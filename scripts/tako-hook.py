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
import signal
import subprocess
import sys
import time
import uuid
import json
import re

# Claude Code fires no hook when the user stops a turn ("Stop does not run if
# the stoppage occurred due to a user interrupt"), but writes this line to the
# turn's transcript the moment it happens. A watcher the prompt's hook starts
# reads the transcript for it; Stop, the next prompt or the session's end
# retires the watcher.
INTERRUPT_MARK = "[Request interrupted by user"
WATCH_POLL = 0.2
WATCH_LIFETIME = 12 * 3600


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
    # The user stopped the turn (Codex's Interrupt hook): no Stop follows,
    # so this is the one event that ends the turn.
    if event == "interrupt":
        return [["status", "set", "idle"] + target,
                ["progress", "clear"] + target]
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


def watcher_pidfile(surface, env):
    home = env.get("HOME") or os.path.expanduser("~")
    return os.path.join(home, ".local", "state", "tako-hook", "claude-%s.pid" % surface)


def stop_watcher(surface, env):
    path = watcher_pidfile(surface, env)
    try:
        with open(path) as handle:
            pid = int(handle.read().strip())
    except (OSError, ValueError):
        return
    try:
        os.unlink(path)
    except OSError:
        pass
    if pid != os.getpid():
        try:
            os.kill(pid, signal.SIGTERM)
        except OSError:
            pass


def start_watcher(surface, env, payload):
    transcript = payload.get("transcript_path") if isinstance(payload, dict) else None
    if not isinstance(transcript, str) or not os.path.isabs(transcript):
        return
    stop_watcher(surface, env)
    try:
        offset = os.path.getsize(transcript)
    except OSError:
        offset = 0
    path = watcher_pidfile(surface, env)
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        # Its own session: the agent does not wait for it, and it outlives
        # the hook that started it.
        child = subprocess.Popen(
            [sys.executable, os.path.abspath(__file__), "claude", "watch-interrupt",
             transcript, str(offset)],
            env=dict(env), stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL, start_new_session=True, close_fds=True)
        with open(path, "w") as handle:
            handle.write(str(child.pid))
    except OSError:
        return


def interrupted(entry):
    """Whether a transcript line is Claude Code's record of a user stop."""
    if not isinstance(entry, dict) or entry.get("type") != "user":
        return False
    content = (entry.get("message") or {}).get("content")
    if isinstance(content, str):
        texts = [content]
    elif isinstance(content, list):
        texts = [part.get("text", "") for part in content
                 if isinstance(part, dict) and part.get("type") == "text"]
    else:
        texts = []
    return any(isinstance(text, str) and text.startswith(INTERRUPT_MARK) for text in texts)


def watch_interrupt(transcript, offset, env, sleep=time.sleep, clock=time.monotonic,
                    lifetime=WATCH_LIFETIME):
    """Reads what the transcript gains after `offset`; on a user stop, ends
    the turn's status. True when it saw one."""
    started, pending = clock(), b""
    while clock() - started < lifetime:
        try:
            with open(transcript, "rb") as handle:
                handle.seek(offset)
                chunk = handle.read()
        except OSError:
            chunk = b""
        if chunk:
            offset += len(chunk)
            lines = (pending + chunk).split(b"\n")
            pending = lines.pop()
            for line in lines:
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                if interrupted(entry):
                    dispatch("claude", "interrupt", env)
                    return True
        sleep(WATCH_POLL)
    return False


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
    if agent == "claude":
        if event == "user_prompt_submit":
            start_watcher(surface, env, payload)
        elif event in ("stop", "done", "session_end"):
            stop_watcher(surface, env)
    pending = commands(event, surface)
    session_id = payload.get("session_id") if isinstance(payload, dict) else None
    if agent in ("claude", "codex") and isinstance(session_id, str) and re.fullmatch(r"[A-Za-z0-9_-]{1,128}", session_id):
        pending.append(["session", "note-agent", agent, session_id, "--target", surface])
    for args in pending:
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
    if len(args) == 4 and args[:2] == ["claude", "watch-interrupt"]:
        try:
            watch_interrupt(args[2], int(args[3]), os.environ)
        finally:
            binding = recipient(os.environ)
            if binding is not None:
                path = watcher_pidfile(binding[0], os.environ)
                try:
                    with open(path) as handle:
                        mine = handle.read().strip() == str(os.getpid())
                    if mine:
                        os.unlink(path)
                except OSError:
                    pass
        return 0
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
