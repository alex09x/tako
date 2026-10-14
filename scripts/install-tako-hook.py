#!/usr/bin/env python3
# tako — Atomic installation of the owned lifecycle dispatcher
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT

import argparse
import hashlib
import os
from pathlib import Path
import tempfile


def install(destination, source_name="tako-hook.py"):
    source = Path(__file__).with_name(source_name).read_bytes()
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.is_symlink():
        raise RuntimeError("Refusing to replace a symlink dispatcher")
    previous = destination.read_bytes() if destination.exists() else None
    if previous == source:
        print("Dispatcher already matches repository source")
        return
    if previous is not None:
        digest = hashlib.sha256(previous).hexdigest()
        backup = destination.with_name(destination.name + ".backup-" + digest[:16])
        if not backup.exists():
            with backup.open("xb") as output:
                os.chmod(backup, 0o600)
                output.write(previous)
        elif backup.is_symlink() or backup.read_bytes() != previous:
            raise RuntimeError("Existing backup does not match installed dispatcher")
    fd, temporary = tempfile.mkstemp(prefix=".tako-hook-", dir=destination.parent)
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(source)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary, 0o755)
        current = destination.read_bytes() if destination.exists() else None
        if destination.is_symlink() or current != previous:
            raise RuntimeError("Dispatcher changed during installation; retry after coordination")
        os.replace(temporary, destination)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print("Installed dispatcher SHA256 " + hashlib.sha256(source).hexdigest())


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--destination", type=Path,
                        default=Path.home() / ".local/bin/tako-hook")
    parser.add_argument("--codex-wrapper", action="store_true")
    options = parser.parse_args()
    destination = options.destination
    install(destination.with_name("tako_hook_context.py"), "tako_hook_context.py")
    install(destination)
    if options.codex_wrapper:
        if not destination.with_name("codex").exists():
            raise RuntimeError("Codex vendor launcher is absent")
        install(destination.with_name("tako-codex"), "tako-codex.py")
        fish_function = Path.home() / ".config/fish/functions/codex.fish"
        fish_source = Path(__file__).with_name("tako-codex.fish").read_bytes()
        if fish_function.exists() and fish_function.read_bytes() != fish_source:
            raise RuntimeError("Existing Codex fish function belongs to the user; not overwritten")
        if not fish_function.exists():
            install(fish_function, "tako-codex.fish")
