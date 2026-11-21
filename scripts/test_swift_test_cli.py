#!/usr/bin/env python3
# tako — Shared CLI admission for Swift integration tests
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT
from pathlib import Path
import tempfile
import unittest

import prebuilt
from swift_test_cli import install


class SwiftTestCliTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.directory = self.root / "producer"
        self.source = self.directory / "Tako.app/Contents/MacOS/takoctl"
        self.source.parent.mkdir(parents=True)
        self.source.write_bytes(b"the producer's CLI")
        self.source.chmod(0o755)
        self.expected = prebuilt.entry(self.source)

    def verified(self, directory, require_zmx, *, root):
        self.assertEqual(directory, str(self.directory))
        self.assertFalse(require_zmx)  # This consumer needs only takoctl.
        self.assertEqual(root, str(self.root))
        return {"app": {"Contents/MacOS/takoctl": self.expected}}

    def test_tests_get_the_verified_executable_at_their_first_lookup_path(self):
        destination = install(self.directory, self.root, self.verified)
        self.assertEqual(destination, self.root / "takoctl/target/debug/takoctl")
        self.assertEqual(prebuilt.entry(destination), self.expected)

    def test_a_refused_manifest_exposes_no_cli(self):
        def refuse(*args, **kwargs):
            raise prebuilt.Mismatch("source/toolchain mismatch")
        with self.assertRaisesRegex(prebuilt.Mismatch, "source/toolchain mismatch"):
            install(self.directory, self.root, refuse)
        self.assertFalse((self.root / "takoctl/target/debug/takoctl").exists())

    def test_a_changed_copy_does_not_replace_the_existing_cli(self):
        destination = self.root / "takoctl/target/debug/takoctl"
        destination.parent.mkdir(parents=True)
        destination.write_bytes(b"previous CLI")
        self.source.write_bytes(b"changed after verification")
        with self.assertRaisesRegex(prebuilt.Mismatch, "differs from the verified prebuilt"):
            install(self.directory, self.root, self.verified)
        self.assertEqual(destination.read_bytes(), b"previous CLI")
        self.assertEqual(list(destination.parent.iterdir()), [destination])


if __name__ == "__main__":
    unittest.main()
