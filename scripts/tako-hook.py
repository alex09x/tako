#!/usr/bin/env python3
# tako — Agent lifecycle dispatcher with explicit recipient and grant binding
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT

"""Dispatch only within an explicitly inherited Tako context.

Detached providers must receive the originating session's socket and surface
from their launcher. Process names, cwd and the current GUI tab are not
session identities. An unresolved event is deliberately a no-op.
"""

import os
import shutil
import subprocess
import sys
import uuid
import json


def recipient(env):
    """Return an explicit complete binding; never discover other processes."""
    surface = env.get("TAKO_SURFACE_ID", "")
    socket = env.get("TAKO_SOCKET", "")
    if not socket or not os.path.isabs(socket):
        return None
    try:
        surface = str(uuid.UUID(surface))
    except (ValueError, AttributeError):
        return None
    return surface, socket


def commands(event, surface):
    target = ["--target", surface]
    if event == "session_end":
        return [["status", "clear"] + target, ["progress", "clear"] + target]
    if event in ("user_prompt_submit", "start", "working", "pre_invocation",
                 "question_answered", "post_question"):
        return [
            ["status", "set", "working", "--text", "Thinking..."] + target,
            ["progress", "indeterminate"] + target,
        ]
    if event in ("stop", "done", "post_invocation"):
        return [["status", "set", "done"] + target,
                ["progress", "clear"] + target]
    if event in ("permission_request", "approval"):
        return [
            ["status", "set", "needs_approval", "--text", "Approval requested"] + target,
            ["progress", "pause"] + target,
            ["notify", "Approval requested", "--title", "Tako"] + target,
        ]
    if event in ("question", "waiting_for_input", "ask"):
        return [
            ["status", "set", "waiting_for_input", "--text", "Question"] + target,
            ["progress", "pause"] + target,
        ]
    return []


def dispatch(agent, event, env, payload=None):
    if agent not in ("codex", "claude", "agy", "antigravity", "gemini"):
        return
    tool = payload.get("tool_name") if isinstance(payload, dict) else None
    question_tools = {"AskUserQuestion", "ask_question", "request_user_input"}
    if event == "permission_request" and tool in question_tools:
        event = "waiting_for_input"
    # Some provider configs use PreToolUse for question events. Ordinary
    # tools must not mark the pane as waiting for a human answer.
    if event == "question" and tool is not None and tool not in question_tools:
        return
    if not commands(event, ""):
        return
    binding = recipient(env)
    if binding is None:
        return
    surface, _ = binding
    cli = shutil.which("takoctl", path=env.get("PATH", os.defpath))
    if not cli:
        return
    for args in commands(event, surface):
        try:
            # Keep inherited targeting: do not pass --socket.
            result = subprocess.run(
                [cli] + args, env=dict(env), stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                timeout=5, check=False,
            )
        except (OSError, subprocess.TimeoutExpired):
            return
        if result.returncode != 0:
            # Never retry with another instance or recipient.
            return


def main(argv=None):
    args = sys.argv[1:] if argv is None else argv
    if len(args) == 2:
        payload = None
        if not sys.stdin.isatty():
            try:
                payload = json.loads(sys.stdin.read(1024 * 1024))
            except ValueError:
                pass
        dispatch(args[0], args[1], os.environ, payload)
    # Providers expect a non-blocking JSON hook response, including no-op cases.
    print("{}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
