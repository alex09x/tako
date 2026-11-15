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
# One isolated persistence case's end: sourced by scripts/e2e-persist.sh,
# tested without a screen by test-persist-case.sh. A case's private session
# namespace, saved windows and Application Support go only once its cleanup
# is proved; a failure, or any doubt about what is still running, keeps all
# of it and its evidence, and stops the run.
#
# Tools the stand-in test swaps: PERSIST_ZMX (the app's zmx), PERSIST_FORGET
# (forgets saved windows), PERSIST_CENSUS (lists processes by command line,
# motion/daemons.sh's daemon_ids), PERSIST_RM.

# shellcheck source=motion/daemons.sh
. "$(dirname "${BASH_SOURCE[0]}")/motion/daemons.sh"

# A top-level helper: a function defined inside another is global in bash
# and would replace a caller's function of the same name.
_persist_problem() { local file="$1"; shift; printf '%s\n' "$*" >> "$file"; }

# persist_cleanup SESSIONS SUPPORT BUNDLE APPEXE EVIDENCE: stop this case's
# own session runtimes, prove nothing of the case still runs, then remove
# its state. 0 only when all of that is proved; otherwise the problems are
# in EVIDENCE/cleanup-problems.txt and nothing is removed.
persist_cleanup() {
    local sessions="$1" support="$2" bundle="$3" appexe="$4" evidence="$5"
    local zmx="${PERSIST_ZMX:?}" census="${PERSIST_CENSUS:-daemon_ids}"
    local problems="$evidence/cleanup-problems.txt" dir names name status
    mkdir -p "$evidence" && : > "$problems" || return 7

    # Every runtime of this case's own namespace, by name, then stopped.
    for dir in "$sessions"/.tako-sessions/*/; do
        [ -d "$dir" ] || continue
        status=0; names="$(ZMX_DIR="$dir" "$zmx" list --short 2>> "$evidence/zmx.err")" || status=$?
        printf '%s\n' "$names" > "$evidence/sessions-before-$(basename "$dir").txt"
        if [ "$status" -ne 0 ]; then _persist_problem "$problems" "inventory of $dir failed (status $status): not known what runs"; continue; fi
        for name in $names; do
            status=0; ZMX_DIR="$dir" "$zmx" kill "$name" --force >> "$evidence/zmx.log" 2>&1 || status=$?
            [ "$status" -eq 0 ] || _persist_problem "$problems" "stop of session $name in $dir refused (status $status)"
        done
        status=0; names="$(ZMX_DIR="$dir" "$zmx" list --short 2>> "$evidence/zmx.err")" || status=$?
        if [ "$status" -ne 0 ]; then _persist_problem "$problems" "inventory of $dir after the stop failed (status $status)"
        elif [ -n "$names" ]; then _persist_problem "$problems" "sessions still listed in $dir after the stop: $(echo $names)"; fi
    done

    # Nothing whose command line names this case's namespace or the app may
    # run on: neither a runtime that missed the list nor an unproven GUI.
    local pattern
    for pattern in "$sessions" "$appexe"; do
        status=0; "$census" "$pattern" > "$evidence/census.txt" 2> "$evidence/census.err" || status=$?
        if [ "$status" -ne 0 ]; then _persist_problem "$problems" "census of '$pattern' failed (status $status): not known what runs"
        elif [ -s "$evidence/census.txt" ]; then _persist_problem "$problems" "still running for '$pattern': $(tr '\n' ' ' < "$evidence/census.txt")"; fi
    done

    if [ -s "$problems" ]; then
        echo "cleanup NOT proved; kept $sessions, $support and $evidence" >&2
        return 7
    fi
    status=0; "${PERSIST_FORGET:?}" "$bundle" >> "$evidence/forget.log" 2>&1 || status=$?
    [ "$status" -eq 0 ] || { _persist_problem "$problems" "saved windows of $bundle could not be forgotten (status $status)"; return 7; }
    status=0; "${PERSIST_RM:-rm}" -rf "$sessions" "$support" 2>> "$evidence/rm.err" || status=$?
    if [ "$status" -ne 0 ] || [ -e "$sessions" ] || [ -e "$support" ]; then
        _persist_problem "$problems" "the case's state could not be removed (status $status)"
        return 7
    fi
    return 0
}

# persist_outcome RUNNER_STATUS CLEANUP_STATUS: the case's status, its own
# failure first, then an unproved cleanup.
persist_outcome() {
    [ "$1" -ne 0 ] && return "$1"
    return "$2"
}

# persist_finish RUNNER_STATUS SESSIONS SUPPORT BUNDLE APPEXE EVIDENCE: a
# case's end. A failed case keeps everything as it is -- its namespace and
# profile may be under a GUI not proved gone, and they are the driver's
# evidence. A passed one is cleaned up, and passes only if that is proved.
# EVIDENCE/status.txt records both; it is removed only with a clean pass.
persist_finish() {
    local status="$1" sessions="$2" support="$3" bundle="$4" appexe="$5" evidence="$6" cleanup=0 outcome=0
    mkdir -p "$evidence" || return 7
    if [ "$status" -eq 0 ]; then
        persist_cleanup "$sessions" "$support" "$bundle" "$appexe" "$evidence" || cleanup=$?
    else
        echo "case failed (status $status); kept $sessions, $support and $evidence" >&2
    fi
    persist_outcome "$status" "$cleanup" || outcome=$?
    printf 'runner %s\ncleanup %s\noutcome %s\n' "$status" "$cleanup" "$outcome" > "$evidence/status.txt" || outcome=7
    [ "$outcome" -ne 0 ] || "${PERSIST_RM:-rm}" -rf "$evidence"
    return "$outcome"
}
