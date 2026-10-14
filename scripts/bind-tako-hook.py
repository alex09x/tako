#!/usr/bin/env python3
# tako — Enroll an explicit provider session for lifecycle status updates
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT

import argparse
import hashlib
import json
import os
import re
import subprocess
import uuid
import socket
from pathlib import Path

from tako_hook_context import write_binding


def enroll(args):
    surface = str(uuid.UUID(args.surface))
    # PID is chosen explicitly by the operator, never discovered heuristically.
    raw = subprocess.check_output(["ps", "-p", str(args.pid), "-ww", "-E"], text=True)
    context = {}
    for key in ("TAKO_SOCKET", "TAKO_SURFACE_ID", "TAKO_CONTROL_TOKEN", "TAKO_AUTH_TOKEN"):
        match = re.search(r"(?:^|\s)" + key + r"=([^\s]*)", raw)
        if match:
            context[key] = match.group(1)
    if context.get("TAKO_SURFACE_ID") != surface or context.get("TAKO_SOCKET") != args.socket:
        raise RuntimeError("Selected process does not belong to the explicit surface/socket")
    inherited = context.get("TAKO_CONTROL_TOKEN", context.get("TAKO_AUTH_TOKEN", ""))
    # --scope in older CLI builds attenuates the issuing request as well as
    # the new grant, dropping its required approval scope. Keep the two roles
    # distinct on the wire: the new grant's scopes live only in args.
    token = Path(args.socket + ".token").read_text().strip()
    request = {"cmd": "grant", "token": token, "from": surface, "scopes": ["approval"], "args": {
        "subcommand": "create", "client": "tako-hook-" + surface,
        "scopes": ["signal"], "description": "Explicit terminal lifecycle binding"}}
    with socket.socket(socket.AF_UNIX) as client:
        client.settimeout(5)
        client.connect(args.socket)
        client.sendall(json.dumps(request).encode() + b"\n")
        response = json.loads(client.makefile("rb").readline(1024 * 1024))
    if not response.get("ok"):
        raise RuntimeError("Server refused the scoped hook grant")
    binding = {"surface": surface, "socket": args.socket,
               "token": response["result"]["token"], "scopes": ["signal"],
               "bundle_id": args.bundle_id,
               "retired_grant_sha256": hashlib.sha256(inherited.encode()).hexdigest()}
    write_binding("surface:" + surface, binding)
    if args.session:
        write_binding("codex:" + str(uuid.UUID(args.session)), binding)
    print("Enrolled", surface, "with signal scope; credential retained in Keychain")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("surface", "socket", "cli", "bundle-id"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--session")
    enroll(parser.parse_args())
