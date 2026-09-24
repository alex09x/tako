#!/bin/bash
# Build TakoCore.xcframework, zip it for a GitHub release, and point the root
# Package.swift at that release asset.
#
#   scripts/package-xcframework.sh v0.2.0
#   gh release create v0.2.0 target/TakoCore.xcframework.zip
#
# Consumers of the root package download the zip and SwiftPM verifies it
# against the checksum written here, so commit Package.swift together with
# the tag the release is cut from.
set -euo pipefail

VERSION="${1:?usage: $0 <version tag, e.g. v0.2.0>}"
REPO="${TAKO_GITHUB_REPO:-alex09x/tako}"
cd "$(dirname "$0")/.."

./scripts/build-xcframework.sh
rm -f target/TakoCore.xcframework.zip
ditto -c -k --sequesterRsrc --keepParent TakoCore.xcframework target/TakoCore.xcframework.zip
SUM=$(swift package compute-checksum target/TakoCore.xcframework.zip)

URL="https://github.com/$REPO/releases/download/$VERSION/TakoCore.xcframework.zip"
perl -0pi -e "s#url: \"[^\"]*TakoCore\.xcframework\.zip\"#url: \"$URL\"#; s#checksum: \"[0-9a-f]{64}\"#checksum: \"$SUM\"#" Package.swift

echo "zip:      target/TakoCore.xcframework.zip"
echo "url:      $URL"
echo "checksum: $SUM"
