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
# A private host (--host-id=SUFFIX) builds and drives com.tako-core.terminal.uitest.SUFFIX
# with its own defaults suite, app and derived-data directories, and a runner signed for
# that host only. The shared host, its suite and its profile are snapshotted before and
# after; any change to them fails the run (never rolled back, never attributed). The
# private host must have no app and no runtime in its profile before the run and after
# it; leftovers fail the run and are reported, never killed or deleted.
#   ./scripts/uitest.sh --local --host-id=run-1 --build-only
#   ./scripts/uitest.sh --local --host-id=run-1 --without-building TakoControlCLIUITests
#
set -euo pipefail

cd "$(dirname "$0")/.."

REMOTE="${TAKO_MAC:-alex09x@Alexs-MacBook-Pro.local}"
RUN_LOCAL=0
BUILD_ONLY=0
WITHOUT_BUILDING=0
HOST_SUFFIX=""
TEST_ARGS=()

if [ -n "${TAKO_REMOTE_EXEC:-}" ] || [ -n "${SSH_CLIENT:-}" ] || [ -n "${SSH_CONNECTION:-}" ]; then
    RUN_LOCAL=1
fi

for arg in "$@"; do
    case "$arg" in
        --local)
            RUN_LOCAL=1
            ;;
        --build-only)
            BUILD_ONLY=1
            ;;
        --without-building)
            WITHOUT_BUILDING=1
            ;;
        --host-id=*)
            HOST_SUFFIX="${arg#--host-id=}"
            [ -n "$HOST_SUFFIX" ] || { echo "FAIL: --host-id needs a suffix" >&2; exit 2; }
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
    if [ $BUILD_ONLY -eq 1 ]; then CMD="$CMD --build-only"; fi
    if [ $WITHOUT_BUILDING -eq 1 ]; then CMD="$CMD --without-building"; fi
    if [ -n "$HOST_SUFFIX" ]; then CMD="$CMD $(printf '%q' "--host-id=$HOST_SUFFIX")"; fi
    if [ ${#TEST_ARGS[@]} -gt 0 ]; then
        CMD="$CMD $(printf '%q ' "${TEST_ARGS[@]}")"
        CMD="${CMD% }"
    fi
    if [ -n "${TAKO_UI_SCHEME:-}" ]; then
        printf -v CMD 'TAKO_UI_SCHEME=%q %s' "$TAKO_UI_SCHEME" "$CMD"
    fi
    exec ./scripts/mac-remote.sh "$CMD"
fi

export TAKO_BUNDLE_ID="${TAKO_BUNDLE_ID:-com.tako-core.terminal.uitest}"
export TAKO_APP_DIR="${TAKO_APP_DIR:-target/macapp-uitest}"
# The project's build phase stages the host in target/macapp-uitest and
# copies it into DerivedData, which is what runs: the host and the runner
# both run off any external volume (scripts/app_locations.py). Results stay
# under target/uitest-results.
DERIVED="${TAKO_UITEST_DERIVED:-$(python3 scripts/app_locations.py dir uitest-derived)}"
python3 scripts/app_locations.py check-app "$DERIVED"

PROJECT=macos_uitests/TakoUITests.xcodeproj
mkdir -p target/uitest-results
RUN_DIR=$(mktemp -d target/uitest-results/run.XXXXXX)
LOG="$RUN_DIR/uitest.log"
echo "Run evidence: $RUN_DIR"

PRIVATE_SETTINGS=()
if [ -n "$HOST_SUFFIX" ]; then
    NAMES=$(python3 scripts/uitest_host_identity.py names "$HOST_SUFFIX")
    read -r HOST_ID SUITE <<<"$NAMES"
    export TAKO_BUNDLE_ID="$HOST_ID"
    export TAKO_APP_DIR="$(python3 scripts/app_locations.py dir "macapp-uitest-$HOST_SUFFIX")"
    DERIVED="$(python3 scripts/app_locations.py dir "uitest-derived-$HOST_SUFFIX")"
    python3 scripts/app_locations.py check-app "$DERIVED"
    python3 scripts/uitest_host_identity.py entitlements \
        --template macos_uitests/TakoUITests/TakoUITests.entitlements \
        --suffix "$HOST_SUFFIX" --out "$RUN_DIR/runner.entitlements"
    # Admission: the private host has no registered app and no process (e.g. a
    # zmx runtime) running from its profile, which the tests would remove under it.
    # Leftovers are reported, never killed or deleted.
    set +e
    python3 scripts/uitest_host_identity.py census "$HOST_ID" --out "$RUN_DIR/private-host-census-before.json"
    CENSUS=$?
    set -e
    if [ $CENSUS -eq 3 ]; then
        echo "FAIL: $HOST_ID still has an app or a runtime; nothing was built or launched." >&2
        echo "      Evidence: $RUN_DIR/private-host-census-before.json" >&2
        exit 2
    elif [ $CENSUS -ne 0 ]; then
        echo "FAIL: could not take the census of $HOST_ID; nothing was built or launched." >&2
        exit 2
    fi
    if ! python3 scripts/uitest_host_identity.py snapshot --out "$RUN_DIR/shared-host-before.json"; then
        echo "FAIL: could not snapshot the shared host; nothing was built or launched." >&2
        exit 2
    fi
    PRIVATE_SETTINGS=(TAKO_UITEST_HOST_ID="$HOST_ID" TAKO_UITEST_APP_DIR="$TAKO_APP_DIR"
                      TAKO_UITEST_RUNNER_ENTITLEMENTS="$PWD/$RUN_DIR/runner.entitlements")
    # xcodebuild hands TEST_RUNNER_* to the runner without the prefix.
    export TEST_RUNNER_TAKO_UITEST_HOST_ID="$HOST_ID" TEST_RUNNER_TAKO_UITEST_DEFAULTS_SUITE="$SUITE"
    echo "==> private host $HOST_ID, suite $SUITE, app $TAKO_APP_DIR, derived $DERIVED"
fi

only=()
if [ ${#TEST_ARGS[@]} -gt 0 ]; then
    for t in "${TEST_ARGS[@]}"; do
        only+=("-only-testing:TakoUITests/$t")
    done
fi

ACTION=test
SUCCEEDED='** TEST SUCCEEDED **'
if [ $WITHOUT_BUILDING -eq 1 ]; then
    ACTION=test-without-building
    SUCCEEDED='** TEST EXECUTE SUCCEEDED **'
fi
if [ $BUILD_ONLY -eq 1 ]; then
    ACTION=build-for-testing
    echo "==> compile the real UI target only; no UI tests will execute"
else
    MODE=$(/usr/bin/automationmodetool status 2>&1)
    if [[ "$MODE" == *"Automation Mode is disabled"* && "$MODE" == *"requires user authentication"* ]]; then
        echo "FAIL: macOS Automation Mode is disabled; no XCUITest executed. Administrator authorization is required on the test Mac." >&2
        exit 3
    fi
    # The tests read the source tree while they run: from an external
    # volume that would ask for access, so refuse before anything launches.
    python3 scripts/app_locations.py check-source uitest
    echo "==> the isolated test app will drive the screen"
fi
echo

RESULT_BUNDLE="$RUN_DIR/tests.xcresult"

set +e
python3 scripts/gui_lock.py -- python3 scripts/ci-swift-watchdog.py \
    --diagnostics-dir "$RUN_DIR/stall" -- xcodebuild "$ACTION" \
    -project "$PROJECT" \
    -scheme "${TAKO_UI_SCHEME:-TakoUITests-Run}" \
    -derivedDataPath "$DERIVED" \
    -destination platform=macOS \
    -parallel-testing-enabled NO \
    -resultBundlePath "$RESULT_BUNDLE" \
    ${PRIVATE_SETTINGS[@]+"${PRIVATE_SETTINGS[@]}"} \
    ${only[@]+"${only[@]}"} 2>&1 | tee "$LOG" \
    | grep -E "^Test Case .*(passed|failed|skipped)|error:|^\*\* (BUILD|TEST)|^\[xcui progress|^\[swift watchdog\]"
STATUS=${PIPESTATUS[0]}
set -e

if [ -n "$HOST_SUFFIX" ]; then
    if ! python3 scripts/uitest_host_identity.py snapshot --out "$RUN_DIR/shared-host-after.json"; then
        echo "FAIL: could not snapshot the shared host after this run; its state is unknown." >&2
        exit 4
    fi
    if ! cmp -s "$RUN_DIR/shared-host-before.json" "$RUN_DIR/shared-host-after.json"; then
        echo "FAIL: the shared host, its suite or its profile changed during this run." >&2
        echo "      Not attributed to the run and nothing was rolled back:" >&2
        diff "$RUN_DIR/shared-host-before.json" "$RUN_DIR/shared-host-after.json" >&2 || true
        exit 4
    fi
    echo "==> shared host unchanged: $RUN_DIR/shared-host-{before,after}.json"
    set +e
    python3 scripts/uitest_host_identity.py census "$HOST_ID" --out "$RUN_DIR/private-host-census-after.json"
    CENSUS=$?
    set -e
    if [ $CENSUS -eq 3 ]; then
        echo "FAIL: $HOST_ID left an app or a runtime behind; nothing was killed or deleted." >&2
        echo "      Evidence: $RUN_DIR/private-host-census-after.json" >&2
        exit 5
    elif [ $CENSUS -ne 0 ]; then
        echo "FAIL: could not take the census of $HOST_ID after this run." >&2
        exit 5
    fi
fi

echo
if [ $BUILD_ONLY -eq 1 ]; then
    if [ $STATUS -ne 0 ] || grep -q 'placeholder host app was kept' "$LOG"; then
        echo "FAIL: UI target or real host app did not compile. Full log: $LOG" >&2
        exit 1
    fi
    echo "COMPILED ONLY: UI target and real host app built; XCUITest execution was not performed."
    echo "Full log: $LOG"
    echo "Build result bundle: $RESULT_BUNDLE"
    exit 0
fi
passed=$(grep -cE "^Test Case .* passed" "$LOG" || true)
failed=$(grep -cE "^Test Case .* failed" "$LOG" || true)
skipped=$(grep -cE "^Test Case .* skipped" "$LOG" || true)
echo "passed=${passed:-0} failed=${failed:-0} skipped=${skipped:-0}"
echo "Full log: $LOG"
echo "Result bundle: $RESULT_BUNDLE"

if [ $STATUS -ne 0 ] || [ "${failed:-0}" -gt 0 ] || [ "${passed:-0}" -eq 0 ] \
    || ! grep -qxF "$SUCCEEDED" "$LOG"; then
    echo "FAIL: UI test run failed (exit=$STATUS, passed=${passed:-0}, failed=${failed:-0})" >&2
    exit 1
fi

