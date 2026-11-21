# tako — iOS walkthrough result accounting
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT

"""Require both a successful command and an executed, successful test result,
and judge the resize scenario against the grid the app itself reports."""

import json
import re

_GRID = re.compile(r"^grid: (\d+)x(\d+) \(view (\d+)x(\d+)\)$", re.M)
_PTY = re.compile(r"PTY \S+ (\d+)x(\d+)")
_RESIZE = re.compile(r"RESIZE (\d+)x(\d+)")


def resize_verdict(dump):
    """Problems with a resize run's dump; empty when it passes.

    The app reports its core grid and its view's (`grid: CxR (view CxR)`,
    written by LaunchProbe in test mode); both must be present, positive and
    equal, which is the drawn grid. The byte-naming server's transcript is the
    dump's buffer section, which must be there: the on-screen section is only
    what fits, and is never used in its place. It reports the PTY request
    and each window change. The PTY may be opened at any positive size: at the
    80x24 default or already at the laid-out size, depending on whether layout
    ran first. What must hold is that the far end is told the drawn grid: the
    last RESIZE equals it, and no 80x24 left over from the default is ever
    sent when that is not the drawn grid.
    """
    head, _, rest = dump.partition("── on screen ──")
    # Only the buffer section is the whole server transcript; the on-screen
    # one is what fits on screen, where an early RESIZE may have scrolled off.
    _, marker, server = rest.partition("── buffer ──")
    problems = []
    if not marker or not server.strip():
        problems.append("the dump has no buffer section")
    grid = _GRID.search(head)
    if not grid:
        problems.append("the app reported no core and view grid")
    elif grid.group(1, 2) != grid.group(3, 4):
        problems.append(f"the core grid {grid.group(1)}x{grid.group(2)} is not the view's "
                        f"{grid.group(3)}x{grid.group(4)}")
    if problems:
        return problems
    pty = _PTY.search(server)
    if not pty:
        problems.append("the server saw no PTY request")
    resizes = [(int(c), int(r)) for c, r in _RESIZE.findall(server)]
    if not resizes:
        problems.append("the server saw no RESIZE")
    if problems:
        return problems
    drawn = (int(grid.group(1)), int(grid.group(2)))
    opened = (int(pty.group(1)), int(pty.group(2)))
    view = (int(grid.group(3)), int(grid.group(4)))
    for label, (cols, rows) in [("drawn grid", drawn), ("view grid", view), ("initial PTY", opened)] + \
            [(f"RESIZE {i + 1}", size) for i, size in enumerate(resizes)]:
        if cols <= 0 or rows <= 0:
            problems.append(f"{label} is {cols}x{rows}")
    if resizes[-1] != drawn:
        problems.append(f"the last RESIZE is {resizes[-1][0]}x{resizes[-1][1]}, "
                        f"the drawn grid {drawn[0]}x{drawn[1]}")
    if drawn != (80, 24) and (80, 24) in resizes:
        problems.append(f"a stale RESIZE 80x24 was sent; the drawn grid is {drawn[0]}x{drawn[1]}")
    return problems


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
