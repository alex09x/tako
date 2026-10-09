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
cd "$(dirname "$0")/../.."

RUN_DIR="target/runs/20261009-132303-host-permission-probes"
mkdir -p "$RUN_DIR/probes" "$RUN_DIR/logs"

echo "==> Packaging probe scripts into $RUN_DIR/probes/..."
cp scripts/probes/probe_host_capabilities.swift "$RUN_DIR/probes/"
cp scripts/probes/probe_codesign_identities.sh "$RUN_DIR/probes/"
cp scripts/probes/probe_notification_auth.sh "$RUN_DIR/probes/"

echo "==> Executing probe_host_capabilities.swift on remote Mac..."
TAKO_MAC=alex09x@Alexs-MacBook-Pro.local ./scripts/mac-remote.sh \
    "swift scripts/probes/probe_host_capabilities.swift" > "$RUN_DIR/logs/probe_host_capabilities.log" 2>&1 || true

echo "==> Executing probe_codesign_identities.sh on remote Mac..."
TAKO_MAC=alex09x@Alexs-MacBook-Pro.local ./scripts/mac-remote.sh \
    "./scripts/probes/probe_codesign_identities.sh" > "$RUN_DIR/logs/probe_codesign_identities.log" 2>&1 || true

echo "==> Executing probe_notification_auth.sh on remote Mac..."
TAKO_MAC=alex09x@Alexs-MacBook-Pro.local ./scripts/mac-remote.sh \
    "./scripts/probes/probe_notification_auth.sh" > "$RUN_DIR/logs/probe_notification_auth.log" 2>&1 || true

echo "==> Probes finished. Generating checksums and manifest..."
cd "$RUN_DIR"
find probes logs -type f -exec shasum -a 256 {} + | sort > sha256sums.txt
cd - > /dev/null

echo "==> Run artifacts captured in $RUN_DIR"
