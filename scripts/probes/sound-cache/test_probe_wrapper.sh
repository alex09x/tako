#!/bin/bash
# tako — Failure checks for the sound-cache probe wrapper, with fake ssh/scp (no Mac, no signing).
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/tako-probe-wrapper.XXXXXX"); trap 'rm -rf "$WORK"' EXIT
GROUP=284V2M3LN9.com.tako-core.probe.soundcache.fake0001; BUNDLE=com.tako-core.probe.soundcache.fake0001
C="/Users/x/Library/Group Containers/$GROUP"
ok_place="{\"mode\":\"place\",\"bundle\":\"$BUNDLE\",\"group\":\"$GROUP\",\"name\":\"Glass\",\"team\":\"284V2M3LN9\",\"groups\":[\"$GROUP\"],\"container\":\"$C\",\"file\":\"$C/Library/Sounds/tako-Glass.aiff\",\"placed\":\"tako-Glass.aiff\",\"matchesSystemSound\":true,\"sha256\":\"abc\"}"
ok_remove="{\"mode\":\"remove\",\"bundle\":\"$BUNDLE\",\"group\":\"$GROUP\",\"name\":\"Glass\",\"team\":\"284V2M3LN9\",\"groups\":[\"$GROUP\"],\"container\":\"$C\",\"file\":\"$C/Library/Sounds/tako-Glass.aiff\",\"removed\":true,\"sha256\":\"abc\"}"
mkdir -p "$WORK/app"
cat > "$WORK/scp" <<'EOF'
#!/bin/bash
exit 0
EOF
# Fake ssh: behaviour per case from env (PLACE_OUT/PLACE_RC, REMOVE_OUT/REMOVE_RC, PGREP_RC); logs every command.
cat > "$WORK/ssh" <<'EOF'
#!/bin/bash
cmd="${@: -1}"; echo "$cmd" >> "$LOG"
case "$cmd" in
  *" place "*) printf '%s\n' "$PLACE_OUT"; exit "$PLACE_RC" ;;
  *" remove "*) printf '%s\n' "$REMOVE_OUT"; exit "$REMOVE_RC" ;;
  pgrep*) exit "$PGREP_RC" ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$WORK/ssh" "$WORK/scp"
pass=0; fails=0
run() {   # name expected_status env...
  local name=$1 want=$2; shift 2
  export LOG="$WORK/$name.log"; : > "$LOG"
  env "$@" SSH="$WORK/ssh" SCP="$WORK/scp" TAKO_MAC=fake PROBE_APP="$WORK/app" PROBE_BUNDLE=$BUNDLE PROBE_GROUP=$GROUP \
    "$HERE/build-and-run.sh" "$WORK/out-$name" > "$WORK/$name.out" 2>&1
  local got=$?
  local removed=no; grep -q '^rm -rf' "$LOG" && removed=yes
  local good=no
  if [ "$want" = 0 ]; then { [ $got = 0 ] && [ $removed = yes ]; } && good=yes
  else { [ $got != 0 ] && [ $removed = no ]; } && good=yes; fi
  if [ $good = yes ]; then
    pass=$((pass+1)); echo "ok   $name (status $got, remote bundle removed: $removed)"
  else
    fails=$((fails+1)); echo "FAIL $name (status $got, remote bundle removed: $removed)"; cat "$WORK/$name.out"
  fi
}
base=(PLACE_OUT="$ok_place" PLACE_RC=0 REMOVE_OUT="$ok_remove" REMOVE_RC=0 PGREP_RC=1)
run success 0 "${base[@]}"
run place-nonzero 1 "${base[@]}" PLACE_RC=3
run place-malformed 1 "${base[@]}" PLACE_OUT="not json"
run place-bytes-differ 1 "${base[@]}" PLACE_OUT="${ok_place/\"matchesSystemSound\":true/\"matchesSystemSound\":false}"
run place-other-group 1 "${base[@]}" PLACE_OUT="${ok_place//fake0001/other999}"
run remove-nonzero 1 "${base[@]}" REMOVE_RC=4
run remove-refused 1 "${base[@]}" REMOVE_OUT="${ok_remove/\"removed\":true/\"removed\":false}"
run remove-other-file 1 "${base[@]}" REMOVE_OUT="${ok_remove/\"sha256\":\"abc\"/\"sha256\":\"zzz\"}"
run process-left 1 "${base[@]}" PGREP_RC=0
run pgrep-broken 1 "${base[@]}" PGREP_RC=2
echo "$pass passed, $fails failed"
[ $fails = 0 ]
