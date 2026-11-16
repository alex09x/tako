# tako — iOS walkthrough result accounting
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT

"""Require both a successful command and an executed, successful test result."""

import json


def walkthrough_verdict(build, summary_result):
    failures = []
    if build.returncode != 0:
        failures.append(f"xcodebuild exited {build.returncode}")
    if summary_result.returncode != 0:
        failures.append(f"xcresult summary exited {summary_result.returncode}")
        diagnostic = (build.stderr or build.stdout or "").strip()[-2000:]
        if diagnostic:
            failures.append(diagnostic)
        return {"passed": 0, "failed": failures}
    try:
        summary = json.loads(summary_result.stdout)
        passed = summary["passedTests"]
        failed_count = summary["failedTests"]
        if (type(passed) is not int or passed < 0
                or type(failed_count) is not int or failed_count < 0):
            raise ValueError("test counts must be nonnegative integers")
        test_failures = summary.get("testFailures", [])
        if not isinstance(test_failures, list):
            raise ValueError("testFailures must be a list")
        for failure in test_failures:
            if not isinstance(failure, dict) or not failure.get("failureText"):
                raise ValueError("test failure has no diagnostic")
            name = (failure.get("testIdentifier") or failure.get("testName")
                    or failure.get("testIdentifierString") or "unnamed test")
            failures.append(f"{name}: {failure['failureText']}")
        if failed_count and not test_failures:
            failures.append(f"xcresult reports {failed_count} failed tests without details")
        if passed == 0:
            failures.append("walkthrough executed no passing tests")
    except (ValueError, KeyError, TypeError) as error:
        return {"passed": 0, "failed": failures + [f"invalid xcresult summary: {error}"]}
    return {"passed": passed, "failed": failures}
