#!/bin/bash
# The session-persistence scenarios, each isolated: a copy of the app built
# with its session runtime under a bundle id of that scenario's run only (so
# its saved windows and Application Support are its own -- macOS keeps
# restoration state per bundle id beyond what deleting its saved-state
# folder clears) and a fresh session home. Everything a run creates --
# sessions, saved state, records -- is removed afterwards, whatever the
# outcome; nothing of a real Tako's is read or touched.
#
#   ./scripts/e2e-persist.sh            # every persistence scenario
#   ./scripts/e2e-persist.sh persist-live
set -euo pipefail
cd "$(dirname "$0")/.."

[ $# -gt 0 ] || set -- persist-live persist-gone persist-close persist-cancel persist-close-asks persist-close-quit
export TAKO_APP_DIR=target/macapp-persist TAKO_WITH_ZMX=1
APP="$TAKO_APP_DIR/Tako.app"

run_one() {
    local scenario=$1
    local bundle="com.tako-core.terminal.e2e-persist-$(date +%s)-$$"
    local state="$HOME/Library/Saved Application State/$bundle.savedState"
    local support="$HOME/Library/Application Support/$bundle"
    # Short: socket paths under it must stay within macOS's 104 bytes.
    local sessions
    sessions=$(mktemp -d /tmp/tkp.XXXXXX)
    cleanup_one() {
        local zmx="$APP/Contents/Helpers/zmx"
        for dir in "$sessions"/.tako-sessions/*/; do
            [ -d "$dir" ] || continue
            for name in $(ZMX_DIR="$dir" "$zmx" list --short 2>/dev/null); do
                ZMX_DIR="$dir" "$zmx" kill "$name" --force >/dev/null 2>&1 || true
            done
        done
        rm -rf "$sessions" "$state" "$support"
    }
    trap cleanup_one EXIT
    # Called on the left of ||, so errexit does not apply here: every step
    # that must stop the run checks its own status.
    if ! TAKO_BUNDLE_ID=$bundle python3 scripts/build-macapp.py >/dev/null; then
        echo "FAIL  $scenario: the app could not be built" >&2
        cleanup_one
        trap - EXIT
        return 1
    fi
    if [ "$(defaults read "$PWD/$APP/Contents/Info" CFBundleIdentifier 2>/dev/null)" != "$bundle" ]; then
        echo "FAIL  $scenario: the built app is not this run's ($bundle)" >&2
        cleanup_one
        trap - EXIT
        return 1
    fi
    local status=0
    APP="$APP" TAKO_SESSIONS_HOME="$sessions" scripts/e2e-macapp.sh "$scenario" || status=$?
    cleanup_one
    trap - EXIT
    return $status
}

failed=0
for scenario in "$@"; do
    run_one "$scenario" || failed=1
done
exit $failed
