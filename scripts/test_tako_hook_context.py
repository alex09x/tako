#!/usr/bin/env python3
# tako — Explicit daemon session routing and grant renewal regressions
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT

import hashlib
import unittest
from unittest.mock import patch

import tako_hook_context as context
import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location("tako_codex", Path(__file__).with_name("tako-codex.py"))
wrapper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wrapper)


class ContextTests(unittest.TestCase):
    def setUp(self):
        self.surface = "11111111-1111-4111-8111-111111111111"
        self.session = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        self.record = {"surface": self.surface, "socket": "/tmp/tako.sock",
                       "token": "a" * 64, "scopes": ["signal"],
                       "retired_grant_sha256": hashlib.sha256(b"retired").hexdigest()}

    @patch.object(context, "read_binding")
    def test_daemon_routes_only_by_enrolled_session(self, read):
        read.return_value = self.record
        self.assertEqual(context.resolve("codex", {}, {"session_id": self.session}), self.record)
        read.assert_called_once_with("codex:" + self.session)

    @patch.object(context, "read_binding")
    def test_unknown_daemon_session_is_noop_even_same_directory(self, read):
        read.return_value = None
        self.assertIsNone(context.resolve("codex", {}, {"session_id": self.session, "cwd": "/same/repo"}))
        self.assertIsNone(context.resolve("codex", {}, {"cwd": "/same/repo"}))

    @patch.object(context, "read_binding")
    def test_only_exact_enrolled_retired_grant_is_refreshed(self, read):
        read.return_value = self.record
        env = {"TAKO_SURFACE_ID": self.surface, "TAKO_SOCKET": "/tmp/tako.sock", "TAKO_CONTROL_TOKEN": "retired"}
        self.assertEqual(context.resolve("claude", env, {}), self.record)
        self.assertIsNone(context.resolve("claude", {**env, "TAKO_CONTROL_TOKEN": "different-restricted"}, {}))
        self.assertIsNone(context.resolve("claude", {**env, "TAKO_SOCKET": "/tmp/other.sock"}, {}))

    @patch.object(context, "read_binding")
    def test_overprivileged_or_malformed_binding_is_rejected(self, read):
        for invalid in [{**self.record, "scopes": ["signal", "input"]},
                        {**self.record, "surface": "not-a-uuid"},
                        {**self.record, "socket": "relative"},
                        {**self.record, "token": "not-a-token"}]:
            read.return_value = invalid
            self.assertIsNone(context.resolve("codex", {}, {"session_id": self.session}))

    def test_codex_wrapper_preserves_outside_calls_and_binds_inside_pty(self):
        self.assertEqual(wrapper.provider_args(["exec", "hello"], {}), ["exec", "hello"])
        env = {"TAKO_SOCKET": "/tmp/one.sock", "TAKO_SURFACE_ID": self.surface}
        self.assertEqual(wrapper.provider_args(["resume", "thread"], env), ["--no-daemon", "resume", "thread"])
        self.assertEqual(wrapper.provider_args(["--no-daemon", "resume"], env), ["--no-daemon", "resume"])

    @patch.object(context, "socket")
    @patch.object(context, "write_binding")
    @patch.object(context, "read_binding", return_value=None)
    def test_bootstrap_preserves_denied_issuer_and_stores_only_signal(self, read, write, network):
        client = network.socket.return_value.__enter__.return_value
        client.makefile.return_value.readline.return_value = b'{"ok":false}'
        env = {"TAKO_SOCKET": "/tmp/one.sock", "TAKO_SURFACE_ID": self.surface, "TAKO_CONTROL_TOKEN": "b" * 64}
        self.assertIsNone(context.bootstrap("claude", env, {}))
        write.assert_not_called()
        client.makefile.return_value.readline.return_value = b'{"ok":true,"result":{"token":"' + b'a' * 64 + b'"}}'
        value = context.bootstrap("claude", env, {})
        self.assertEqual(value["scopes"], ["signal"])
        self.assertEqual(value["retired_grant_sha256"], hashlib.sha256(env["TAKO_CONTROL_TOKEN"].encode()).hexdigest())


if __name__ == "__main__":
    unittest.main()
