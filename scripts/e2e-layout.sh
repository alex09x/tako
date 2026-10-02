#!/bin/bash
# The window-layout scenarios, each isolated the way the persistence ones
# are (see e2e-persist.sh): a copy of the app under a bundle id of that run
# only, because macOS keeps restoration state per bundle id beyond what
# deleting its saved-state folder clears, and a run that restores windows
# would otherwise inherit every earlier run's. Its saved state and
# Application Support are removed afterwards, whatever the outcome.
#
#   ./scripts/e2e-layout.sh             # every layout scenario
#   ./scripts/e2e-layout.sh crash-layout
set -euo pipefail
cd "$(dirname "$0")/.."

[ $# -gt 0 ] || set -- crash-layout crash-again crash-corrupt quit-layout
export TAKO_APP_DIR=target/macapp-layout
APP="$TAKO_APP_DIR/Tako.app"

run_one() {
    local scenario=$1
    local bundle="com.tako-core.terminal.e2e-layout-$(date +%s)-$$"
    local state="$HOME/Library/Saved Application State/$bundle.savedState"
    local support="$HOME/Library/Application Support/$bundle"
    cleanup_one() { rm -rf "$state" "$support"; }
    trap cleanup_one EXIT
    if ! TAKO_BUNDLE_ID=$bundle python3 scripts/build-macapp.py >/dev/null; then
        echo "FAIL  $scenario: the app could not be built" >&2
        cleanup_one; trap - EXIT; return 1
    fi
    if [ "$(defaults read "$PWD/$APP/Contents/Info" CFBundleIdentifier 2>/dev/null)" != "$bundle" ]; then
        echo "FAIL  $scenario: the built app is not this run's ($bundle)" >&2
        cleanup_one; trap - EXIT; return 1
    fi
    local status=0
    APP="$APP" scripts/e2e-macapp.sh "$scenario" || status=$?
    cleanup_one
    trap - EXIT
    return $status
}

failed=0
for scenario in "$@"; do
    run_one "$scenario" || failed=1
done
exit $failed
