#!/usr/bin/env python3
# tako — Where test apps are built and run from: tests
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT
"""app_locations on made-up checkouts: an external-volume prefix is faked by
pointing EXTERNAL at a temporary directory, so no real volume is touched."""

import importlib.util
import os
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location(
    "app_locations", os.path.join(os.path.dirname(os.path.abspath(__file__)), "app_locations.py"))
app_locations = importlib.util.module_from_spec(spec)
spec.loader.exec_module(app_locations)


class AppLocationsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        base = os.path.realpath(self.tmp.name)
        self.external = os.path.join(base, "Volumes", "Disk")
        self.internal = os.path.join(base, "internal")
        os.makedirs(os.path.join(self.external, "checkout"))
        os.makedirs(os.path.join(self.internal, "checkout"))
        # A link from the startup disk onto the volume, like the test Mac's ~/ci.
        self.link = os.path.join(self.internal, "ci")
        os.symlink(os.path.join(self.external, "checkout"), self.link)
        patcher = mock.patch.object(app_locations, "EXTERNAL", os.path.join(base, "Volumes") + "/")
        patcher.start()
        self.addCleanup(patcher.stop)
        self.addCleanup(self.tmp.cleanup)

    def test_an_internal_checkout_keeps_target(self):
        root = os.path.join(self.internal, "checkout")
        self.assertEqual(app_locations.app_dir("macapp-e2e", root, {}), "target/macapp-e2e")
        self.assertIsNone(app_locations.check_source("uitest", root))

    def test_an_external_checkout_moves_the_app_to_the_caches_root(self):
        cache = os.path.join(self.internal, "caches")
        got = app_locations.app_dir("macapp-e2e", self.link, {"TAKO_E2E_APP_ROOT": cache})
        self.assertTrue(got.startswith(cache + "/") and got.endswith("/macapp-e2e"), got)
        self.assertFalse(app_locations.is_external(got))
        # The key is the real checkout, however it is reached.
        direct = app_locations.app_dir("macapp-e2e", os.path.join(self.external, "checkout"),
                                       {"TAKO_E2E_APP_ROOT": cache})
        self.assertEqual(got, direct)
        self.assertNotEqual(got, app_locations.app_dir("macapp-ci", self.link, {"TAKO_E2E_APP_ROOT": cache}))

    def test_without_an_override_the_root_is_the_users_caches(self):
        got = app_locations.app_dir("macapp", self.link, {})
        self.assertTrue(got.startswith(os.path.expanduser("~/Library/Caches/tako-e2e/")), got)

    def test_an_app_on_an_external_volume_is_refused_through_a_link_and_before_it_exists(self):
        self.assertIsNotNone(app_locations.check_app(os.path.join(self.link, "target/macapp/Tako.app")))
        self.assertIsNotNone(app_locations.check_app(os.path.join(self.external, "new/Tako.app")))
        self.assertIsNone(app_locations.check_app(os.path.join(self.internal, "caches/x/Tako.app")))

    def test_source_reading_routes_refuse_an_external_checkout(self):
        reason = app_locations.check_source("macos-ui-tests", self.link)
        self.assertIn("TAKO_MAC_DIR=/private/tmp/", reason)
        self.assertIn("nothing was launched", reason)

    def test_the_cli_exits_3_with_its_reason(self):
        with mock.patch.object(app_locations, "ROOT", self.link):
            self.assertEqual(app_locations.main(["check-source", "ios-simtest"]), 3)
            self.assertEqual(app_locations.main(["check-app", os.path.join(self.link, "a.app")]), 3)
            self.assertEqual(app_locations.main(["check-app", os.path.join(self.internal, "a.app")]), 0)
            self.assertEqual(app_locations.main(["bogus"]), 2)


if __name__ == "__main__":
    unittest.main()
