# tako — Explicit session bindings and managed hook credentials
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT

import hashlib
import json
import os
import shlex
import subprocess
import uuid
import socket

SERVICE = "com.tako-core.terminal.hook-bindings.v1"


def read_binding(account):
    try:
        result = subprocess.run(
            ["/usr/bin/security", "find-generic-password", "-s", SERVICE,
             "-a", account, "-w"], capture_output=True, text=True, timeout=3,
        )
        if result.returncode == 0:
            return json.loads(result.stdout)
    except (OSError, ValueError, subprocess.TimeoutExpired):
        pass
    return None


def write_binding(account, binding):
    # Feed the secret over stdin, never a process argument or a log file.
    line = shlex.join(["add-generic-password", "-U", "-s", SERVICE,
                       "-a", account, "-w", json.dumps(binding)]) + "\n"
    result = subprocess.run(["/usr/bin/security", "-i"], input=line,
                            capture_output=True, text=True, timeout=10)
    if result.returncode != 0 or read_binding(account) != binding:
        raise RuntimeError("Could not persist the session binding in Keychain")


def valid_binding(binding):
    if not isinstance(binding, dict) or binding.get("scopes") != ["signal"]:
        return False
    try:
        uuid.UUID(binding["surface"])
        return (os.path.isabs(binding["socket"]) and
                len(binding["token"]) == 64 and
                all(c in "0123456789abcdef" for c in binding["token"]))
    except (KeyError, TypeError, ValueError):
        return False


def bootstrap(agent, env, payload):
    """Enroll a new terminal using only the authority it already inherited."""
    surface, path = env.get("TAKO_SURFACE_ID"), env.get("TAKO_SOCKET")
    token = env.get("TAKO_CONTROL_TOKEN", env.get("TAKO_AUTH_TOKEN", ""))
    try:
        surface = str(uuid.UUID(surface))
    except (TypeError, ValueError, AttributeError):
        return None
    if not path or not os.path.isabs(path) or len(token) != 64:
        return None
    # Never replace an existing enrollment or refresh a different caller.
    if read_binding("surface:" + surface) is not None:
        return None
    request = {"cmd": "grant", "token": token, "from": surface, "scopes": ["approval"],
               "args": {"subcommand": "create", "client": "tako-hook-" + surface,
                        "scopes": ["signal"], "description": "Terminal lifecycle hook"}}
    try:
        with socket.socket(socket.AF_UNIX) as client:
            client.settimeout(3)
            client.connect(path)
            client.sendall(json.dumps(request).encode() + b"\n")
            response = json.loads(client.makefile("rb").readline(1024 * 1024))
        if not response.get("ok"):
            return None
        binding = {"surface": surface, "socket": path, "token": response["result"]["token"],
                   "scopes": ["signal"], "bundle_id": env.get("TAKO_BUNDLE_ID", "com.tako-core.terminal"),
                   "retired_grant_sha256": hashlib.sha256(token.encode()).hexdigest()}
        if not valid_binding(binding):
            return None
        write_binding("surface:" + surface, binding)
        if agent == "codex" and isinstance(payload, dict):
            session = payload.get("session_id") or payload.get("thread_id")
            if session:
                write_binding("codex:" + str(uuid.UUID(session)), binding)
        return binding
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.TimeoutExpired):
        return None


def resolve(agent, env, payload):
    """Refresh only an explicitly registered session, not an arbitrary caller."""
    surface, socket = env.get("TAKO_SURFACE_ID"), env.get("TAKO_SOCKET")
    if surface and socket:
        binding = read_binding("surface:" + surface.lower())
        inherited = env.get("TAKO_CONTROL_TOKEN", env.get("TAKO_AUTH_TOKEN", ""))
        if valid_binding(binding) and binding["socket"] == socket:
            digest = hashlib.sha256(inherited.encode()).hexdigest()
            # Only replace the exact retired grant enrolled by the operator.
            if digest == binding.get("retired_grant_sha256"):
                return binding
        return None
    if agent != "codex" or not isinstance(payload, dict):
        return None
    session = payload.get("session_id") or payload.get("thread_id")
    if not isinstance(session, str):
        return None
    try:
        session = str(uuid.UUID(session))
    except ValueError:
        return None
    binding = read_binding("codex:" + session)
    return binding if valid_binding(binding) else None
