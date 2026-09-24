#!/bin/bash
# Archive the iOS app and upload it to TestFlight.
#
# Signing is automatic: `-allowProvisioningUpdates` lets Xcode mint the
# development and distribution certificates and the provisioning profile from
# the account Xcode is signed in as, so there is nothing to install by hand.
#
# The one thing it cannot create is the App Store Connect *app record*. Until
# `dev.prod.takocore` exists there, the upload is rejected with "no suitable
# application record"; create it once at
# https://appstoreconnect.apple.com/apps -> + -> New App, picking the
# dev.prod.takocore bundle ID, and every run after that is unattended.
#
#   ./scripts/deploy-ios-testflight.sh            # archive, export, upload
#   ./scripts/deploy-ios-testflight.sh --no-upload  # stop at a signed .ipa
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

TEAM_ID="${TAKO_APPLE_TEAM_ID:-284V2M3LN9}"
BUNDLE_ID="dev.prod.takocore"
# App Store Connect refuses a build number it has already seen, and rejecting
# it happens after the upload rather than before, so it defaults to something
# that cannot repeat.
BUILD_NUMBER="${TAKO_IOS_BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}"
DESTINATION="upload"

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --no-upload) DESTINATION="export"; shift ;;
        --build-number)
            [[ "$#" -ge 2 ]] || { echo "usage: $0 [--no-upload] [--build-number N]" >&2; exit 2; }
            BUILD_NUMBER="$2"; shift 2 ;;
        *) echo "usage: $0 [--no-upload] [--build-number N]" >&2; exit 2 ;;
    esac
done

[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]{0,17}$ ]] || {
    echo "[testflight] build number must be 1-18 decimal digits" >&2
    exit 1
}

for tool in xcodegen xcodebuild plutil codesign; do
    command -v "$tool" >/dev/null || { echo "[testflight] missing $tool" >&2; exit 1; }
done

OUT_DIR="$ROOT_DIR/target/testflight/$BUILD_NUMBER"
ARCHIVE="$OUT_DIR/TakoCore.xcarchive"
EXPORT_DIR="$OUT_DIR/export"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

# The project is generated, not committed, so it can never drift from the
# source directories it lists.
echo "[testflight] generating the Xcode project"
xcodegen -s ios/project.yml -p ios --quiet

echo "[testflight] archiving build=$BUILD_NUMBER"
xcodebuild \
    -project ios/TakoCore.xcodeproj \
    -scheme TakoCore \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    archive

APP_PATH="$ARCHIVE/Products/Applications/TakoCore.app"
[[ -d "$APP_PATH" ]] || { echo "[testflight] archive has no TakoCore.app" >&2; exit 1; }

# Checking the archive rather than trusting the build settings: a stale
# DerivedData hit or a scheme pointing at another configuration both surface
# here, and both would otherwise be found by App Store Connect instead.
INFO_PLIST="$APP_PATH/Info.plist"
[[ "$(plutil -extract CFBundleIdentifier raw -o - "$INFO_PLIST")" == "$BUNDLE_ID" ]] || {
    echo "[testflight] archive bundle identifier mismatch" >&2; exit 1; }
[[ "$(plutil -extract CFBundleVersion raw -o - "$INFO_PLIST")" == "$BUILD_NUMBER" ]] || {
    echo "[testflight] archive build number mismatch" >&2; exit 1; }
codesign --verify --strict "$APP_PATH"

cat > "$OUT_DIR/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>$DESTINATION</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>uploadSymbols</key><true/>
</dict></plist>
EOF

echo "[testflight] ${DESTINATION}ing"
xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$OUT_DIR/ExportOptions.plist" \
    -allowProvisioningUpdates

if [[ "$DESTINATION" == "export" ]]; then
    echo "[testflight] OK signed ipa at $EXPORT_DIR/TakoCore.ipa"
else
    echo "[testflight] OK uploaded build=$BUILD_NUMBER — processing takes a few minutes"
fi
