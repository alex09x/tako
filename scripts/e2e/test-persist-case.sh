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
# persist-case.sh without a screen or a session runtime. zmx, forgetting
# saved windows, rm and (for its failures) ps are stand-ins; the census's
# matches are this test's own sleeps, named like a case's runtime. Only those
# sleeps are ever signalled. Exits non-zero on any failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./persist-case.sh

tmp="$(mktemp -d)"
started=()
cleanup() { for p in "${started[@]:-}"; do [ -n "$p" ] && kill "$p" 2>/dev/null; done; rm -rf "$tmp"; }
trap cleanup EXIT
failed=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: got '$2', want '$3'"; failed=1; fi; }

# The stand-in zmx: FAKE_LIST ok|fail|stuck, FAKE_KILL ok|fail. "stuck"
# still lists the session after its stop.
cat > "$tmp/zmx" <<'SH'
#!/bin/bash
case "$1" in
  list) [ "${FAKE_LIST:-ok}" = fail ] && { echo "zmx: cannot read $ZMX_DIR" >&2; exit 3; }
        if [ "${FAKE_LIST:-ok}" = stuck ] || [ ! -e "$ZMX_DIR/killed" ]; then echo "s1"; fi; exit 0 ;;
  kill) [ "${FAKE_KILL:-ok}" = fail ] && { echo "zmx: kill refused" >&2; exit 4; }
        touch "$ZMX_DIR/killed"; exit 0 ;;
esac
SH
cat > "$tmp/forget" <<'SH'
#!/bin/bash
[ "${FAKE_FORGET:-ok}" = fail ] && exit 2
echo "forgot $1" >> "$FORGOT"
SH
printf '#!/bin/bash\nexit 1\n' > "$tmp/rm-fails"
# ps that fails outright, and ps that fails only its first call (a first
# census with an error, then a clean one).
printf '#!/bin/bash\necho "ps: no snapshot (stand-in)" >&2\nexit 1\n' > "$tmp/ps-fails"
cat > "$tmp/ps-fails-once" <<'SH'
#!/bin/bash
if [ ! -e "$PS_ONCE" ]; then touch "$PS_ONCE"; echo "ps: first snapshot failed (stand-in)" >&2; exit 1; fi
exec ps "$@"
SH
chmod +x "$tmp/zmx" "$tmp/forget" "$tmp/rm-fails" "$tmp/ps-fails" "$tmp/ps-fails-once"
export PERSIST_ZMX="$tmp/zmx" PERSIST_FORGET="$tmp/forget" FORGOT="$tmp/forgot"
# Three checks 0.4 s apart for a survivor: short, but long enough for a
# runtime that exits on its own during them.
export PERSIST_SETTLE_TRIES=3 PERSIST_SETTLE_DELAY=0.4

# A runtime of bundle $1 as a case's would run it: from its registry, with
# its namespace in the environment and a token in the arguments.
runtime() {
    (exec -a "$tmp/h/Library/Application Support/$1/runtime/0.1.0-0123456789abcdef/zmx attach --create-only TOKEN-SECRET" sleep 60) &
    started+=($!); sleep 0.3
}

# case_run RUNNER_STATUS: a fresh case with one session; then persist_finish.
# Bundle ids carry regex characters: the census must match them literally.
n=0
case_run() {
    n=$((n + 1))
    bundle="b.$n+x"; sessions="$tmp/c$n/sessions"; support="$tmp/c$n/support"; evidence="$tmp/c$n/evidence"
    mkdir -p "$sessions/.tako-sessions/main" "$support"
    : > "$FORGOT"
    s=0; persist_finish "$1" "$sessions" "$support" "$bundle" "/x/Tako.app/Contents/MacOS/Tako" "$evidence" > "$tmp/c$n.out" 2> "$tmp/c$n.err" || s=$?
}
kept() { [ -d "$sessions" ] && [ -d "$support" ] && [ -f "$evidence/status.txt" ] && echo kept || echo lost; }
problem() { grep -c -- "$1" "$evidence/cleanup-problems.txt" 2>/dev/null || echo 0; }

case_run 0
check "a clean pass is 0" "$s" 0
check "a clean pass removes namespace, profile and evidence" \
    "$([ -e "$sessions" ] || [ -e "$support" ] || [ -e "$evidence" ] && echo left || echo gone)" gone
