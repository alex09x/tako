#!/bin/bash
# Build the iOS app and install it on a physical iPhone over USB.
#
# This is the short way to have the app in your hand: it needs only the
# development certificate Xcode already manages, so no App Store Connect app
# record and no TestFlight review sit between a change and the phone.
# scripts/deploy-ios-testflight.sh is for handing builds to other people.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

DEVICE="${TAKO_IOS_DEVICE:-}"
if [[ -z "$DEVICE" ]]; then
    # `devicectl` prints a table; the identifier is the column of UUIDs. A
    # reachable phone reads "connected" or "available (paired)" depending on
    # whether a tunnel is already up, so the filter is the state that rules a
    # device out rather than the several that do not.
    DEVICE="$(xcrun devicectl list devices 2>/dev/null \
        | awk '!/unavailable/ { for (i = 1; i <= NF; i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{4}-/) { print $i; exit } }')"
fi
[[ -n "$DEVICE" ]] || {
    echo "[iphone] no paired device — plug the phone in and unlock it" >&2
    exit 1
}

xcodegen -s ios/project.yml -p ios --quiet

DERIVED="$ROOT_DIR/target/ios-derived"
# Built for `generic/platform=iOS` rather than for this device: xcodebuild
# addresses a phone by its hardware UDID while devicectl uses its own
# identifier, and one generic build installs on either.
xcodebuild \
    -project ios/TakoCore.xcodeproj \
    -scheme TakoCore \
    -configuration Debug \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$DERIVED" \
    -allowProvisioningUpdates \
    build

APP="$DERIVED/Build/Products/Debug-iphoneos/TakoCore.app"
[[ -d "$APP" ]] || { echo "[iphone] no app at $APP" >&2; exit 1; }

echo "[iphone] installing to $DEVICE"
xcrun devicectl device install app --device "$DEVICE" "$APP"

# Launching needs the phone unlocked, which is not worth failing the install
# over -- by then the icon is already on the home screen.
xcrun devicectl device process launch --device "$DEVICE" --terminate-existing dev.prod.takocore \
    || echo "[iphone] installed; unlock the phone and tap TakoCore"
