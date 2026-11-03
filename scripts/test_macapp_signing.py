"""Tako — Signing changes must not invalidate the pinned session runtime.

Copyright (c) 2026 Alexander Panasenko
Contact: alex@prod.codes
Author: https://prod.codes/about/
Project: https://github.com/alex09x/tako
SPDX-License-Identifier: MIT
"""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

from macapp_signing import candidate_source, sign_bundle, verify_source_checkout


class SigningTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.TemporaryDirectory()
        self.addCleanup(self.root.cleanup)
        self.app = Path(self.root.name) / "Tako.app"
        for relative in ["Contents/MacOS/Tako", "Contents/MacOS/takoctl", "Contents/Helpers/zmx"]:
            path = self.app / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"unsigned fixture")
        self.helper = self.app / "Contents/Helpers/zmx"
        self.manifest = self.app / "Contents/Resources/session-runtime.json"
        self.manifest.parent.mkdir(parents=True)
        self.original = {"path": "Contents/Helpers/zmx", "sha256": "old", "guardedProtocol": 3,
                         "commit": "source fixture", "future_metadata": {"keep": True}}
        self.manifest.write_text(json.dumps(self.original))

    def test_resigning_refreshes_runtime_digest_before_outer_signature(self):
        calls = []

        def signer(args, **kwargs):
            calls.append(args)
            if "--force" in args:
                target = Path(args[-1])
                self.assertNotIn("--deep", args)
                if target == self.app:
                    current = json.loads(self.manifest.read_text())
                    self.assertEqual(current["sha256"], hashlib.sha256(self.helper.read_bytes()).hexdigest())
                    self.assertNotEqual(current["sha256"], self.original["sha256"])
                else:
                    target.write_bytes(target.read_bytes() + b" signed fixture")
            return subprocess.CompletedProcess(args, 0, "", "")

        digest = sign_bundle(self.app, "Developer ID Application: Test fixture", runner=signer)
        current = json.loads(self.manifest.read_text())
        self.assertEqual(digest, hashlib.sha256(self.helper.read_bytes()).hexdigest())
        self.assertEqual({k: v for k, v in current.items() if k != "sha256"},
                         {k: v for k, v in self.original.items() if k != "sha256"})
        self.assertEqual([Path(c[-1]).name for c in calls if "--force" in c], ["zmx", "takoctl", "Tako.app"])
        self.assertIn("--verify", calls[-1])

    def test_invalid_manifest_path_and_linked_helper_are_refused_before_signing(self):
        calls = []
        self.manifest.write_text(json.dumps({**self.original, "path": "../../outside"}))
        with self.assertRaises(ValueError):
            sign_bundle(self.app, "-", runner=lambda *a, **k: calls.append(a))
        self.assertEqual(calls, [])
        self.manifest.write_text(json.dumps(self.original))
        outside = Path(self.root.name) / "outside"
        outside.write_bytes(b"must stay unchanged")
        self.helper.unlink()
        self.helper.symlink_to(outside)
        with self.assertRaises(ValueError):
            sign_bundle(self.app, "-", runner=lambda *a, **k: calls.append(a))
        self.assertEqual(outside.read_bytes(), b"must stay unchanged")
        self.assertEqual(calls, [])

    def test_runtime_absence_is_valid_but_partial_runtime_is_not(self):
        self.helper.unlink()
        with self.assertRaises(ValueError):
            sign_bundle(self.app, "-", runner=lambda *a, **k: self.fail("must refuse before signing"))
        self.manifest.unlink()
        calls = []
        sign_bundle(self.app, "-", runner=lambda a, **k: calls.append(a))
        self.assertEqual(len(calls), 3)
        self.assertTrue(all("--timestamp" not in a for a in calls))

    def test_parent_directory_links_cannot_redirect_signing_outside_the_bundle(self):
        outside = Path(self.root.name) / "outside-helper"
        outside.mkdir()
        (outside / "zmx").write_bytes(b"outside fixture")
        self.helper.unlink()
        self.helper.parent.rmdir()
        self.helper.parent.symlink_to(outside)
        with self.assertRaises(ValueError):
            sign_bundle(self.app, "-", runner=lambda *a, **k: self.fail("outside signing is forbidden"))
        self.assertEqual((outside / "zmx").read_bytes(), b"outside fixture")

    def test_signer_failure_does_not_seal_or_publish_a_partial_candidate(self):
        calls = []

        def failing(args, **kwargs):
            calls.append(args)
            raise subprocess.CalledProcessError(1, args, stderr="fixture signer failed")

        with self.assertRaises(subprocess.CalledProcessError):
            sign_bundle(self.app, "-", runner=failing)
        self.assertEqual(len(calls), 1)
        self.assertEqual(json.loads(self.manifest.read_text()), self.original)

    def test_cli_refuses_an_installed_app_before_using_a_certificate(self):
        result = subprocess.run([sys.executable, str(Path(__file__).with_name("sign-macapp.py")),
                                 "--app", "/Applications/Tako.app"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertIn("not an installed application", result.stderr)

    def test_cli_without_a_developer_id_never_attempts_signing(self):
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "com.tako-core.terminal", "CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "1"}))
        spec = importlib.util.spec_from_file_location("tako_sign_candidate", Path(__file__).with_name("sign-macapp.py"))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with mock.patch.object(sys, "argv", ["sign-macapp.py", "--app", str(self.app)]), \
             mock.patch.dict(os.environ, {"TAKO_CODESIGN_IDENTITY": ""}), \
             mock.patch.object(module.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "0 valid identities", "")), \
             mock.patch.object(module, "sign_bundle") as sign:
            with self.assertRaises(SystemExit) as failure:
                module.main()
            self.assertEqual(failure.exception.code, 2)
            sign.assert_not_called()

    def test_candidate_metadata_cannot_substitute_another_source_or_build(self):
        source = "a" * 40
        info = {"TakoSourceCommit": source, "CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "42"}
        metadata = Path(self.root.name) / "candidate.json"
        record = {"source_sha": source, "version": "1.2.3", "build": "42"}
        metadata.write_text(json.dumps(record))
        self.assertEqual(candidate_source(info, metadata), source)
        for field, value in [("source_sha", "b" * 40), ("version", "9.9.9"), ("build", "99")]:
            metadata.write_text(json.dumps({**record, field: value}))
            with self.assertRaises(ValueError):
                candidate_source(info, metadata)

    def test_notarization_refuses_mismatched_or_dirty_sbom_source(self):
        source = "a" * 40

        def wrong_head(args, **kwargs):
            return subprocess.CompletedProcess(args, 0, "b" * 40, "")

        with self.assertRaises(ValueError):
            verify_source_checkout(source, self.root.name, runner=wrong_head)

        def dirty(args, **kwargs):
            return subprocess.CompletedProcess(args, 0, source if args[1] == "rev-parse" else " M Cargo.lock", "")

        with self.assertRaises(ValueError):
            verify_source_checkout(source, self.root.name, runner=dirty)

        def clean(args, **kwargs):
            return subprocess.CompletedProcess(args, 0, source if args[1] == "rev-parse" else "", "")

        verify_source_checkout(source, self.root.name, runner=clean)


if __name__ == "__main__":
    unittest.main()
