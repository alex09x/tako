#!/usr/bin/env python3
"""Tako — Sign a downloaded candidate without rebuilding its executables.

Copyright (c) 2026 Alexander Panasenko
Contact: alex@prod.codes
Author: https://prod.codes/about/
Project: https://github.com/alex09x/tako
SPDX-License-Identifier: MIT
"""

import argparse
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys

from macapp_signing import candidate_source, sign_bundle, verify_source_checkout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path, help="extracted candidate Tako.app")
    parser.add_argument("--identity", help="Developer ID name or certificate fingerprint; defaults to login keychain")
    parser.add_argument("--notarize", action="store_true", help="also notarize and package with release-macapp.py")
    parser.add_argument("--notary-profile", default="tako", help="existing notarytool keychain profile")
    parser.add_argument("--candidate-metadata", type=Path, help="downloaded candidate.json; source/version/build must match")
    args = parser.parse_args()
    app = args.app.resolve()
    if Path("/Applications") in app.parents or Path.home() / "Applications" in app.parents:
        parser.error("sign an extracted candidate, not an installed application")
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if not info.get("CFBundleIdentifier", "").startswith("com.tako-core.terminal"):
        parser.error("this is not a Tako candidate")
    source = candidate_source(info, args.candidate_metadata)
    if args.notarize:
        verify_source_checkout(source, Path(__file__).resolve().parent.parent)
    identity = args.identity or os.environ.get("TAKO_CODESIGN_IDENTITY")
    if not identity:
        result = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"],
                                check=True, capture_output=True, text=True)
        identity = next((name for name in re.findall(r'"([^"]+)"', result.stdout)
                         if name.startswith("Developer ID Application:")), None)
    if not identity or identity == "-":
        parser.error("a Developer ID Application certificate is required in the local keychain")
    digest = sign_bundle(app, identity)
    signed = subprocess.run(["codesign", "-dv", "--verbose=4", str(app)],
                            check=True, capture_output=True, text=True)
    if "Authority=Developer ID Application" not in signed.stderr:
        raise ValueError("the selected identity is not Developer ID Application; candidate is not distributable")
    print(f"Signed {app.name} {info['CFBundleShortVersionString']} ({info['CFBundleVersion']})")
    if digest:
        print(f"Verified runtime SHA-256: {digest}")
    if args.notarize:
        env = os.environ.copy()
        env["TAKO_APP_DIR"] = str(app.parent)
        env["TAKO_NOTARY_PROFILE"] = args.notary_profile
        env["GITHUB_SHA"] = source
        env["TAKO_VERSION"] = info["CFBundleShortVersionString"]
        subprocess.run([sys.executable, str(Path(__file__).with_name("release-macapp.py"))],
                       env=env, check=True)
    else:
        print("Notarization is still required before public distribution; use --notarize.")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
