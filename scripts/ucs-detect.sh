#!/usr/bin/env bash
# Unicode conformance sweep. Run this INSIDE the terminal under test.
#
# ucs-detect measures what a terminal believes a character's width to be by
# printing it and asking where the cursor ended up (DSR 6 / cursor position
# report). That makes the measurement a property of whichever terminal the
# process is attached to -- launching it from another terminal, or from an
# editor's task runner, measures that one instead.
#
# So: open TakoCore, cd here, and run it.
#
#   ./scripts/ucs-detect.sh                    # full sweep (minutes)
#   ./scripts/ucs-detect.sh --test-only wide   # just wide-character width
#   ./scripts/ucs-detect.sh --test-only zwj    # emoji ZWJ sequences
#
# It covers wide characters, emoji ZWJ sequences, VS-16/VS-15 variation
# selectors, regional-indicator flags, and zero-width combining marks by
# language. Results are written to target/ucs-detect/ as JSON so two runs can
# be diffed after a wcwidth or grapheme-clustering change.
#
# Nothing needs installing: uvx fetches ucs-detect into a throwaway
# environment. The only thing this repo has to provide is DSR 6, which it
# does (see src/terminal/mod.rs, CSI 6 n).
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v uvx >/dev/null 2>&1; then
    echo "uvx not found. Install uv (https://docs.astral.sh/uv/) or run:" >&2
    echo "  pipx run --spec ucs-detect ucs-detect $*" >&2
    exit 1
fi

out=target/ucs-detect
mkdir -p "$out"
stamp=$(date -u '+%Y-%m-%dT%H-%M-%SZ')

echo "Measuring $TERM in this terminal. Do not type or switch focus."
echo "Results: $out/$stamp.json"
echo

uvx --from ucs-detect ucs-detect \
    --save-json "$out/$stamp.json" \
    --set-software-name TakoCore \
    --set-software-version "$(git log -1 --format=%h 2>/dev/null || echo dev)" \
    "$@"

echo
echo "Saved $out/$stamp.json"
ls -1t "$out"/*.json 2>/dev/null | sed -n '2p' | while read -r prev; do
    echo "Previous run: $prev"
    echo "Diff them with: diff <(python3 -m json.tool '$prev') <(python3 -m json.tool '$out/$stamp.json')"
done
