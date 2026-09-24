#!/usr/bin/env bash
# Build the terminal, prove it works, and put it in /Applications.
#
# For your own machine. Gatekeeper only questions an app that came from
# somewhere else, so an ad-hoc signature is enough here -- shipping it to
# anyone else means a Developer ID certificate and notarisation, which this
# script deliberately does not pretend to do.
#
# Refuses to replace a running copy with live shells in it: the last thing an
# update should do is take away the sessions you were working in.
set -euo pipefail
cd "$(dirname "$0")/.."

DEST="${DEST:-/Applications/Tako.app}"
BUILT="target/macapp/Tako.app"

running=$(pgrep -f "$DEST/Contents/MacOS/" 2>/dev/null | head -1 || true)
if [ -n "$running" ]; then
    shells=$(pgrep -P "$running" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$shells" != "0" ] && [ "${FORCE:-0}" != "1" ]; then
        echo "refusing to replace a running terminal with $shells live session(s)." >&2
        echo "close them, or re-run with FORCE=1 to end them." >&2
        exit 1
    fi
fi

echo "==> building"
python3 scripts/build-macapp.py

echo
echo "==> checking it actually works before installing it"
APP="$BUILT" ./scripts/selftest-macapp.sh

echo
echo "==> installing to $DEST"
[ -n "$running" ] && { pkill -f "$DEST/Contents/MacOS/" || true; sleep 2; }
mkdir -p "$(dirname "$DEST")"
rm -rf "$DEST"
cp -R "$BUILT" "$DEST"
codesign --force --deep --sign - "$DEST" >/dev/null 2>&1
# Only ever set on something downloaded; harmless, and clearing it keeps a
# locally built app from being questioned.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "installed: $DEST"
echo "open it from Launchpad, or: open -a '$DEST'"
