#!/usr/bin/env python3
"""Removes the windows macOS saved for an app, so a test launch restores none.

Usage: forget-saved-state.py <signing identifier>

Older macOS keeps them in ~/Library/Saved Application State/<id>.savedState.
Newer macOS keeps them in the container of its talagent daemon, in a folder
named by a UUID that ApplicationMapping.plist maps to the app's signing
identifier (for an ad-hoc build, its bundle id) -- deleting the old path does
nothing there. Both are removed. The mapping itself is left alone: macOS owns
it and finds the folder gone on the next save.
"""
import glob
import os
import plistlib
import shutil
import sys


def main(identifier):
    library = os.path.expanduser("~/Library")
    doomed = [os.path.join(library, "Saved Application State", identifier + ".savedState")]
    pattern = os.path.join(library, "Daemon Containers", "*", "Data", "Library",
                           "Saved Application State", "ApplicationMapping.plist")
    for mapping in glob.glob(pattern):
        try:
            with open(mapping, "rb") as f:
                entries = plistlib.load(f)
        except Exception:
            continue
        # A flat list: an app's description, then the UUID of its folder.
        for app, uuid in zip(entries[0::2], entries[1::2]):
            signing = app.get("protected", {}).get("signingIdentifier") if isinstance(app, dict) else None
            if signing == identifier and isinstance(uuid, str):
                doomed.append(os.path.join(os.path.dirname(mapping), uuid + ".savedState"))
    for path in doomed:
        shutil.rmtree(path, ignore_errors=True)


if __name__ == "__main__":
    if len(sys.argv) != 2 or not sys.argv[1]:
        sys.exit(__doc__)
    main(sys.argv[1])