check "a clean pass forgets its saved windows" "$(cat "$FORGOT")" "forgot $bundle"
check "a clean pass prints its census receipts" "$(grep -c '^census ' "$tmp/c$n.out")" 3

case_run 3
check "a runner failure keeps its own status" "$s" 3
check "a runner failure leaves namespace, profile and evidence" "$(kept)" kept
check "a runner failure stops nothing and forgets nothing" "$([ -e "$sessions/.tako-sessions/main/killed" ] || [ -s "$FORGOT" ] && echo touched || echo untouched)" untouched

FAKE_LIST=fail case_run 0
check "a failed inventory fails a passing run with 7" "$s" 7
check "a failed inventory is not taken as empty" "$(problem 'inventory of')" 1
check "a failed inventory keeps what is left" "$(kept)" kept

FAKE_KILL=fail case_run 0
check "a refused stop fails a passing run with 7" "$s" 7
check "a refused stop is named" "$(problem 'refused')" 1
check "a refused stop keeps what is left" "$(kept)" kept

FAKE_LIST=stuck case_run 0
check "a session still listed after its stop fails the run" "$s" 7
check "the listed survivor is named" "$(problem 'still listed')" 1

# A runtime of this case's registry still running, missed by the list:
# found by its literal registry path, recorded without its arguments.
n_next=$((n + 1)); runtime "b.$n_next+x"
case_run 0
check "a runtime still running from the case's registry fails the run" "$s" 7
check "the running runtime is named after every check" "$(problem 'still running (runtimes-after-3, after 3 checks)')" 1
check "each check of it kept files of its own" "$(ls "$evidence"/census-runtimes-after-*.out | wc -l | tr -d ' ')" 3
check "the census saw it before the stop too" "$(wc -l < "$evidence/census-runtimes-before.out" | tr -d ' ')" 1
check "its record is pid, start and the matched path, not a token after it" \
    "$(grep -c 'TOKEN-SECRET' "$evidence"/census-*.out "$evidence/cleanup-problems.txt" | awk -F: '{s+=$NF} END {print s+0}')/$(cut -f3 "$evidence/census-runtimes-after-3.out")" \
    "0/references /Application Support/b.$n_next+x/runtime/"
check "a running runtime keeps what is left" "$(kept)" kept
# A process that names the case's path after a token -- in an argument, not
# as its executable: it is kept as a reference, and the token is not written.
for p in "${started[@]}"; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; started=()
(exec -a "/usr/bin/reader TOKEN-BEFORE $tmp/h/Library/Application Support/b.$((n + 1))+x/runtime/0.1.0-0123456789abcdef/zmx" sleep 60) &
started+=($!); sleep 0.3
case_run 0
check "a process naming the case's runtime path in an argument keeps the case" "$s" 7
check "no token before the path is written" \
    "$(cat "$evidence"/census-* "$evidence/cleanup-problems.txt" "$tmp/c$n.out" "$tmp/c$n.err" | grep -c 'TOKEN-BEFORE')" 0
for p in "${started[@]}"; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; started=()
# Literal: another case's runtime whose bundle the dot and plus would match as a regex is not this case's.
runtime "bX$((n + 1))Ex"
case_run 0
check "a regex look-alike of the bundle is not matched" "$s/$(grep -c '^census runtimes-before: ok 0 match' "$tmp/c$n.out")" "0/1"

# The snapshot fails while the stand-in runtime is alive: unknown, not gone.
PERSIST_PS="$tmp/ps-fails" case_run 0
check "a failed process snapshot fails the run" "$s" 7
check "every census that failed is named" "$(problem 'failed (status 2)')" 3
check "its error is kept" "$(grep -c 'no snapshot' "$evidence/census-runtimes-after-1.err")" 1
check "a failed census is not retried away" "$(ls "$evidence"/census-runtimes-after-*.status | wc -l | tr -d ' ')" 1
check "a failed snapshot keeps what is left" "$(kept)" kept

