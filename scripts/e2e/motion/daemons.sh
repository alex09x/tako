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
# Session daemons a motion run may leave behind, by identity: sourced by
# motion-check.sh, tested without a screen by test-daemons.sh.

# Every process whose command line contains $1, one "PID<TAB>start" a line,
# sorted. None is an empty list, not an error; pgrep failing otherwise is.
daemon_ids() {
    local pids status=0
    pids="$(pgrep -f -- "$1")" || status=$?
    [ "$status" -eq 0 ] || [ "$status" -eq 1 ] || return "$status"
    [ -n "$pids" ] || return 0
    local pid start
    for pid in $pids; do
        [ "$pid" = "$$" ] && continue
        start="$(ps -o lstart= -p "$pid" 2>/dev/null)" || continue
        printf '%s\t%s\n' "$pid" "$start"
    done | LC_ALL=C sort
}

# The identities in file $2 (after) that file $1 (before) lacks: a PID
# reused by a new process counts, its start differs.
new_daemons() {
    LC_ALL=C comm -13 "$1" "$2"
}

# A run's outcome once its app is gone: $1 the status it had, $2 the file of
# identities from before it, $3 the pattern, $4 where to keep evidence. A
# daemon the run left behind -- or a census that failed -- turns a passing
# run into a failure (5, 6) and keeps both lists and the leftovers in $4;
# an earlier failure keeps its own status.
motion_finish() {
    local status="$1" before="$2" pattern="$3" evidence="$4" after leaked
    after="$(mktemp)"
    if ! daemon_ids "$pattern" > "$after"; then
        echo "motion-check: could not list session daemons after the run" >&2
        [ "$status" -ne 0 ] || status=6
    else
        leaked="$(new_daemons "$before" "$after")"
        if [ -n "$leaked" ]; then
            mkdir -p "$evidence"
            cp "$before" "$evidence/daemons-before.txt"
            cp "$after" "$evidence/daemons-after.txt"
            printf '%s\n' "$leaked" > "$evidence/daemons-left.txt"
            echo "motion-check: LEFT $(printf '%s\n' "$leaked" | wc -l | tr -d ' ') session daemon(s) behind; see $evidence" >&2
            [ "$status" -ne 0 ] || status=5
        fi
    fi
    rm -f "$after"
    return "$status"
}
