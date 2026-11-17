#!/usr/bin/env bash
# tako — macOS app self-tests
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT
#
# Does the built macOS app actually take input?
#
# The app carries `--selftest-keys`, `--selftest-input`, `--selftest-scroll`
# and `--selftest-frame`. Each runs as an explicit case of the e2e runner
# (scripts/e2e/ScenariosAppSelftests.swift), through its private launch,
# owned-process cleanup and kept-on-failure work directory, with the checks
# and deadlines this script used to apply itself. A failed mode does not stop
# the next one. `macapp self-test: ok` is printed only when every requested
# case reported ok exactly once (scripts/selftest_verdict.py).
#
#   ./scripts/selftest-macapp.sh                 # keys, input, scroll, frame
#   ./scripts/selftest-macapp.sh --scroll-only   # scroll
#
# The runner drives the app by its bundle identifier and resets that
# identifier's defaults. A test bundle runs as it is, under its own
# identifier (TAKO_BUNDLE_ID, when set, must name it). An app with the
# production identifier is never launched under it: a disposable ad-hoc
# resealed copy with a fresh e2e identifier runs instead; the original bundle
# is not touched.
set -euo pipefail
cd "$(dirname "$0")/.."

case "${1:-}" in
    "") names=(app-selftest-keys app-selftest-input app-selftest-scroll app-selftest-frame) ;;
    --scroll-only) names=(app-selftest-scroll) ;;
    *) echo "usage: $0 [--scroll-only]" >&2; exit 2 ;;
esac

# Off any external volume, where macOS would ask for access on every build.
APP="${APP:-${TAKO_APP_DIR:-$(python3 scripts/app_locations.py dir macapp)}/Tako.app}"
[ -d "$APP" ] || { echo "no app at $APP; run scripts/build-macapp.py first" >&2; exit 1; }
python3 scripts/app_locations.py check-app "$APP"

production=com.tako-core.terminal
actual=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist") \
    || { echo "FAIL: $APP has no bundle identifier" >&2; exit 1; }
if [ -n "${TAKO_BUNDLE_ID:-}" ] && [ "$TAKO_BUNDLE_ID" != "$actual" ]; then
    echo "FAIL: TAKO_BUNDLE_ID=$TAKO_BUNDLE_ID but $APP is $actual; nothing was launched" >&2
    exit 1
elif [ "$actual" = "$production" ]; then
    copies="$(python3 scripts/app_locations.py dir selftest-copies)"
    mkdir -p "$copies"
    copies=$(cd "$copies" && pwd -P)
    copy_dir=$(mktemp -d "$copies/run.XXXXXX")
    TAKO_BUNDLE_ID="com.tako-core.terminal.e2e-selftest-$(basename "$copy_dir" | tr -cd 'A-Za-z0-9')-$$"
    ditto "$APP" "$copy_dir/Tako.app"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $TAKO_BUNDLE_ID" "$copy_dir/Tako.app/Contents/Info.plist"
    codesign --force --sign - "$copy_dir/Tako.app" >/dev/null
    APP="$copy_dir/Tako.app"
    python3 scripts/app_locations.py check-app "$APP"
    echo "self-test: $actual is the production identifier; running a disposable copy as $TAKO_BUNDLE_ID ($APP)"
else
    TAKO_BUNDLE_ID="$actual"
fi
export TAKO_BUNDLE_ID

# One log per invocation: two runs never share or truncate each other's.
# The runner takes the GUI lock itself.
mkdir -p target
log=$(mktemp target/selftest-macapp-log.XXXXXX)
set +e
APP="$APP" ./scripts/e2e-macapp.sh "${names[@]}" 2>&1 | tee "$log"
statuses=("${PIPESTATUS[@]}")
set -e
echo
exec python3 scripts/selftest_verdict.py --status "${statuses[0]}" --tee-status "${statuses[1]}" --log "$log" "${names[@]}"
