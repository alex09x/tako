#!/usr/bin/env python3
# tako — Isolated dispatcher regression tests
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT

import importlib.util
from pathlib import Path
import subprocess
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("tako_hook", Path(__file__).with_name("tako-hook.py"))
hook = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hook)


class DispatcherTests(unittest.TestCase):
    def setUp(self):
        self.env = {
            "TAKO_SOCKET": "/tmp/isolated socket/c.sock",
            "TAKO_SURFACE_ID": "11111111-1111-4111-8111-111111111111",
            "PATH": "/fixture/bin",
        }

    def dispatch(self, event="working", env=None):
        hook.dispatch("codex", event, self.env if env is None else env)

    @patch.object(hook.subprocess, "run")
    @patch.object(hook.shutil, "which", return_value="/fixture/bin/takoctl")
    def test_preserves_socket_spaces_and_target(self, which, run):
        run.return_value = SimpleNamespace(returncode=0)
        self.dispatch()
        self.assertEqual(run.call_count, 2)
        for call in run.call_args_list:
            argv = call.args[0]
            self.assertEqual(argv[-2:], ["--target", self.env["TAKO_SURFACE_ID"]])
            self.assertNotIn("--socket", argv)
            self.assertEqual(call.kwargs["env"], self.env)

    @patch.object(hook.subprocess, "run")
    @patch.object(hook.shutil, "which")
    def test_outside_tako_never_searches_processes_or_uses_cwd(self, which, run):
        self.dispatch(env={"PWD": "/same/repository/as/another/codex"})
        run.assert_not_called()
        which.assert_not_called()

    @patch.object(hook.subprocess, "run")
    def test_incomplete_context_never_falls_back(self, run):
        for key in ("TAKO_SOCKET", "TAKO_SURFACE_ID"):
            env = self.env.copy()
            del env[key]
            self.dispatch(env=env)
        self.dispatch(env={**self.env, "TAKO_SURFACE_ID": "not-a-uuid"})
        self.dispatch(env={**self.env, "TAKO_SOCKET": "relative.sock"})
        run.assert_not_called()

    @patch.object(hook.subprocess, "run")
    @patch.object(hook.shutil, "which", return_value="/fixture/bin/takoctl")
    def test_denial_does_not_retry_with_another_credential(self, which, run):
        run.return_value = SimpleNamespace(returncode=1)
        self.dispatch("permission_request")
        self.assertEqual(run.call_count, 1)
        self.assertEqual(run.call_args.kwargs["env"], self.env)

    @patch.object(hook.subprocess, "run")
    @patch.object(hook.shutil, "which", return_value="/fixture/bin/takoctl")
    def test_two_instances_keep_their_own_bindings(self, which, run):
        run.return_value = SimpleNamespace(returncode=0)
        self.dispatch("done")
        other = {**self.env, "TAKO_SOCKET": "/tmp/second/c.sock",
                 "TAKO_SURFACE_ID": "22222222-2222-4222-8222-222222222222"}
        self.dispatch("done", other)
        for call, expected in zip(run.call_args_list, [self.env, self.env, other, other]):
            self.assertEqual(call.kwargs["env"], expected)
            self.assertEqual(call.args[0][-1], expected["TAKO_SURFACE_ID"])

    @patch.object(hook.subprocess, "run")
    @patch.object(hook.shutil, "which", return_value="/fixture/bin/takoctl")
    def test_timeout_does_not_retry(self, which, run):
        run.side_effect = subprocess.TimeoutExpired("fixture", 5)
        self.dispatch()
        self.assertEqual(run.call_count, 1)

    def test_notification_is_explicitly_targeted(self):
        for args in hook.commands("approval", self.env["TAKO_SURFACE_ID"]):
            self.assertEqual(args[-2:], ["--target", self.env["TAKO_SURFACE_ID"]])

    @patch.object(hook.subprocess, "run")
    @patch.object(hook.shutil, "which", return_value="/fixture/bin/takoctl")
    def test_question_permission_maps_to_waiting_not_execution_approval(self, which, run):
        run.return_value = SimpleNamespace(returncode=0)
        hook.dispatch("claude", "permission_request", self.env, {"tool_name": "AskUserQuestion"})
        self.assertEqual(run.call_args_list[0].args[0][1:4], ["status", "set", "waiting_for_input"])
        self.assertEqual(run.call_args_list[1].args[0][1:3], ["progress", "pause"])

    @patch.object(hook.subprocess, "run")
    @patch.object(hook.shutil, "which", return_value="/fixture/bin/takoctl")
    def test_interrupt_ends_the_turn_idle_and_clears_progress(self, which, run):
        run.return_value = SimpleNamespace(returncode=0)
        hook.dispatch("codex", "interrupt", self.env, {"hook_event_name": "Interrupt"})
        self.assertEqual([c.args[0][1:4] for c in run.call_args_list],
                         [["status", "set", "idle"], ["progress", "clear", "--target"]])
        for call in run.call_args_list:
            self.assertEqual(call.args[0][-2:], ["--target", self.env["TAKO_SURFACE_ID"]])

    @patch.object(hook.subprocess, "run")
    def test_ordinary_tool_is_not_reported_as_question(self, run):
        hook.dispatch("codex", "question", self.env, {"tool_name": "exec_command"})
        run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
