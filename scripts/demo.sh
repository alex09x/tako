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
# Automated feature showcase and video presentation runner for Tako.
#
# Runs animated feature demonstrations driven by the Accessibility and
# keyboard event harness, suitable for human viewing and video recording.
#
# By default, runs against the remote test Mac (Alexs-MacBook-Pro.local)
# via scripts/mac-remote.sh so your local screen and mouse are NOT disturbed.
# Pass --local to run on this machine instead.
#
# Usage:
#   ./scripts/demo.sh                          # run default core presentation remotely
#   ./scripts/demo.sh --list                   # list feature showcase matrix
#   ./scripts/demo.sh --pace fast              # fast preview without presentation delays
#   ./scripts/demo.sh --scene workspaces-frame-sync # run specific scene
#   ./scripts/demo.sh --record showcase.mov    # record QuickTime video of run
#   ./scripts/demo.sh --local                  # run locally on this machine
#
set -euo pipefail
cd "$(dirname "$0")/.."

REMOTE="${TAKO_MAC:-alex09x@Alexs-MacBook-Pro.local}"
RUN_LOCAL=0
FORWARD_ARGS=()

while [ $# -gt 0 ]; do
    case "$1" in
        --local)
            RUN_LOCAL=1
            shift
            ;;
        --list)
            [ -x target/tako-showcase ] || swiftc -O -o target/tako-showcase scripts/e2e/DriverCore.swift scripts/e2e/tako-showcase.swift 2>/dev/null || true
            if [ -x target/tako-showcase ]; then
                ./target/tako-showcase --list
            else
                echo "Showcase runner not compiled. Run with --local to compile or inspect scripts/e2e/tako-showcase.swift."
            fi
            exit 0
            ;;
        *)
            FORWARD_ARGS+=("$1")
            shift
            ;;
    esac
done

export TAKO_BUNDLE_ID="${TAKO_BUNDLE_ID:-com.tako-core.terminal.showcase}"
export TAKO_APP_DIR="${TAKO_APP_DIR:-target/macapp-showcase}"
export TAKO_WITH_ZMX="${TAKO_WITH_ZMX:-1}"

ARGS_STRING=""
if [ ${#FORWARD_ARGS[@]} -gt 0 ]; then
    ARGS_STRING=" $(printf '%q ' "${FORWARD_ARGS[@]}")"
    ARGS_STRING="${ARGS_STRING% }"
fi

if [ $RUN_LOCAL -eq 1 ]; then
    echo "==> Running Tako Showcase locally..."
    mkdir -p target
    python3 scripts/build-macapp.py
    swiftc -O -o target/tako-showcase scripts/e2e/DriverCore.swift scripts/e2e/tako-showcase.swift
    exec python3 scripts/gui_lock.py -- target/tako-showcase "$TAKO_APP_DIR/Tako.app" "${FORWARD_ARGS[@]}"
else
    echo "==> Running Tako Showcase remotely on $REMOTE (local screen stays untouched)..."
    export TAKO_MAC="$REMOTE"
    export TAKO_REMOTE_TIMEOUT="${TAKO_REMOTE_TIMEOUT:-600}"
    exec ./scripts/mac-remote.sh "TAKO_BUNDLE_ID=com.tako-core.terminal.showcase TAKO_APP_DIR=target/macapp-showcase TAKO_WITH_ZMX=1 python3 scripts/build-macapp.py && swiftc -O -o target/tako-showcase scripts/e2e/DriverCore.swift scripts/e2e/tako-showcase.swift && python3 scripts/gui_lock.py -- target/tako-showcase target/macapp-showcase/Tako.app$ARGS_STRING"
fi
