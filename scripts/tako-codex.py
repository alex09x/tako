#!/usr/bin/env python3
# tako — Keep new terminal Codex hooks inside their originating PTY
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT

import os
from pathlib import Path
import sys
import uuid


def provider_args(args, env):
    try:
        uuid.UUID(env.get("TAKO_SURFACE_ID", ""))
        inside = os.path.isabs(env.get("TAKO_SOCKET", ""))
    except ValueError:
        inside = False
    return (["--no-daemon"] if inside and "--no-daemon" not in args else []) + list(args)


if __name__ == "__main__":
    original = Path.home() / ".local/bin/codex"
    os.execv(str(original), [str(original)] + provider_args(sys.argv[1:], os.environ))
