#!/bin/bash
# The window-layout scenarios, each isolated the way the persistence ones
# are (see e2e-persist.sh): a copy of the app under a bundle id of that run
# only, so a run that restores windows never inherits another's. Saved
# windows are removed with forget-saved-state.py: newer macOS keeps them
# outside ~/Library/Saved Application State. Its saved state and
# Application Support are removed afterwards, whatever the outcome.
#
#   ./scripts/e2e-layout.sh             # every layout scenario
#   ./scripts/e2e-layout.sh crash-layout
set -euo pipefail
cd "$(dirname "$0")/.."

[ $# -gt 0 ] || set -- crash-layout crash-again crash-corrupt quit-layout upgrade-crash
# Off any external volume, where macOS would ask for access on every build.
TAKO_APP_DIR="$(python3 scripts/app_locations.py dir macapp-layout)"
case "$TAKO_APP_DIR" in /*) ;; *) TAKO_APP_DIR="$PWD/$TAKO_APP_DIR" ;; esac
export TAKO_APP_DIR
APP="$TAKO_APP_DIR/Tako.app"
python3 scripts/app_locations.py check-app "$APP"

run_one() {
    local scenario=$1
    local bundle="com.tako-core.terminal.e2e-layout-$(date +%s)-$$"
    local support="$HOME/Library/Application Support/$bundle"
    cleanup_one() { python3 scripts/e2e/forget-saved-state.py "$bundle"; rm -rf "$support"; }
    trap cleanup_one EXIT
    if ! TAKO_BUNDLE_ID=$bundle python3 scripts/build-macapp.py >/dev/null; then
        echo "FAIL  $scenario: the app could not be built" >&2
        cleanup_one; trap - EXIT; return 1
    fi
    if [ "$(defaults read "$APP/Contents/Info" CFBundleIdentifier 2>/dev/null)" != "$bundle" ]; then
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
