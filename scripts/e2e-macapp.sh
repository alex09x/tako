#!/usr/bin/env bash
# Drive the built macOS app with real key presses and clicks, and check what
# the shell inside it received. See scripts/e2e/tako-e2e.swift.
#
#   ./scripts/e2e-macapp.sh                # every scenario
#   ./scripts/e2e-macapp.sh paste copy     # only these
#
# Needs the logged-in GUI session of the test Mac and Accessibility
# permission for the process running it. Tako is brought to the front while
# it runs, and the app that was in front gets the focus back at the end.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${APP:-target/macapp/Tako.app}"
[ -d "$APP" ] || { echo "no app at $APP; run scripts/build-macapp.py first" >&2; exit 1; }

mkdir -p target
swiftc -O -o target/tako-e2e scripts/e2e/tako-e2e.swift
exec target/tako-e2e "$APP" "$@"
