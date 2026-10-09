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
# Automated UI test runner for Tako.
#
# Runs e2e and accessibility-driven UI tests against Tako.app without requiring
# manual clicking.
#
# By default, runs against the remote test Mac (Alexs-MacBook-Pro.local)
# via scripts/mac-remote.sh so your local screen and mouse are NOT disturbed.
# Pass --local to run on this machine instead.
#
# Usage:
#   ./scripts/test-ui.sh                    # run default e2e scenarios on remote Mac
#   ./scripts/test-ui.sh --persist          # run session persistence scenarios
#   ./scripts/test-ui.sh persist-reflow     # run specific scenario
#   ./scripts/test-ui.sh --list             # list all available scenarios
#   ./scripts/test-ui.sh --local [scenario] # run locally (takes screen focus)
#
set -euo pipefail
cd "$(dirname "$0")/.."

REMOTE="${TAKO_MAC:-alex09x@Alexs-MacBook-Pro.local}"
RUN_LOCAL=0
IS_PERSIST=0
SCENARIOS=()

for arg in "$@"; do
    case "$arg" in
        --local)
            RUN_LOCAL=1
            ;;
        --persist)
            IS_PERSIST=1
            ;;
        --list)
            echo "Available E2E UI scenarios:"
            [ -x target/tako-e2e ] || swiftc -O -o target/tako-e2e scripts/e2e/tako-e2e.swift 2>/dev/null || true
            if [ -x target/tako-e2e ]; then
                ./target/tako-e2e 2>&1 | grep "^  " || true
            fi
            exit 0
            ;;
        -*)
            echo "Unknown option: $arg" >&2
            echo "Usage: $0 [--local] [--persist] [--list] [scenario ...]" >&2
            exit 2
            ;;
        *)
            SCENARIOS+=("$arg")
            ;;
    esac
done

if [ ${#SCENARIOS[@]} -gt 0 ]; then
    KNOWN_SCENARIOS=$(grep -E '^\s*\("[a-zA-Z0-9_-]+",\s*"' scripts/e2e/tako-e2e.swift | sed -E 's/^[[:space:]]*\("([^"]+)",.*/\1/')
    for s in "${SCENARIOS[@]}"; do
        if ! echo "$KNOWN_SCENARIOS" | grep -Fqx -- "$s"; then
            echo "FAIL: unknown scenario '$s'" >&2
            echo "Use --list to see available scenarios." >&2
            exit 2
        fi
    done
fi

SCENARIO_ARGS=""
if [ ${#SCENARIOS[@]} -gt 0 ]; then
    SCENARIO_ARGS=" $(printf '%q ' "${SCENARIOS[@]}")"
    SCENARIO_ARGS="${SCENARIO_ARGS% }"
fi

export TAKO_BUNDLE_ID="${TAKO_BUNDLE_ID:-com.tako-core.terminal.e2e}"
export TAKO_APP_DIR="${TAKO_APP_DIR:-target/macapp-e2e}"

if [ $RUN_LOCAL -eq 1 ]; then
    echo "==> Running UI tests locally..."
    if [ $IS_PERSIST -eq 1 ] || [[ "${SCENARIOS[*]:-}" =~ persist- ]]; then
        exec ./scripts/e2e-persist.sh "${SCENARIOS[@]}"
    else
        TAKO_BUNDLE_ID="$TAKO_BUNDLE_ID" TAKO_APP_DIR="$TAKO_APP_DIR" python3 scripts/build-macapp.py
        APP="$TAKO_APP_DIR/Tako.app" exec ./scripts/e2e-macapp.sh "${SCENARIOS[@]}"
    fi
else
    echo "==> Running UI tests remotely on $REMOTE (local screen stays untouched)..."
    export TAKO_MAC="$REMOTE"
    export TAKO_REMOTE_TIMEOUT="${TAKO_REMOTE_TIMEOUT:-300}"
    if [ $IS_PERSIST -eq 1 ] || [[ "${SCENARIOS[*]:-}" =~ persist- ]]; then
        exec ./scripts/mac-remote.sh "./scripts/e2e-persist.sh$SCENARIO_ARGS"
    else
        exec ./scripts/mac-remote.sh "TAKO_BUNDLE_ID=com.tako-core.terminal.e2e TAKO_APP_DIR=target/macapp-e2e python3 scripts/build-macapp.py && APP=target/macapp-e2e/Tako.app ./scripts/e2e-macapp.sh$SCENARIO_ARGS"
    fi
fi

