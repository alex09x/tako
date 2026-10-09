#!/usr/bin/env bash
#
# tako — Terminal emulator
# Copyright (c) 2026 Alexander Panasenko
#
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT
#
# Run the macOS UI tests against the real app.
#
# By default, runs against the remote test Mac (Alexs-MacBook-Pro.local)
# via scripts/mac-remote.sh so your local screen and mouse are NOT disturbed.
# Pass --local to run on this machine instead.
#
# Usage:
#   ./scripts/uitest.sh                              # everything on remote Mac
#   ./scripts/uitest.sh TakoFeatureJourneysUITests   # one class on remote Mac
#   ./scripts/uitest.sh --local TakoTitleUITests     # run locally (takes screen focus)
#
set -euo pipefail

cd "$(dirname "$0")/.."

REMOTE="${TAKO_MAC:-alex09x@Alexs-MacBook-Pro.local}"
RUN_LOCAL=0
TEST_ARGS=()

if [ -n "${TAKO_REMOTE_EXEC:-}" ] || [ -n "${SSH_CLIENT:-}" ] || [ -n "${SSH_CONNECTION:-}" ]; then
    RUN_LOCAL=1
fi

for arg in "$@"; do
    case "$arg" in
        --local)
            RUN_LOCAL=1
            ;;
        *)
            TEST_ARGS+=("$arg")
            ;;
    esac
done

if [ $RUN_LOCAL -eq 0 ]; then
    echo "==> Running XCUITest remotely on $REMOTE (local screen stays untouched)..."
    export TAKO_MAC="$REMOTE"
    export TAKO_REMOTE_TIMEOUT="${TAKO_REMOTE_TIMEOUT:-600}"
    CMD="./scripts/uitest.sh --local"
    if [ ${#TEST_ARGS[@]} -gt 0 ]; then
        CMD="$CMD $(printf '%q ' "${TEST_ARGS[@]}")"
        CMD="${CMD% }"
    fi
    exec ./scripts/mac-remote.sh "$CMD"
fi

export TAKO_BUNDLE_ID="${TAKO_BUNDLE_ID:-com.tako-core.terminal.uitest}"
export TAKO_APP_DIR="${TAKO_APP_DIR:-target/macapp-uitest}"

PROJECT=macos_uitests/TakoUITests.xcodeproj
LOG=target/uitest.log
mkdir -p target

only=()
if [ ${#TEST_ARGS[@]} -gt 0 ]; then
    for t in "${TEST_ARGS[@]}"; do
        only+=("-only-testing:TakoUITests/$t")
    done
fi

echo "==> the screen will be driven for the next few minutes"
echo

RESULT_BUNDLE="target/uitest.xcresult"
rm -rf "$RESULT_BUNDLE"

set +e
xcodebuild test \
    -project "$PROJECT" \
    -scheme TakoUITests-Run \
    -destination platform=macOS \
    -resultBundlePath "$RESULT_BUNDLE" \
    ${only[@]+"${only[@]}"} 2>&1 | tee "$LOG" \
    | grep -E "^Test Case .*(passed|failed)|error: -\["
STATUS=${PIPESTATUS[0]}
set -e

echo
passed=$(grep -cE "^Test Case .* passed" "$LOG" || true)
failed=$(grep -cE "^Test Case .* failed" "$LOG" || true)
echo "passed=${passed:-0} failed=${failed:-0}"
echo "Full log: $LOG"
echo "Result bundle: $RESULT_BUNDLE"

if [ $STATUS -ne 0 ] || [ "${failed:-0}" -gt 0 ] || [ "${passed:-0}" -eq 0 ]; then
    echo "FAIL: UI test run failed (exit=$STATUS, passed=${passed:-0}, failed=${failed:-0})" >&2
    exit 1
fi