# A snapshot that exits 0 but is not process records: nothing is known.
printf '#!/bin/bash\necho "garbage GARBAGE-SECRET row"\n' > "$tmp/ps-garbage"
# Real records with one row that is not one among them: not dropped silently.
printf '#!/bin/bash\nps "$@" || exit\necho "12x ??? GARBAGE-SECRET"\n' > "$tmp/ps-mixed"
chmod +x "$tmp/ps-garbage" "$tmp/ps-mixed"
PERSIST_PS="$tmp/ps-garbage" case_run 0
check "an all-malformed snapshot fails the run" "$s" 7
check "it is named as unreadable, by row number only" \
    "$(grep -c 'row 1: not a process record' "$evidence/census-runtimes-before.err")/$(cat "$evidence"/census-* "$evidence/cleanup-problems.txt" | grep -c 'GARBAGE-SECRET')" "1/0"
check "an all-malformed snapshot keeps what is left" "$(kept)" kept
PERSIST_PS="$tmp/ps-mixed" case_run 0
check "a malformed row among records fails the run" "$s" 7
check "the bad row is named, its text not kept" \
    "$(grep -c 'not a process record' "$evidence/census-runtimes-before.err")/$(cat "$evidence"/census-* "$evidence/cleanup-problems.txt" | grep -c 'GARBAGE-SECRET')" "1/0"
check "a malformed row is not retried away" "$(ls "$evidence"/census-runtimes-after-*.status | wc -l | tr -d ' ')" 1
# Only blank space: no bad row, but no process record either.
printf '#!/bin/bash\nprintf "   \\n \\n"\n' > "$tmp/ps-blank"; chmod +x "$tmp/ps-blank"
PERSIST_PS="$tmp/ps-blank" case_run 0
check "a snapshot with no process record fails the run" "$s/$(grep -c 'no process record' "$evidence/census-runtimes-before.err")" "7/1"

# The first census fails, the later ones are clean: the first's details stay.
for p in "${started[@]}"; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; started=()
PS_ONCE="$tmp/ps-once.flag" PERSIST_PS="$tmp/ps-fails-once" case_run 0
check "a first failed census still fails the run" "$s" 7
check "the first census keeps its own error" "$(grep -c 'first snapshot failed' "$evidence/census-runtimes-before.err")" 1
check "the first census keeps its own status" "$(cut -c1-15 "$evidence/census-runtimes-before.status")" "snapshot failed"
check "a later clean census has files of its own" "$(cat "$evidence/census-runtimes-after-1.status")" "ok 0 match(es)"

# A runtime that exits on its own while it is checked (as a stopped one
# does): it shows in the first check, is gone by a later one, and passes.
(exec -a "$tmp/h/Library/Application Support/b.$((n + 1))+x/runtime/0.1.0-0123456789abcdef/zmx attach --create-only TOKEN-SECRET" sleep 1.5) &
started+=($!); sleep 0.2
PERSIST_SETTLE_TRIES=10 case_run 0
check "a runtime that exits during the checks leaves a clean pass" "$s" 0
check "it was seen, then seen gone" \
    "$(grep -c '^census runtimes-after-1: ok 1 match' "$tmp/c$n.out")/$(grep -c '^census runtimes-after-[0-9]*: ok 0 match' "$tmp/c$n.out")" "1/1"
started=()

# A runtime that ended before the census: proved gone, a clean pass.
runtime "b.$((n + 1))+x"; for p in "${started[@]}"; do kill "$p" 2>/dev/null; wait "$p" 2>/dev/null; done; started=()
case_run 0
check "a runtime gone before the census leaves a clean pass" "$s" 0

FAKE_FORGET=fail case_run 0
check "saved windows that cannot be forgotten fail the run" "$s" 7
check "the forget failure is named and the state kept" "$(problem 'forgotten')/$(kept)" "1/kept"

PERSIST_RM="$tmp/rm-fails" case_run 0
check "state that cannot be removed fails the run" "$s" 7
check "the removal failure is named and the evidence kept" "$(problem 'could not be removed')/$([ -f "$evidence/status.txt" ] && echo kept || echo lost)" "1/kept"

# An earlier failure keeps its own status over a cleanup problem.
s=0; persist_outcome 3 7 || s=$?; check "an earlier failure is kept first" "$s" 3
s=0; persist_outcome 0 7 || s=$?; check "an unproved cleanup fails a passing case" "$s" 7
s=0; persist_outcome 0 0 || s=$?; check "a clean case passes" "$s" 0

[ "$failed" -eq 0 ] && echo "persist-case: all checks passed" || echo "persist-case: FAILED"
exit "$failed"
