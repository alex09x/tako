#!/usr/bin/env python3
# tako — tako-core release location tests
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT
"""scripts/tako_core.py: the pinned release is found, or the failure says to resolve again."""
import json
import os
import plistlib
import subprocess
import tempfile
import unittest

import tako_core


def git(cwd, *args):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True)


class LocateTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.package = tmp.name
        checkout = os.path.join(self.package, ".build", "checkouts", "tako-core")
        os.makedirs(os.path.join(checkout, "swift", "Sources", "TakoCoreUI"))
        git(checkout, "init", "-q")
        git(checkout, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "x")
        revision = subprocess.run(["git", "rev-parse", "HEAD"], cwd=checkout, capture_output=True,
                                  text=True, check=True).stdout.strip()
        self.resolved = os.path.join(self.package, "Package.resolved")
        with open(self.resolved, "w") as f:
            json.dump({"pins": [{"identity": "tako-core", "state": {"revision": revision, "version": "9.9.9"}}],
                       "version": 2}, f)
        self.framework = os.path.join(self.package, ".build", "artifacts", "tako-core", "X", "TakoCore.xcframework")
        os.makedirs(self.framework)

    def write_info(self, body):
        with open(os.path.join(self.framework, "Info.plist"), "wb") as f:
            f.write(body)

    def libraries(self, *idents):
        return plistlib.dumps({"AvailableLibraries": [
            {"LibraryIdentifier": i, "LibraryPath": "libtako_core.a", "HeadersPath": "Headers"} for i in idents]})

    def locate(self):
        return tako_core.locate(self.package, self.resolved)

    def complete_slices(self):
        for ident in tako_core.REQUIRED_SLICES:
            os.makedirs(os.path.join(self.framework, ident, "Headers"), exist_ok=True)
            open(os.path.join(self.framework, ident, "libtako_core.a"), "w").close()

    def test_a_complete_release_is_located(self):
        self.write_info(self.libraries(*tako_core.REQUIRED_SLICES))
        self.complete_slices()
        paths = self.locate()
        self.assertEqual(paths["version"], "9.9.9")
        self.assertEqual(set(paths["slices"]), set(tako_core.REQUIRED_SLICES))
        self.assertTrue(paths["slices"]["macos-arm64"]["library"].endswith("macos-arm64/libtako_core.a"))

    def test_a_damaged_framework_says_to_resolve_again(self):
        for body in (b"<?xml version='1.0'?><plist><dict>",
                     b"<?xml version='1.0'?><plist><key>AvailableLibraries</key></plist>",
                     plistlib.dumps({"AvailableLibraries": "x"}),
                     plistlib.dumps({"AvailableLibraries": [{"LibraryIdentifier": "a", "LibraryPath": 3}]}),
                     b"<?xml version='1.0'?><plist><dict><key>d</key><date>not a date</date></dict></plist>",
                     self.libraries("macos-arm64")):
            self.write_info(body)
            with self.assertRaisesRegex(tako_core.Unresolved, "resolve the package again"):
                self.locate()

    def test_a_slice_missing_its_archive_says_to_resolve_again(self):
        self.write_info(self.libraries(*tako_core.REQUIRED_SLICES))
        self.complete_slices()
        os.remove(os.path.join(self.framework, "ios-arm64", "libtako_core.a"))
        with self.assertRaisesRegex(tako_core.Unresolved, "ios-arm64: .*libtako_core.a is missing"):
            self.locate()

    def test_a_checkout_at_another_commit_is_refused(self):
        self.write_info(self.libraries(*tako_core.REQUIRED_SLICES))
        self.complete_slices()
        with open(self.resolved) as f:
            data = json.load(f)
        data["pins"][0]["state"]["revision"] = "0" * 40
        with open(self.resolved, "w") as f:
            json.dump(data, f)
        with self.assertRaisesRegex(tako_core.Unresolved, "Package.resolved says"):
            self.locate()


if __name__ == "__main__":
    unittest.main()
