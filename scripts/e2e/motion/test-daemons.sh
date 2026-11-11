#!/bin/bash
#
# tako — Terminal emulator
# Copyright (c) 2026 Alexander Panasenko
#
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT
#
# daemons.sh without a screen: stand-in "daemons" are sleeps whose command
# line carries a pattern unique to this run. Exits non-zero on any failure.
set -euo pipefail
cd "$(dirname "$0")"
. ./daemons.sh

tmp="$(mktemp -d)"
tag="tako-daemon-test-$$-$RANDOM"
started=()
spawn() { (exec -a "$tag-$1" sleep 60) & started+=($!); sleep 0.2; }
cleanup() { for p in "${started[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null || true; done; rm -rf "$tmp"; }
trap cleanup EXIT
failed=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2', want '$3'"; failed=1; fi; }

# None running: an empty list, status 0 -- also under set -e.
daemon_ids "$tag" > "$tmp/none"; check "no match is an empty list, not an error" "$(wc -l < "$tmp/none" | tr -d ' ')" 0

spawn a
daemon_ids "$tag" > "$tmp/before"; check "a running daemon is listed" "$(wc -l < "$tmp/before" | tr -d ' ')" 1

# Nothing new: a passing run stays passing, nothing kept.
s=0; motion_finish 0 "$tmp/before" "$tag" "$tmp/ev0" 2>/dev/null || s=$?
check "no new daemon keeps a pass" "$s" 0
check "no new daemon keeps no evidence" "$([ -e "$tmp/ev0" ] && echo kept || echo none)" none

# One left behind: the pass becomes 5 and the evidence names it.
spawn b
s=0; motion_finish 0 "$tmp/before" "$tag" "$tmp/ev1" 2>/dev/null || s=$?
check "a new daemon fails a passing run" "$s" 5
check "the evidence lists exactly the new one" "$(cut -f1 "$tmp/ev1/daemons-left.txt")" "${started[1]}"

# An earlier failure keeps its own status, and the leak is still recorded.
s=0; motion_finish 3 "$tmp/before" "$tag" "$tmp/ev2" 2>/dev/null || s=$?
check "an earlier failure keeps its status" "$s" 3
check "and its leak is still kept" "$([ -s "$tmp/ev2/daemons-left.txt" ] && echo kept || echo none)" kept

# One gone and one new at once: a count would see no change, identities do.
kill "${started[0]}"; wait "${started[0]}" 2>/dev/null || true
daemon_ids "$tag" > "$tmp/before2"
spawn c
kill "${started[1]}"; wait "${started[1]}" 2>/dev/null || true
s=0; motion_finish 0 "$tmp/before2" "$tag" "$tmp/ev3" 2>/dev/null || s=$?
check "a leak hidden by another daemon exiting still fails" "$s" 5

exit "$failed"
