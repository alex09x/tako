#!/usr/bin/env bash
# Does the built macOS app actually take input?
#
# The app has carried `--selftest-keys` and `--selftest-input` for a while:
# the first drives real NSEvents through the surface and records the bytes
# they produce, the second types into the live shell and dumps the screen.
# Nothing ran them, so a refactor that left the input path unwired produced a
# terminal that launched, drew, spawned its shell -- and silently swallowed
# every keystroke. This script is that gap closed: it runs both and fails.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="${APP:-target/macapp/Tako.app}"
[ -d "$APP" ] || { echo "no app at $APP; run scripts/build-macapp.py first" >&2; exit 1; }

# Reports go to a directory of this run's own (the app reads
# TAKO_SELFTEST_DIR), so two runs on one machine never read each other's.
REPORTS="$(mktemp -d "${TMPDIR:-/tmp}/tako-selftest.XXXXXX")"
launch() { open -n --env "TAKO_SELFTEST_DIR=$REPORTS" "$APP" --args "$@"; }

quit() { pkill -f "$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")/Contents/MacOS/" 2>/dev/null || true; }
trap 'quit; rm -rf "$REPORTS"' EXIT

fail=0

echo "== keys: an NSEvent must produce the bytes it stands for =="
rm -f "$REPORTS"/tako-keytest.txt
quit; launch --selftest-keys
for _ in $(seq 1 20); do [ -f "$REPORTS/tako-keytest.txt" ] && break; sleep 1; done
quit
if [ ! -f "$REPORTS/tako-keytest.txt" ]; then
    echo "  FAIL: the app produced no report at all" >&2; fail=1
else
    cat "$REPORTS/tako-keytest.txt"
    # Each line reads "label chars=X -> hh (c)". An unwired input path still
    # prints every line, with nothing between the arrow and the parenthesis.
    if grep -qE '\->\s+\(' "$REPORTS/tako-keytest.txt"; then
        echo "  FAIL: a keystroke produced no bytes -- input is not reaching the shell" >&2
        fail=1
    fi
    for expect in 'chars=a -> 61' 'chars=A -> 41' 'chars=1 -> 31' 'chars=! -> 21'; do
        grep -qF "$expect" "$REPORTS/tako-keytest.txt" || { echo "  FAIL: missing $expect" >&2; fail=1; }
    done
    # The space bar, by label: what it types is invisible in the chars
    # column. Option+Space is a no-break space on the usual Mac layouts, and a
    # shell cannot split words on one, so it must arrive as 20 too.
    for expect in 'space 20' 'space2 20' 'shift+spc 20' 'ctrl+spc 00' 'opt+spc 20'; do
        label="${expect% *}" bytes="${expect#* }"
        grep -aqE "^$(printf '%s' "$label" | sed 's/[+]/[+]/g') +chars=.* -> $bytes \(" "$REPORTS/tako-keytest.txt" \
            || { echo "  FAIL: $label should send $bytes" >&2; fail=1; }
    done
fi

echo
echo "== input: typing must reach the real shell and come back on screen =="
rm -f "$REPORTS"/tako-inputtest.txt
quit; launch --selftest-input
for _ in $(seq 1 30); do [ -f "$REPORTS/tako-inputtest.txt" ] && break; sleep 1; done
quit
if [ ! -f "$REPORTS/tako-inputtest.txt" ]; then
    echo "  FAIL: the app produced no report at all" >&2; fail=1
else
    cat "$REPORTS/tako-inputtest.txt"
    tail -n 1 "$REPORTS/tako-inputtest.txt" | grep -q "hello world" \
        || { echo "  FAIL: what was typed never appeared on screen" >&2; fail=1; }
    grep -q "^focused at launch: yes" "$REPORTS/tako-inputtest.txt" \
        || { echo "  FAIL: a new window does not give the terminal the keyboard" >&2; fail=1; }
fi

echo
echo "== scroll: a precise delta must move the grid by a fraction of a row =="
rm -f "$REPORTS"/tako-scrolltest.txt
quit; launch --selftest-scroll
for _ in $(seq 1 25); do [ -f "$REPORTS/tako-scrolltest.txt" ] && break; sleep 1; done
quit
if [ ! -f "$REPORTS/tako-scrolltest.txt" ]; then
    echo "  FAIL: the app produced no report at all" >&2; fail=1
else
    cat "$REPORTS/tako-scrolltest.txt"
    grep -q "^FAIL" "$REPORTS/tako-scrolltest.txt" && fail=1
    # A run that scrolled without ever handing a frame over would report every
    # position correctly and still show nothing moving.
    grep -qE "submitted=[1-9]" "$REPORTS/tako-scrolltest.txt" \
        || { echo "  FAIL: no frame was handed to the display while scrolling" >&2; fail=1; }
fi

echo
echo "== frame: the pixels on screen put the grid inside its padding =="
rm -f "$REPORTS"/tako-frametest.txt "$REPORTS"/tako-frame.png
quit; launch --selftest-frame
for _ in $(seq 1 25); do [ -f "$REPORTS/tako-frametest.txt" ] && break; sleep 1; done
quit
if [ ! -f "$REPORTS/tako-frametest.txt" ]; then
    echo "  FAIL: the app produced no report at all" >&2; fail=1
else
    cat "$REPORTS/tako-frametest.txt"
    grep -q "^FAIL" "$REPORTS/tako-frametest.txt" && fail=1
    # What the window showed, for a person to look at.
    if [ -f "$REPORTS/tako-frame.png" ]; then
        mkdir -p target && cp "$REPORTS/tako-frame.png" target/selftest-frame.png
        echo "  frame saved to target/selftest-frame.png"
    fi
fi

echo
[ "$fail" -eq 0 ] && echo "macapp self-test: ok" || { echo "macapp self-test: FAILED" >&2; exit 1; }
