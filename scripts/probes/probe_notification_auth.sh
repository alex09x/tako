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
set -euo pipefail

echo "================================================================================"
echo "TAKO NOTIFICATION AUTHORIZATION PROBE REPORT"
echo "Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "================================================================================"

E2E_APP="${1:-target/macapp-e2e/Tako.app}"
echo "Target App: $E2E_APP"
TAKOCTL_BIN="$E2E_APP/Contents/MacOS/takoctl"
BUNDLE_ID="com.tako-core.terminal.e2e"

if [ ! -x "$TAKOCTL_BIN" ]; then
    echo "ERROR: takoctl not found at $TAKOCTL_BIN" >&2
    exit 1
fi

# Check if an instance of Tako is already running
EXISTING_PID=$(pgrep -f "$E2E_APP/Contents/MacOS/Tako" | head -n 1 || true)
LAUNCHED_PID=""

if [ -n "$EXISTING_PID" ]; then
    echo "Found existing running Tako instance (PID: $EXISTING_PID)."
else
    echo "Launching target app in background..."
    "$E2E_APP/Contents/MacOS/Tako" --no-update --no-launch-notices &
    LAUNCHED_PID=$!
    echo "Launched Tako instance (PID: $LAUNCHED_PID)."
    sleep 2
fi

cleanup() {
    if [ -n "$LAUNCHED_PID" ]; then
        echo "Terminating launched probe app (PID $LAUNCHED_PID)..."
        kill -TERM "$LAUNCHED_PID" 2>/dev/null || true
        wait "$LAUNCHED_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

echo -e "\nInvoking: $TAKOCTL_BIN --bundle-id $BUNDLE_ID notify 'Probe Notification' --json"
"$TAKOCTL_BIN" --bundle-id "$BUNDLE_ID" notify "Probe Notification" --json 2>&1 || true

echo -e "\n================================================================================"
echo "NOTIFICATION PROBE COMPLETE"
echo "================================================================================"
