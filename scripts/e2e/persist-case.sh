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
# namespace, saved windows and Application Support are removed only once its
# cleanup is proved; a failure, or any doubt about what still runs, stops
# the removal and the run. Cleanup is not a rollback: sessions stopped before
# a later step fails stay stopped, and only what is left is kept, with the
# exact status of every step.
#
# Tools the stand-in test swaps: PERSIST_ZMX (the app's zmx), PERSIST_FORGET
# (forgets saved windows), PERSIST_PS (the process snapshot), PERSIST_RM.

# A top-level helper: a function defined inside another is global in bash
# and would replace a caller's function of the same name.
_persist_problem() { local file="$1"; shift; printf '%s\n' "$*" >> "$file"; }

# persist_census LABEL EVIDENCE PATTERN...: one snapshot of every process;
# those whose command line contains a PATTERN as a literal string (no regex),
# as "pid<TAB>start<TAB>path" -- the path is the command line up to the end
# of the matched executable path, so a token in the arguments is never kept. Written to
# EVIDENCE/census-LABEL.{out,err,status}, each census its own files. Status 2
# when the snapshot cannot be taken: then nothing is known about what runs.
persist_census() {
    local label="$1" evidence="$2"; shift 2
    local out="$evidence/census-$label.out" err="$evidence/census-$label.err" st="$evidence/census-$label.status"
    local snapshot status=0
    snapshot="$("${PERSIST_PS:-ps}" -axww -o pid=,lstart=,command= 2> "$err")" || status=$?
    # A snapshot always holds at least this shell; an empty one is a failure too.
    if [ "$status" -ne 0 ] || [ -z "$snapshot" ]; then
        : > "$out"
        echo "snapshot failed (status $status, $(printf '%s' "$snapshot" | wc -l | tr -d ' ') lines)" > "$st"
        return 2
    fi
    local IFS=$'\n'
    printf '%s\n' "$snapshot" | PERSIST_PATTERNS="$*" python3 -c '
import os, sys
patterns = [p for p in os.environ["PERSIST_PATTERNS"].split("\n") if p]
for line in sys.stdin:
    fields = line.split(None, 6)
    if len(fields) < 7:
        continue
    pid, start, command = fields[0], " ".join(fields[1:6]), fields[6].rstrip("\n")
    for p in patterns:
        at = command.find(p)
        if at >= 0:
            end = command.find(" ", at + len(p))
            print(f"{pid}\t{start}\t{command if end < 0 else command[:end]}")
            break
' > "$out" 2>> "$err" || { echo "matching failed" > "$st"; return 2; }
    echo "ok $(wc -l < "$out" | tr -d ' ') match(es)" > "$st"
    # The receipt, also for a clean pass whose evidence directory goes.
    echo "census $label: $(cat "$st")$( [ -s "$out" ] && printf '; %s' "$(tr '\t\n' ' ;' < "$out")")"
    return 0
}

# persist_cleanup SESSIONS SUPPORT BUNDLE APPEXE EVIDENCE: stop this case's
# own session runtimes, prove nothing of the case still runs, then remove
# its state. 0 only when all of that is proved; otherwise the problems are in
# EVIDENCE/cleanup-problems.txt and what is left is not removed.
persist_cleanup() {
    local sessions="$1" support="$2" bundle="$3" appexe="$4" evidence="$5"
    local zmx="${PERSIST_ZMX:?}"
    local problems="$evidence/cleanup-problems.txt" dir names name status
    mkdir -p "$evidence" && : > "$problems" || return 7
    # A case's runtimes run from its own registry, <Application Support>/<bundle>/runtime/<id>/zmx:
    # the bundle is this case's only. Its namespace is in their environment, not their command line.
    local runtimes="/Application Support/$bundle/runtime/" gui realgui
    realgui="$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$appexe")" || realgui="$appexe"
    gui=("$appexe"); [ "$realgui" = "$appexe" ] || gui+=("$realgui")

    # What runs of this case before anything is stopped: the receipt that the
    # census sees its runtimes at all.
    status=0; persist_census runtimes-before "$evidence" "$runtimes" || status=$?
    [ "$status" -eq 0 ] || _persist_problem "$problems" "census of the case's runtimes before the stop failed (status $status)"

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

    # Nothing of the case may run on: no runtime from its registry (also one
    # the list missed), and not the app itself (a GUI not proved gone).
    # A stopped runtime takes a moment to exit: each check is asked again,
    # each attempt with files of its own, until it shows nothing or the tries
    # run out. A failed census is never retried away.
    local kind label patterns try tries="${PERSIST_SETTLE_TRIES:-10}" delay="${PERSIST_SETTLE_DELAY:-0.5}"
    for kind in runtimes gui; do
        if [ "$kind" = runtimes ]; then patterns=("$runtimes"); else patterns=("${gui[@]}"); fi
        try=1
        while :; do
            label="$kind-after-$try"
            status=0; persist_census "$label" "$evidence" "${patterns[@]}" || status=$?
            if [ "$status" -ne 0 ]; then
                _persist_problem "$problems" "census $label failed (status $status): not known what runs"
                break
            fi
            [ -s "$evidence/census-$label.out" ] || break
            if [ "$try" -ge "$tries" ]; then
                _persist_problem "$problems" "still running ($label, after $tries checks): $(tr '\t\n' ' ;' < "$evidence/census-$label.out")"
                break
            fi
            try=$((try + 1)); sleep "$delay"
        done
    done

    if [ -s "$problems" ]; then
        echo "cleanup NOT proved; what is left of $sessions and $support is kept, evidence in $evidence" >&2
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
# case's end. A failed case is left as it is -- its namespace and profile
# may be under a GUI not proved gone, and they are the driver's evidence. A
# passed one is cleaned up, and passes only if that is proved.
# EVIDENCE/status.txt records both; it is removed only with a clean pass.
persist_finish() {
    local status="$1" sessions="$2" support="$3" bundle="$4" appexe="$5" evidence="$6" cleanup=0 outcome=0
    mkdir -p "$evidence" || return 7
    if [ "$status" -eq 0 ]; then
        persist_cleanup "$sessions" "$support" "$bundle" "$appexe" "$evidence" || cleanup=$?
    else
        echo "case failed (status $status); left as it is: $sessions, $support, evidence in $evidence" >&2
    fi
    persist_outcome "$status" "$cleanup" || outcome=$?
    printf 'runner %s\ncleanup %s\noutcome %s\n' "$status" "$cleanup" "$outcome" > "$evidence/status.txt" || outcome=7
    [ "$outcome" -ne 0 ] || "${PERSIST_RM:-rm}" -rf "$evidence"
    return "$outcome"
}
