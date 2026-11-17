#!/usr/bin/env bash
# tako — macOS app self-tests
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT
#
# Does the built macOS app actually take input?
#
# The app carries `--selftest-keys`, `--selftest-input`, `--selftest-scroll`
# and `--selftest-frame`. Each runs as an explicit case of the e2e runner
# (scripts/e2e/ScenariosAppSelftests.swift), through its private launch,
# owned-process cleanup and kept-on-failure work directory, with the checks
# and deadlines this script used to apply itself. A failed mode does not stop
# the next one. `macapp self-test: ok` is printed only when every requested
# case reported ok exactly once (scripts/selftest_verdict.py).
#
#   ./scripts/selftest-macapp.sh                 # keys, input, scroll, frame
#   ./scripts/selftest-macapp.sh --scroll-only   # scroll
set -euo pipefail
cd "$(dirname "$0")/.."

case "${1:-}" in
    "") names=(app-selftest-keys app-selftest-input app-selftest-scroll app-selftest-frame) ;;
    --scroll-only) names=(app-selftest-scroll) ;;
    *) echo "usage: $0 [--scroll-only]" >&2; exit 2 ;;
esac

# Off any external volume, where macOS would ask for access on every build.
APP="${APP:-${TAKO_APP_DIR:-$(python3 scripts/app_locations.py dir macapp)}/Tako.app}"
[ -d "$APP" ] || { echo "no app at $APP; run scripts/build-macapp.py first" >&2; exit 1; }
python3 scripts/app_locations.py check-app "$APP"

# The runner takes the GUI lock itself; its log is kept for the verdict.
mkdir -p target
log="target/selftest-macapp.log"
status=0
APP="$APP" ./scripts/e2e-macapp.sh "${names[@]}" 2>&1 | tee "$log" || status=${PIPESTATUS[0]}
echo
exec python3 scripts/selftest_verdict.py --status "$status" --log "$log" "${names[@]}"
