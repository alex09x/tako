#!/usr/bin/env python3
# tako — Build the test app once: tests
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT
"""prebuilt.py on a made-up bundle in a throwaway git checkout: nothing is
built, signed or launched; the toolchain and the reseal are stand-ins."""

import importlib.util
import json
import os
import plistlib
import subprocess
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location(
    "prebuilt", os.path.join(os.path.dirname(os.path.abspath(__file__)), "prebuilt.py"))
prebuilt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prebuilt)

TOOLS = {"swiftc": "swift 6.2", "xcode": "Xcode 26.6", "macos_sdk": "26.5", "macos_sdk_build": "25F1",
         "rustc": "rustc 1.91.0", "mitts": "mitts 0.3.37"}
# What ci.sh exports for every test stage, producer and consumers alike.
ENV = {"TAKO_CODESIGN_IDENTITY": "-"}


def git(root, *args):
    subprocess.run(["git", *args], cwd=root, check=True, capture_output=True)


def write_plist(path, bundle_id):
    with open(path, "wb") as f:
        plistlib.dump({"CFBundleIdentifier": bundle_id}, f)


def fake_reseal(app, bundle_id):
    write_plist(os.path.join(app, "Contents/Info.plist"), bundle_id)
    with open(os.path.join(app, "Contents/MacOS/Tako"), "ab") as f:
        f.write(b"sig")


class PrebuiltTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = os.path.realpath(tmp.name)
        self.root = os.path.join(self.tmp, "checkout")
        os.makedirs(os.path.join(self.root, "scripts"))
        for pin in ("rust-toolchain.toml", "Cargo.lock", "scripts/build-macapp.py"):
            with open(os.path.join(self.root, pin), "w") as f:
                f.write(pin)
        with open(os.path.join(self.root, ".gitignore"), "w") as f:
            f.write("/target/\n")
        git(self.root, "init", "-q")
        git(self.root, "-c", "user.email=t@t", "-c", "user.name=t", "add", ".")
        git(self.root, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "x")
        self.app = os.path.join(self.root, "target/macapp/Tako.app")
        for rel, body in [("Contents/MacOS/Tako", "exe"), ("Contents/MacOS/takoctl", "ctl"),
                          ("Contents/Helpers/zmx", "zmx"), ("Contents/_CodeSignature/CodeResources", "seal")]:
            os.makedirs(os.path.dirname(os.path.join(self.app, rel)), exist_ok=True)
            with open(os.path.join(self.app, rel), "w") as f:
                f.write(body)
        write_plist(os.path.join(self.app, "Contents/Info.plist"), "com.tako-core.terminal.prebuilt")
        self.runner = os.path.join(self.root, "target/tako-e2e")
        for path, body in [(self.runner, "runner"), (self.runner + ".inputs", "key")]:
            with open(path, "w") as f:
                f.write(body)
        patcher = mock.patch.object(prebuilt, "toolchain_facts", lambda root=None: dict(TOOLS))
        patcher.start()
        self.addCleanup(patcher.stop)
        self.out = os.path.join(self.tmp, "prebuilt")
        self.manifest = prebuilt.pack(self.app, self.out, self.runner, self.root, ENV)

    def current(self, environ=ENV, **toolchain):
        facts = prebuilt.describe(self.app, None, self.root, environ)
        facts["toolchain"].update(toolchain)
        return facts

    def test_the_manifest_binds_commit_toolchain_build_pins_and_every_file(self):
        head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=self.root, capture_output=True, text=True).stdout.strip()
        self.assertEqual(self.manifest["checkout"]["head"], head)
        self.assertEqual(self.manifest["toolchain"], TOOLS)
        self.assertEqual(self.manifest["build"]["mode"], "debug")
        self.assertEqual(self.manifest["build"]["codesign"], "-")
        self.assertEqual(self.manifest["build"]["bundle_id"], "com.tako-core.terminal.prebuilt")
        self.assertIn("Cargo.lock", self.manifest["pins"])
        self.assertIn("Contents/Helpers/zmx", self.manifest["app"])
        self.assertTrue(self.manifest["build"]["with_zmx"])
        self.assertEqual(set(self.manifest["runner"]), {"tako-e2e", "tako-e2e.inputs"})
        prebuilt.verify(self.out, True, self.root, ENV, self.current())

    def test_a_dirty_checkout_cannot_pack(self):
        with open(os.path.join(self.root, "Cargo.lock"), "w") as f:
            f.write("edited")
        with self.assertRaisesRegex(prebuilt.Mismatch, "uncommitted"):
            prebuilt.pack(self.app, self.out + "2", None, self.root, ENV)

    def test_an_untracked_source_counts_as_a_change_but_ignored_products_do_not(self):
        # target/ (the app and runner themselves) is ignored and already present.
        prebuilt.pack(self.app, self.out + "-clean", None, self.root, ENV)
        os.makedirs(os.path.join(self.root, "swift"))
        with open(os.path.join(self.root, "swift", "New.swift"), "w") as f:
            f.write("let x = 1\n")
        with self.assertRaisesRegex(prebuilt.Mismatch, "uncommitted"):
            prebuilt.pack(self.app, self.out + "-new", None, self.root, ENV)
        with self.assertRaisesRegex(prebuilt.Mismatch, "uncommitted"):
            prebuilt.verify(self.out, False, self.root, ENV)

    def test_only_an_ad_hoc_build_can_be_shared(self):
        for env in ({}, {"TAKO_CODESIGN_IDENTITY": "Developer ID Application: X"}):
            with self.assertRaisesRegex(prebuilt.Mismatch, "ad hoc"):
                prebuilt.pack(self.app, self.out + "3", None, self.root, env)

    def test_another_commit_is_refused(self):
        git(self.root, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "y")
        with self.assertRaisesRegex(prebuilt.Mismatch, "built from"):
            prebuilt.verify(self.out, False, self.root, ENV)

    def test_github_sha_must_be_the_checkout(self):
        with self.assertRaisesRegex(prebuilt.Mismatch, "GITHUB_SHA"):
            prebuilt.checkout_facts(self.root, {"GITHUB_SHA": "0" * 40})

    def head(self):
        return subprocess.run(["git", "rev-parse", "HEAD"], cwd=self.root, capture_output=True, text=True).stdout.strip()

    def test_an_explicit_source_run_binds_its_checkout_and_keeps_the_event_sha(self):
        event = {"GITHUB_SHA": "0" * 40, "GITHUB_REF": "refs/heads/main", "TAKO_EXPECTED_SOURCE_SHA": self.head()}
        manifest = prebuilt.pack(self.app, self.out + "-dispatch", None, self.root, {**ENV, **event})
        self.assertEqual(manifest["checkout"]["head"], self.head())
        self.assertEqual(manifest["checkout"]["expected_source_sha"], self.head())
        # The event's own SHA and ref stay what the event said.
        self.assertEqual(manifest["checkout"]["github_sha"], "0" * 40)
        self.assertEqual(manifest["checkout"]["github_ref"], "refs/heads/main")

    def test_an_expected_source_other_than_the_checkout_is_refused(self):
        with self.assertRaisesRegex(prebuilt.Mismatch, "is not the expected source"):
            prebuilt.checkout_facts(self.root, {"GITHUB_SHA": self.head(), "TAKO_EXPECTED_SOURCE_SHA": "1" * 40})
        # An abbreviated id is refused as such, not compared by prefix.
        with self.assertRaisesRegex(prebuilt.Mismatch, "full commit id"):
            prebuilt.checkout_facts(self.root, {"TAKO_EXPECTED_SOURCE_SHA": self.head()[:12]})

    def test_another_sdk_or_compiler_is_refused(self):
        with self.assertRaisesRegex(prebuilt.Mismatch, "macos_sdk_build"):
            prebuilt.verify(self.out, False, self.root, ENV, self.current(macos_sdk_build="25G9"))
        with self.assertRaisesRegex(prebuilt.Mismatch, "swiftc"):
            prebuilt.verify(self.out, False, self.root, ENV, self.current(swiftc="swift 6.1"))

    def test_a_release_build_is_refused_by_a_debug_stage_and_back(self):
        with self.assertRaisesRegex(prebuilt.Mismatch, "build mode"):
            prebuilt.verify(self.out, False, self.root, ENV, self.current({**ENV, "RELEASE": "1"}))
        release = os.path.join(self.tmp, "release")
        prebuilt.pack(self.app, release, None, self.root, {**ENV, "RELEASE": "1"})
        with self.assertRaisesRegex(prebuilt.Mismatch, "build mode"):
            prebuilt.verify(release, False, self.root, ENV, self.current())

    def test_other_target_features_or_signing_are_refused(self):
        for key, value in (("target", "x86_64-apple-macos14.0"), ("cargo_features", "ssh,pty"), ("codesign", "")):
            current = self.current()
            current["build"][key] = value
            with self.assertRaisesRegex(prebuilt.Mismatch, f"build {key}"):
                prebuilt.verify(self.out, False, self.root, ENV, current)

    def test_the_neutral_bundle_id_is_not_part_of_the_contract(self):
        current = self.current()
        current["build"]["bundle_id"] = "com.tako-core.terminal.e2e"
        prebuilt.verify(self.out, False, self.root, ENV, current)

    def test_changed_missing_or_added_files_are_refused(self):
        exe = os.path.join(self.out, "Tako.app/Contents/MacOS/Tako")
        with open(exe, "a") as f:
            f.write("x")
        with self.assertRaisesRegex(prebuilt.Mismatch, "changed Contents/MacOS/Tako"):
            prebuilt.verify(self.out, False, self.root, ENV, self.current())
        with open(exe, "w") as f:
            f.write("exe")
        os.remove(os.path.join(self.out, "Tako.app/Contents/Helpers/zmx"))
        with self.assertRaisesRegex(prebuilt.Mismatch, "missing Contents/Helpers/zmx"):
            prebuilt.verify(self.out, False, self.root, ENV, self.current())
        with open(os.path.join(self.out, "Tako.app/Contents/Helpers/zmx"), "w") as f:
            f.write("zmx")
        with open(os.path.join(self.out, "Tako.app/Contents/extra"), "w") as f:
            f.write("?")
        with self.assertRaisesRegex(prebuilt.Mismatch, "unexpected Contents/extra"):
            prebuilt.verify(self.out, False, self.root, ENV, self.current())

    def test_a_lost_executable_bit_is_a_change(self):
        exe = os.path.join(self.out, "Tako.app/Contents/MacOS/Tako")
        os.chmod(exe, 0o644 if os.stat(exe).st_mode & 0o100 else 0o755)
        with self.assertRaisesRegex(prebuilt.Mismatch, "changed Contents/MacOS/Tako"):
            prebuilt.verify(self.out, False, self.root, ENV, self.current())

    def test_a_changed_runner_is_refused(self):
        with open(os.path.join(self.out, "tako-e2e"), "a") as f:
            f.write("x")
        with self.assertRaisesRegex(prebuilt.Mismatch, "runner"):
            prebuilt.verify(self.out, False, self.root, ENV, self.current())

    def test_persistence_requires_the_session_runtime(self):
        os.remove(os.path.join(self.app, "Contents/Helpers/zmx"))
        bare = os.path.join(self.tmp, "bare")
        prebuilt.pack(self.app, bare, None, self.root, ENV)
        with self.assertRaisesRegex(prebuilt.Mismatch, "session runtime"):
            prebuilt.verify(bare, True, self.root, ENV, self.current())

    def test_install_reseals_only_identity_and_writes_its_own_receipt(self):
        dest = os.path.join(self.tmp, "stage")
        receipt = prebuilt.install(self.out, dest, "com.example.e2e-1", True, self.root, ENV, self.current(), fake_reseal)
        self.assertEqual(receipt["bundle_id"], "com.example.e2e-1")
        self.assertEqual(prebuilt.bundle_id(os.path.join(dest, "Tako.app")), "com.example.e2e-1")
        self.assertEqual(receipt["resealed"], ["Contents/Info.plist", "Contents/MacOS/Tako"])
        with open(os.path.join(dest, "prebuilt-receipt.json")) as f:
            self.assertEqual(json.load(f)["files"], prebuilt.tree_hashes(os.path.join(dest, "Tako.app")))
        with open(os.path.join(self.root, "target/tako-e2e")) as f:
            self.assertEqual(f.read(), "runner")

    def test_a_reseal_that_touches_anything_else_is_refused(self):
        def bad(app, bundle_id):
            with open(os.path.join(app, "Contents/MacOS/takoctl"), "a") as f:
                f.write("x")
        with self.assertRaisesRegex(prebuilt.Mismatch, "takoctl"):
            prebuilt.install(self.out, os.path.join(self.tmp, "s"), "id", False, self.root, ENV, self.current(), bad)

    def test_the_cli_fails_closed_with_exit_3(self):
        with mock.patch.object(prebuilt, "ROOT", self.root):
            self.assertEqual(prebuilt.main(["verify", os.path.join(self.tmp, "nowhere")]), 3)


if __name__ == "__main__":
    unittest.main()
