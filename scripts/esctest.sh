#!/usr/bin/env bash
# Run esctest against the engine, headlessly.
#
# esctest is George Nachman's conformance suite -- roughly a thousand tests
# that drive a terminal by writing escape sequences to stdout and reading the
# answers back from stdin. It measures against "xterm, but without the bugs
# George disagrees with", which is a far stricter target than any suite we
# would write ourselves.
#
# It needs no display and no app: examples/headless.rs is a terminal with no
# window, so esctest runs inside our engine the same way it would run inside
# a real terminal. DECRQCRA is what makes this possible at all -- it is how
# esctest reads the screen back (see src/terminal/checksum.rs).
#
#   ./scripts/esctest.sh                      # everything
#   ./scripts/esctest.sh --include '^CUP'     # one group
#   ./scripts/esctest.sh --stop-on-failure
#
# esctest is GPL-2.0. It is fetched into target/, executed against our binary,
# and never vendored or linked, so it does not affect this repository's
# licensing.
set -euo pipefail

cd "$(dirname "$0")/.."

CHECKOUT=target/esctest2
LOG=target/esctest.log

if [[ ! -d "$CHECKOUT" ]]; then
    echo "==> fetching esctest2"
    git clone -q --depth 1 https://github.com/ThomasDickey/esctest2.git "$CHECKOUT"
fi

echo "==> building headless host"
cargo build -q --example headless --features pty

echo "==> running esctest"
set +e
# XTCHECKSUM 13 = POSITIVE | NO_TRIM | DRAWN: a positive sum, trailing blanks
# counted, never-written cells counted as spaces. That is the convention
# esctest assumes for xterm 279 and later -- it expects a blank cell to come
# back as 32 and normalises it to zero -- and it never selects it itself, so
# the terminal has to be put in it before the suite starts. Without this the
# run measures the gap between two checksum conventions: DEC's negated,
# trimmed sum answers 0000 for a blank rectangle, esctest computes
# 0x10000 - 0 for it, and every test that checks an empty region fails.
cargo run -q --example headless --features pty -- \
    --quiet --rows 25 --cols 80 --init '\e[13#y' -- \
    python3 "$CHECKOUT/esctest/esctest.py" \
        --expected-terminal=xterm \
        --xterm-checksum=334 \
        --no-print-logs \
        --logfile "$LOG" \
        --timeout 2 \
        "$@" >/dev/null 2>&1
set -e

echo
if [[ -f "$LOG" ]]; then
    grep -E "tests passed|tests failed" "$LOG" | tail -1 || true
    echo
    failures=$(grep -c "^FAILED" "$LOG" || true)
    if [[ "${failures:-0}" -gt 0 ]]; then
        echo "Failures ($failures):"
        grep -B 1 "^FAILED" "$LOG" | grep "^Run test:" | sed 's/^Run test: /  /' | sort | head -40
        echo
        echo "Full log: $LOG"
    fi
else
    echo "no log produced -- did the runner start?" >&2
    exit 1
fi
