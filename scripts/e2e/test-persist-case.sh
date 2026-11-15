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
# persist-case.sh without a screen or a session runtime: zmx, the census,
# forgetting saved windows and rm are stand-ins steered per case; no real
# process is listed, stopped or signalled. Exits non-zero on any failure.
set -uo pipefail
cd "$(dirname "$0")"
. ./persist-case.sh

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
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
cat > "$tmp/rm-fails" <<'SH'
#!/bin/bash
exit 1
SH
chmod +x "$tmp/zmx" "$tmp/forget" "$tmp/rm-fails"
fake_census() {
    case "${FAKE_CENSUS:-none}" in
      none) return 0 ;;
      fail) echo "pgrep: failed" >&2; return 2 ;;
      survivor) [ "$1" = "$survivor_pattern" ] && printf '4242\tSat Nov 14 00:00:00 2026\n'; return 0 ;;
    esac
}
export PERSIST_ZMX="$tmp/zmx" PERSIST_FORGET="$tmp/forget" PERSIST_CENSUS=fake_census FORGOT="$tmp/forgot"

# case NAME RUNNER_STATUS: a fresh case with one session; then persist_finish.
n=0
case_run() {
    local name="$1" runner="$2"
    n=$((n + 1))
    sessions="$tmp/c$n/sessions"; support="$tmp/c$n/support"; evidence="$tmp/c$n/evidence"
    mkdir -p "$sessions/.tako-sessions/main" "$support"
    survivor_pattern="$sessions"
    : > "$FORGOT"
    s=0; persist_finish "$runner" "$sessions" "$support" "bundle-$n" "/x/Tako.app/Contents/MacOS/Tako" "$evidence" 2> "$tmp/c$n.err" || s=$?
}
kept() { [ -d "$sessions" ] && [ -d "$support" ] && [ -f "$evidence/status.txt" ] && echo kept || echo lost; }
problem() { grep -c -- "$1" "$evidence/cleanup-problems.txt" 2>/dev/null || echo 0; }

case_run success 0
check "a clean pass is 0" "$s" 0
check "a clean pass removes namespace, profile and evidence" \
    "$([ -e "$sessions" ] || [ -e "$support" ] || [ -e "$evidence" ] && echo left || echo gone)" gone
check "a clean pass forgets its saved windows" "$(cat "$FORGOT")" "forgot bundle-$n"

case_run runner-failure 3
check "a runner failure keeps its own status" "$s" 3
check "a runner failure keeps namespace, profile and evidence" "$(kept)" kept
check "a runner failure stops nothing and forgets nothing" "$([ -e "$sessions/.tako-sessions/main/killed" ] || [ -s "$FORGOT" ] && echo touched || echo untouched)" untouched

FAKE_LIST=fail case_run inventory-failure 0
check "a failed inventory fails a passing run with 7" "$s" 7
check "a failed inventory is not taken as empty" "$(problem 'inventory of')" 1
check "a failed inventory keeps everything" "$(kept)" kept

FAKE_KILL=fail case_run refused-stop 0
check "a refused stop fails a passing run with 7" "$s" 7
check "a refused stop is named" "$(problem 'refused')" 1
check "a refused stop keeps everything" "$(kept)" kept

FAKE_LIST=stuck case_run survivor-listed 0
check "a session still listed after its stop fails the run" "$s" 7
check "the listed survivor is named" "$(problem 'still listed')" 1
check "a listed survivor keeps everything" "$(kept)" kept

FAKE_CENSUS=survivor case_run survivor-running 0
check "a process still running on the namespace fails the run" "$s" 7
check "the running survivor is named" "$(problem 'still running')" 1
check "a running survivor keeps everything" "$(kept)" kept

FAKE_CENSUS=fail case_run census-failure 0
check "a failed census fails the run" "$s" 7
check "a failed census is not taken as nothing running" "$(problem 'census of')" 2
check "a failed census keeps everything" "$(kept)" kept

FAKE_FORGET=fail case_run forget-failure 0
check "saved windows that cannot be forgotten fail the run" "$s" 7
check "the forget failure is named and the state kept" "$(problem 'forgotten')/$(kept)" "1/kept"

PERSIST_RM="$tmp/rm-fails" case_run state-removal-failure 0
check "state that cannot be removed fails the run" "$s" 7
check "the removal failure is named and the evidence kept" "$(problem 'could not be removed')/$([ -f "$evidence/status.txt" ] && echo kept || echo lost)" "1/kept"

# An earlier failure keeps its own status over a cleanup problem.
s=0; persist_outcome 3 7 || s=$?; check "an earlier failure is kept first" "$s" 3
s=0; persist_outcome 0 7 || s=$?; check "an unproved cleanup fails a passing case" "$s" 7
s=0; persist_outcome 0 0 || s=$?; check "a clean case passes" "$s" 0

[ "$failed" -eq 0 ] && echo "persist-case: all checks passed" || echo "persist-case: FAILED"
exit "$failed"
