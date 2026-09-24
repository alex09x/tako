#!/usr/bin/env bash
# Run the macOS UI tests against the real app.
#
# These are upstream's XCUITest suite, ported verbatim. They drive a running
# app through the accessibility tree: windows, tabs, menu items, the command
# palette, titlebar pixels.
#
# They are OFF by default, and deliberately. TakoCustomConfigCase returns
# an empty suite unless IDE_DISABLED_OS_ACTIVITY_DT_MODE is set -- a variable
# Xcode's IDE sets and xcodebuild does not -- which is upstream's own way of
# keeping a slow, click-driven suite out of unattended builds. This script
# uses the TakoUITests-Run scheme, which sets it.
#
#   ./scripts/uitest.sh                              # everything
#   ./scripts/uitest.sh TakoTitleUITests          # one class
#   ./scripts/uitest.sh TakoThemeTests/testIssue8282
#
# Running them TAKES OVER THE SCREEN: they type keystrokes, drag tabs and
# move windows. It needs a logged-in, unlocked session on a real display, with
# Accessibility and Automation permission granted, and nothing else stealing
# focus. Do not start a run and then walk off with the machine mid-task.
#
# The host app is rebuilt from scratch/build-macapp.py by a post-build script
# phase, so this always tests the current working tree.
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT=macos_uitests/TakoUITests.xcodeproj
LOG=target/uitest.log
mkdir -p target

only=()
for t in "$@"; do
    only+=("-only-testing:TakoUITests/$t")
done
# `${only[@]}` on an empty array is an unbound variable under `set -u` in
# bash 3.2, which is the bash macOS ships. Expanding it guarded is what lets
# this run with no arguments at all -- which, until now, it never had.

echo "==> the screen will be driven for the next few minutes"
echo

set +e
xcodebuild test \
    -project "$PROJECT" \
    -scheme TakoUITests-Run \
    -destination platform=macOS \
    ${only[@]+"${only[@]}"} 2>&1 | tee "$LOG" \
    | grep -E "^Test Case .*(passed|failed)|error: -\[" || true
set -e

echo
passed=$(grep -cE "^Test Case .* passed" "$LOG" || true)
failed=$(grep -cE "^Test Case .* failed" "$LOG" || true)
echo "passed=${passed:-0} failed=${failed:-0}"
echo "Full log: $LOG"
