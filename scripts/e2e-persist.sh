#!/bin/bash
# tako — Isolated session persistence tests
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT
#
# The session-persistence scenarios, each isolated: a copy of the app built
# with its session runtime under a bundle id of that scenario's run only (so
# its saved windows and Application Support are its own) and a fresh
# session home. Saved windows are removed with forget-saved-state.py: newer
# macOS keeps them outside ~/Library/Saved Application State. Nothing of a
# real Tako's is read or touched.
#
# What a case creates -- sessions, saved state, records -- is removed only
# after its cleanup is proved (scripts/e2e/persist-case.sh): its own runtimes
# stopped, nothing of it still running. A failed case, or one whose cleanup
# is in doubt, keeps all of it with its evidence under
# target/e2e-persist-evidence/<bundle>/, and the run stops there.
#
#   ./scripts/e2e-persist.sh            # every persistence scenario
#   ./scripts/e2e-persist.sh persist-live
set -euo pipefail
cd "$(dirname "$0")/.."
. scripts/e2e/persist-case.sh

[ $# -gt 0 ] || set -- persist-live persist-gone persist-close persist-cancel persist-close-asks persist-close-quit persist-second-owner persist-reflow
# The app is built and run from the startup disk, not from the checkout:
# every case reseals it under a bundle id of its own, so macOS sees a new
# app each time, and one launched from an external volume (the test Mac
# builds on one) asked anew on every case for access to that volume. One
# directory per checkout, so two checkouts never share a build.
PERSIST_ROOT="${TAKO_E2E_APP_ROOT:-$HOME/Library/Caches/tako-e2e}/$(printf '%s' "$PWD" | shasum -a 256 | cut -c1-12)"
export TAKO_APP_DIR="$PERSIST_ROOT/macapp-persist" TAKO_WITH_ZMX=1 TAKO_CODESIGN_IDENTITY=-
APP="$TAKO_APP_DIR/Tako.app"
# Bundle identity is metadata, not a Swift compile input. Build once, then
# reseal only that metadata per scenario; inner executable bytes stay fixed.
TAKO_BUNDLE_ID="com.tako-core.terminal.e2e-persist-build-$$" python3 scripts/build-macapp.py
export PERSIST_ZMX="$APP/Contents/Helpers/zmx" PERSIST_FORGET="scripts/e2e/forget-saved-state.py"
APPEXE="$APP/Contents/MacOS/Tako"

# Called on the left of ||, so errexit does not apply here: every step
# checks its own status.
run_one() {
    local scenario=$1
    local bundle="com.tako-core.terminal.e2e-persist-$(date +%s)-$$"
    local support="$HOME/Library/Application Support/$bundle"
    local evidence="$PWD/target/e2e-persist-evidence/$bundle"
    mkdir -p "$evidence" || return 1
    # Short: socket paths under it must stay within macOS's 104 bytes.
    local sessions
    sessions=$(mktemp -d /tmp/tkp.XXXXXX) || return 1
    printf 'scenario %s\nbundle %s\nsessions %s\nsupport %s\n' "$scenario" "$bundle" "$sessions" "$support" > "$evidence/identity.txt"
    local status=0
    if ! /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle" "$APP/Contents/Info.plist" \
        || ! codesign --force --sign - "$APP"; then
        echo "FAIL  $scenario: the isolated app could not be resealed" >&2
        status=1
    elif [ "$(defaults read "$APP/Contents/Info" CFBundleIdentifier 2>/dev/null)" != "$bundle" ]; then
        echo "FAIL  $scenario: the built app is not this run's ($bundle)" >&2
        status=1
    else
        APP="$APP" TAKO_BUNDLE_ID="$bundle" TAKO_SESSIONS_HOME="$sessions" scripts/e2e-macapp.sh "$scenario" 2>&1 \
            | tee "$evidence/runner.log"
        status=${PIPESTATUS[0]}
    fi
    persist_finish "$status" "$sessions" "$support" "$bundle" "$APPEXE" "$evidence"
}

failed=0
for scenario in "$@"; do
    if ! run_one "$scenario"; then
        failed=1
        # What ran may still run: no further case on top of it.
        echo "e2e-persist: stopping after $scenario; its state and evidence are kept" >&2
        break
    fi
done
exit $failed
