#!/bin/bash
# Targeted checks on the test Mac: the tests a change touches, not the full
# CI. See scripts/check_run.py for the check names.
#
#   export TAKO_MAC=user@test-mac.local
#   scripts/check.sh rust:search swift:CrossSessionSearch e2e:find-all,find-stale
#
# scripts/ci.sh stays the full run: every stage, clippy and coverage gates.
set -euo pipefail
cd "$(dirname "$0")/.."
[ $# -gt 0 ] || { python3 scripts/check_run.py; exit 2; }
args=$(printf ' %q' "$@")
exec scripts/mac-remote.sh "python3 scripts/check_run.py$args"
