#!/bin/bash
# tako — Build, Developer-ID-sign and run the sound-cache probe under a unique identity.
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT
#
# Compiles on the test Mac through scripts/mac-remote.sh, signs here with the Developer ID
# identity, runs there over ssh (no UI), removes only the sound file it placed and the probe
# bundle it copied. Usage: build-and-run.sh OUT_DIR IDENTITY_SHA1
set -euo pipefail
OUT=$1; IDENTITY=$2
TEAM=284V2M3LN9
ID=$(uuidgen | tr 'A-Z' 'a-z' | cut -c1-8)
BUNDLE=com.tako-core.probe.soundcache.$ID
GROUP=$TEAM.com.tako-core.probe.soundcache.$ID
MAC=${TAKO_MAC:?}; DIR=${TAKO_MAC_DIR:?}
REMOTE_RUN=probe-soundcache-$ID
mkdir -p "$OUT"; chmod 700 "$OUT"
echo "bundle $BUNDLE group $GROUP" | tee "$OUT/identity.txt"

# 1. Compile on the test Mac, from the synced checkout.
TAKO_MAC=$MAC TAKO_MAC_DIR=$DIR scripts/mac-remote.sh \
  "mkdir -p target/probe-soundcache && swiftc -O -o target/probe-soundcache/probe scripts/probes/sound-cache/main.swift swift/Sources/TakoApp/Features/Notifications/ActivitySoundCache.swift && shasum -a 256 target/probe-soundcache/probe" \
  < /dev/null > "$OUT/compile.log" 2>&1
scp -q "$MAC:$DIR/target/probe-soundcache/probe" "$OUT/probe.bin"

# 2. A minimal bundle, its own identity and group, signed with hardened runtime.
APP="$OUT/SoundCacheProbe.app"
mkdir -p "$APP/Contents/MacOS"
cp "$OUT/probe.bin" "$APP/Contents/MacOS/probe"
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
codesign --force --options runtime --timestamp --entitlements "$OUT/probe.entitlements" --sign "$IDENTITY" "$APP"
codesign --verify --strict --deep "$APP"
{ codesign -dv --verbose=4 "$APP" 2>&1 | grep -E '^(Identifier|Authority=Developer ID Application|TeamIdentifier|CDHash=|Runtime)'; \
  codesign -d --entitlements :- "$APP" 2>/dev/null; } > "$OUT/signature.txt"

# 3. Run it on the test Mac over ssh: place, re-read, then remove only what it placed.
ssh -o ConnectTimeout=10 "$MAC" "mkdir -p /tmp/$REMOTE_RUN && chmod 700 /tmp/$REMOTE_RUN"
scp -q -r "$APP" "$MAC:/tmp/$REMOTE_RUN/"
set +e
ssh "$MAC" "/tmp/$REMOTE_RUN/SoundCacheProbe.app/Contents/MacOS/probe place $GROUP Glass; echo \"exit=\$?\"" > "$OUT/place.json" 2>&1
ssh "$MAC" "/tmp/$REMOTE_RUN/SoundCacheProbe.app/Contents/MacOS/probe remove $GROUP Glass; echo \"exit=\$?\"" > "$OUT/remove.json" 2>&1
ssh "$MAC" "pgrep -f /tmp/$REMOTE_RUN/ || echo 'no probe process'" > "$OUT/exit.txt" 2>&1
ssh "$MAC" "rm -rf /tmp/$REMOTE_RUN" ; echo "remote probe dir removed rc=$?" >> "$OUT/exit.txt"
set -e
cat "$OUT/place.json" "$OUT/remove.json" "$OUT/exit.txt"
