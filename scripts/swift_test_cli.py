#!/usr/bin/env python3
# tako — Give Swift integration tests the verified shared takoctl
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT
"""Install the producer's CLI at the existing Swift tests' first lookup path.

No app is launched or resealed. Verify the full prebuilt contract first and
verify the copied CLI before atomically making it available to the tests.
"""
import os
from pathlib import Path
import shutil
import sys
import tempfile

import prebuilt


def install(directory, root=prebuilt.ROOT, verify=prebuilt.verify):
    manifest = verify(str(directory), False, root=str(root))
    relative = "Contents/MacOS/takoctl"
    source = Path(directory) / "Tako.app" / relative
    expected = manifest["app"][relative]
    if source.is_symlink() or not source.is_file() or not os.access(source, os.X_OK):
        raise prebuilt.Mismatch("the verified CLI is not a regular executable")
    destination = Path(root) / "takoctl/target/debug/takoctl"
    destination.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".takoctl-", dir=destination.parent)
    os.close(descriptor)
    try:
        shutil.copy2(source, temporary)
        if prebuilt.entry(temporary) != expected:
            raise prebuilt.Mismatch("the copied CLI differs from the verified prebuilt")
        os.replace(temporary, destination)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return destination


if __name__ == "__main__":
    try:
        destination = install(sys.argv[1])
        print(f"swift test CLI: verified {destination} sha256 {prebuilt.sha256(destination)}")
    except (prebuilt.Mismatch, OSError, ValueError, KeyError, IndexError) as error:
        print(f"FAIL: Swift test CLI: {error}; no Swift test was launched", file=sys.stderr)
        sys.exit(3)
