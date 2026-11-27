#!/usr/bin/env python3
# tako — session runtime fetch tests
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT
"""scripts/session_runtime.py: only pinned files are used, and only once."""
import hashlib
import json
import os
import tempfile
import unittest

import session_runtime as sr


def digest(data):
    return hashlib.sha256(data).hexdigest()


def read(path):
    with open(path, "rb") as f:
        return f.read()


class FetchTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.cache = os.path.join(self.tmp.name, "cache")
        self.files = {
            "tako-session-macos-arm64": b"#!/bin/sh\necho runtime\n",
            "tako-session/LICENSE": b"MIT\n",
            "tako-session/NOTICE": b"notice\n",
        }
        self.pin = {
            "name": "tako-session", "version": "0.1.0", "commit": "c" * 40,
            "repository": "https://github.com/example/core", "tag": "session-v0.1.0",
            "guardedProtocol": 3,
            "executables": {"macos-arm64": {"asset": "tako-session-macos-arm64",
                                            "sha256": digest(self.files["tako-session-macos-arm64"])}},
            "notices": {
                "tako-session/LICENSE": {"as": "LICENSE-tako-session",
                                         "sha256": digest(self.files["tako-session/LICENSE"])},
                "tako-session/NOTICE": {"as": "NOTICE-tako-session",
                                        "sha256": digest(self.files["tako-session/NOTICE"])},
            },
        }
        self.downloads = []

    def tearDown(self):
        self.tmp.cleanup()

    def download(self, url, dest):
        self.downloads.append(url)
        key = url.rsplit("/", 1)[-1] if "/releases/download/" in url else url.split("/" + "c" * 40 + "/", 1)[1]
        with open(dest, "wb") as f:
            f.write(self.files[key])

    def fetch(self):
        return sr.fetch("macos-arm64", pin=self.pin, cache=self.cache, download=self.download)

    def test_the_pinned_runtime_and_its_notices_are_fetched_once(self):
        exe = self.fetch()
        self.assertEqual(read(exe), self.files["tako-session-macos-arm64"])
        self.assertTrue(os.access(exe, os.X_OK))
        entry = os.path.dirname(exe)
        self.assertEqual(sorted(os.listdir(entry)),
                         ["LICENSE-tako-session", "NOTICE-tako-session", "source.json", "tako-session"])
        with open(os.path.join(entry, "source.json")) as f:
            self.assertEqual(json.load(f), {"name": "tako-session", "version": "0.1.0", "commit": "c" * 40,
                                            "tag": "session-v0.1.0", "guardedProtocol": 3,
                                            "asset": "tako-session-macos-arm64",
                                            "assetSha256": digest(self.files["tako-session-macos-arm64"])})
        self.assertIn("https://github.com/example/core/releases/download/session-v0.1.0/tako-session-macos-arm64",
                      self.downloads)
        self.assertIn(f"https://raw.githubusercontent.com/example/core/{'c' * 40}/tako-session/NOTICE",
                      self.downloads)
        fetched = len(self.downloads)
        self.assertEqual(self.fetch(), exe)
        self.assertEqual(len(self.downloads), fetched, "a complete entry is reused")

    def test_a_download_that_is_not_the_pinned_one_is_refused_and_not_cached(self):
        self.files["tako-session-macos-arm64"] = b"something else"
        with self.assertRaisesRegex(sr.Mismatch, "tako-session-macos-arm64: sha256"):
            self.fetch()
        self.assertEqual(os.listdir(self.cache), [], "nothing is left behind")

    def test_a_changed_notice_is_refused(self):
        self.files["tako-session/NOTICE"] = b"changed"
        with self.assertRaisesRegex(sr.Mismatch, "tako-session/NOTICE: sha256"):
            self.fetch()

    def test_a_verified_entry_with_an_old_record_is_not_downloaded_again(self):
        exe = self.fetch()
        record = os.path.join(os.path.dirname(exe), "source.json")
        with open(record, "w") as f:
            json.dump({"name": "tako-session", "version": "0.1.0"}, f)
        fetched = len(self.downloads)
        self.assertEqual(self.fetch(), exe)
        self.assertEqual(len(self.downloads), fetched, "the verified files are kept")
        with open(record) as f:
            self.assertEqual(json.load(f)["assetSha256"], digest(self.files["tako-session-macos-arm64"]))
        # A record that is a link to a verified file is replaced, never written through.
        os.remove(record)
        os.symlink(exe, record)
        self.assertEqual(self.fetch(), exe)
        self.assertEqual(read(exe), self.files["tako-session-macos-arm64"])
        self.assertFalse(os.path.islink(record))

    def test_a_tampered_cache_entry_is_downloaded_again(self):
        exe = self.fetch()
        with open(exe, "ab") as f:
            f.write(b"tampered")
        fetched = len(self.downloads)
        self.assertEqual(self.fetch(), exe)
        self.assertGreater(len(self.downloads), fetched)
        self.assertEqual(read(exe), self.files["tako-session-macos-arm64"])

    def test_an_unknown_platform_is_an_error(self):
        with self.assertRaises(SystemExit):
            sr.fetch("windows", pin=self.pin, cache=self.cache, download=self.download)

    def test_the_legacy_fixture_is_fetched_once_and_only_as_pinned(self):
        fixture = b"legacy runtime"
        self.pin["legacyFixture"] = {"tag": "fixtures-v1", "asset": "legacy-asset", "sha256": digest(fixture)}
        self.files["legacy-asset"] = fixture
        exe = sr.fetch_legacy_fixture(pin=self.pin, cache=self.cache, download=self.download)
        self.assertEqual(read(exe), fixture)
        self.assertTrue(os.access(exe, os.X_OK))
        self.assertIn("https://github.com/example/core/releases/download/fixtures-v1/legacy-asset", self.downloads)
        fetched = len(self.downloads)
        self.assertEqual(sr.fetch_legacy_fixture(pin=self.pin, cache=self.cache, download=self.download), exe)
        self.assertEqual(len(self.downloads), fetched)
        self.files["legacy-asset"] = b"other"
        self.pin["legacyFixture"]["sha256"] = digest(b"pinned")
        with self.assertRaisesRegex(sr.Mismatch, "legacy-asset: sha256"):
            sr.fetch_legacy_fixture(pin=self.pin, cache=self.cache, download=self.download)

    def test_the_repository_pin_names_both_release_builds(self):
        pin = sr.load_pin()
        self.assertEqual(set(pin["executables"]), {"macos-arm64", "linux-x86_64"})
        for entry in [*pin["executables"].values(), *pin["notices"].values(), pin["legacyFixture"]]:
            self.assertRegex(entry["sha256"], r"^[0-9a-f]{64}$")
        self.assertRegex(pin["commit"], r"^[0-9a-f]{40}$")


if __name__ == "__main__":
    unittest.main()
