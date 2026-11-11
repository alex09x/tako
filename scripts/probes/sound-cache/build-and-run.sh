#!/bin/bash
# tako — Build, Developer-ID-sign and run the sound-cache probe under a unique identity.
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT
#
# Compiles on the test Mac through scripts/mac-remote.sh, signs here with the Developer ID
# identity, runs there over ssh (no UI). Every remote step's own status is kept and each
# result is validated (validate.py); the remote bundle is removed only after both steps
# succeeded and no probe process is left. Any failure exits nonzero and keeps the evidence.
#   build-and-run.sh OUT_DIR IDENTITY_SHA1
# Tests: SSH/SCP replace ssh/scp, and PROBE_APP=<signed app> PROBE_BUNDLE PROBE_GROUP skip the build.
set -euo pipefail
OUT=$1; IDENTITY=${2:-}
HERE=$(cd "$(dirname "$0")" && pwd)
SSH=${SSH:-ssh}; SCP=${SCP:-scp}
TEAM=284V2M3LN9; NAME=Glass
MAC=${TAKO_MAC:?}; DIR=${TAKO_MAC_DIR:-}
mkdir -p "$OUT"; chmod 700 "$OUT"
fail() { echo "FAILED: $*" | tee -a "$OUT/status.txt"; exit 1; }

if [ -n "${PROBE_APP:-}" ]; then
  APP=$PROBE_APP; BUNDLE=${PROBE_BUNDLE:?}; GROUP=${PROBE_GROUP:?}
else
  ID=$(uuidgen | tr 'A-Z' 'a-z' | cut -c1-8)
  BUNDLE=com.tako-core.probe.soundcache.$ID; GROUP=$TEAM.com.tako-core.probe.soundcache.$ID
  # 1. Compile on the test Mac, from the synced checkout.
  TAKO_MAC=$MAC TAKO_MAC_DIR=${DIR:?} scripts/mac-remote.sh \
    "mkdir -p target/probe-soundcache && swiftc -O -o target/probe-soundcache/probe scripts/probes/sound-cache/main.swift swift/Sources/TakoApp/Features/Notifications/ActivitySoundCache.swift && shasum -a 256 target/probe-soundcache/probe" \
    < /dev/null > "$OUT/compile.log" 2>&1 || fail "compile"
  $SCP -q "$MAC:$DIR/target/probe-soundcache/probe" "$OUT/probe.bin" || fail "copy back"
  # 2. A minimal bundle, its own identity and group, signed with hardened runtime.
  APP="$OUT/SoundCacheProbe.app"
  mkdir -p "$APP/Contents/MacOS"; cp "$OUT/probe.bin" "$APP/Contents/MacOS/probe"
  cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$BUNDLE</string>
<key>CFBundleExecutable</key><string>probe</string>
<key>CFBundleName</key><string>SoundCacheProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
EOF
  cat > "$OUT/probe.entitlements" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.application-groups</key><array><string>$GROUP</string></array>
</dict></plist>
EOF
  codesign --force --options runtime --timestamp --entitlements "$OUT/probe.entitlements" --sign "${IDENTITY:?}" "$APP"
  codesign --verify --strict --deep "$APP"
  { codesign -dv --verbose=4 "$APP" 2>&1 | grep -E '^(Identifier|Authority=Developer ID Application|TeamIdentifier|CDHash=|Runtime)'; \
    codesign -d --entitlements :- "$APP" 2>/dev/null; } > "$OUT/signature.txt"
fi
echo "bundle $BUNDLE group $GROUP" | tee "$OUT/identity.txt"

# 3. Run on the test Mac: place, validate, remove the validated file, validate, prove the process gone.
RUN=/tmp/probe-soundcache-${GROUP##*.}
REMOTE="$RUN/SoundCacheProbe.app/Contents/MacOS/probe"
$SSH -o ConnectTimeout=10 "$MAC" "mkdir -p $RUN && chmod 700 $RUN" || fail "remote dir"
$SCP -q -r "$APP" "$MAC:$RUN/SoundCacheProbe.app" || fail "copy probe"
set +e
$SSH "$MAC" "$REMOTE place $GROUP $NAME" > "$OUT/place.json" 2> "$OUT/place.err"; PLACE=$?
set -e
python3 -I "$HERE/validate.py" place "$OUT/place.json" "$PLACE" "$BUNDLE" "$GROUP" "$NAME" | tee "$OUT/place.valid" \
  | grep -qx valid || fail "place: $(cat "$OUT/place.valid") (remote bundle kept at $RUN)"
SHA=$(python3 -I -c 'import json,sys; print(json.loads(open(sys.argv[1]).read())["sha256"])' "$OUT/place.json")
set +e
$SSH "$MAC" "$REMOTE remove $GROUP $NAME" > "$OUT/remove.json" 2> "$OUT/remove.err"; REMOVE=$?
set -e
python3 -I "$HERE/validate.py" remove "$OUT/remove.json" "$REMOVE" "$BUNDLE" "$GROUP" "$NAME" "$SHA" | tee "$OUT/remove.valid" \
  | grep -qx valid || fail "remove: $(cat "$OUT/remove.valid") (remote bundle kept at $RUN)"
set +e
$SSH "$MAC" "pgrep -f $RUN/" > "$OUT/pgrep.txt" 2>&1; PG=$?
set -e
[ "$PG" = 1 ] || fail "probe process still present or pgrep failed (status $PG); remote bundle kept at $RUN"
$SSH "$MAC" "rm -rf $RUN" || fail "remote bundle removal"
echo "ok: placed and removed $SHA; no probe process; remote bundle removed" | tee "$OUT/status.txt"
