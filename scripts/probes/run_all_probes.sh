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

TIMESTAMP="$(date -u +"%Y%m%d-%H%M%S")"
RUN_DIR="${1:-target/runs/${TIMESTAMP}-host-permission-probes}"

if [ -e "$RUN_DIR" ]; then
    echo "ERROR: Target run directory '$RUN_DIR' already exists. Refusing to overwrite preserved evidence." >&2
    exit 1
fi

mkdir -p "$RUN_DIR/probes" "$RUN_DIR/logs"

echo "==> Packaging probe sources into $RUN_DIR/probes/..."
cp scripts/probes/probe_host_capabilities.swift "$RUN_DIR/probes/"
cp scripts/probes/probe_codesign_identities.sh "$RUN_DIR/probes/"
cp scripts/probes/probe_notification_auth.sh "$RUN_DIR/probes/"

GIT_REV="$(git rev-parse HEAD 2>/dev/null || echo "unknown")"
HOST="${TAKO_MAC:-alex09x@Alexs-MacBook-Pro.local}"

echo "==> Executing probe 1: probe_host_capabilities.swift on $HOST..."
STATUS_CAP=0
START_CAP=$(date +%s)
TAKO_MAC="$HOST" ./scripts/mac-remote.sh \
    "swift scripts/probes/probe_host_capabilities.swift" > "$RUN_DIR/logs/probe_host_capabilities.log" 2>&1 || STATUS_CAP=$?
DUR_CAP=$(( $(date +%s) - START_CAP ))

echo "==> Executing probe 2: probe_codesign_identities.sh on $HOST..."
STATUS_CODESIGN=0
START_CODESIGN=$(date +%s)
TAKO_MAC="$HOST" ./scripts/mac-remote.sh \
    "./scripts/probes/probe_codesign_identities.sh" > "$RUN_DIR/logs/probe_codesign_identities.log" 2>&1 || STATUS_CODESIGN=$?
DUR_CODESIGN=$(( $(date +%s) - START_CODESIGN ))

echo "==> Executing probe 3: probe_notification_auth.sh on $HOST..."
STATUS_NOTIF=0
START_NOTIF=$(date +%s)
TAKO_MAC="$HOST" ./scripts/mac-remote.sh \
    "./scripts/probes/probe_notification_auth.sh" > "$RUN_DIR/logs/probe_notification_auth.log" 2>&1 || STATUS_NOTIF=$?
DUR_NOTIF=$(( $(date +%s) - START_NOTIF ))

echo "==> Generating dynamic MANIFEST.json and README.md..."
cat > "$RUN_DIR/MANIFEST.json" <<EOF
{
  "run_id": "$(basename "$RUN_DIR")",
  "created_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "git_revision": "$GIT_REV",
  "host": "$HOST",
  "probes": [
    {
      "name": "probe_host_capabilities",
      "source_file": "probes/probe_host_capabilities.swift",
      "log_file": "logs/probe_host_capabilities.log",
      "command": "swift scripts/probes/probe_host_capabilities.swift",
      "exit_code": $STATUS_CAP,
      "duration_seconds": $DUR_CAP
    },
    {
      "name": "probe_codesign_identities",
      "source_file": "probes/probe_codesign_identities.sh",
      "log_file": "logs/probe_codesign_identities.log",
      "command": "./scripts/probes/probe_codesign_identities.sh",
      "exit_code": $STATUS_CODESIGN,
      "duration_seconds": $DUR_CODESIGN
    },
    {
      "name": "probe_notification_auth",
      "source_file": "probes/probe_notification_auth.sh",
      "log_file": "logs/probe_notification_auth.log",
      "command": "./scripts/probes/probe_notification_auth.sh",
      "exit_code": $STATUS_NOTIF,
      "duration_seconds": $DUR_NOTIF
    }
  ]
}
EOF

cat > "$RUN_DIR/README.md" <<EOF
# Host Permission and Capability Probes

- **Run ID**: $(basename "$RUN_DIR")
- **Timestamp**: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
- **Git Revision**: $GIT_REV
- **Target Host**: $HOST

## Probe Results
1. **probe_host_capabilities.swift**: exit code $STATUS_CAP (${DUR_CAP}s)
2. **probe_codesign_identities.sh**: exit code $STATUS_CODESIGN (${DUR_CODESIGN}s)
3. **probe_notification_auth.sh**: exit code $STATUS_NOTIF (${DUR_NOTIF}s)
EOF

echo "==> Generating sha256sums.txt across all artifacts..."
(
    cd "$RUN_DIR"
    find . -type f ! -name sha256sums.txt -exec shasum -a 256 {} + | sort > sha256sums.txt
)

echo "==> Run artifacts captured in $RUN_DIR"
if [ $STATUS_CAP -ne 0 ] || [ $STATUS_CODESIGN -ne 0 ] || [ $STATUS_NOTIF -ne 0 ]; then
    echo "WARNING: One or more probes completed with non-zero exit status (cap=$STATUS_CAP, codesign=$STATUS_CODESIGN, notif=$STATUS_NOTIF)."
fi
