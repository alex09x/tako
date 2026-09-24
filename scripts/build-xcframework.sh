#!/bin/bash
set -e

# Navigate to the project root
cd "$(dirname "$0")/.."

IOS_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --ios-only)
            IOS_ONLY=1
            ;;
    esac
done

if [ "$IOS_ONLY" -eq 1 ]; then
    echo "🚀 Starting iOS-only build for TakoCore.xcframework..."
else
    echo "🚀 Starting production macOS (arm64) & iOS build for TakoCore.xcframework..."
fi

# 1. Install rustup targets
echo "📦 Installing rustup targets..."
rustup target add aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim

# 2. Build libraries
#    --lib explicitly scopes the build to the [lib] targets (staticlib/cdylib/rlib).
echo "🔨 Compiling release builds..."
# The macOS library is built even for --ios-only: the Swift bindings are
# generated from it below, and generating them from a stale copy would ship
# bindings that no longer match the iOS libraries. arm64 only, deliberately:
# a universal slice more than doubles the release asset.
MACOSX_DEPLOYMENT_TARGET=14.0 cargo build --release --lib --features ssh --target aarch64-apple-darwin
IPHONEOS_DEPLOYMENT_TARGET=17.0 cargo build --release --lib --features ssh --target aarch64-apple-ios
IPHONEOS_DEPLOYMENT_TARGET=17.0 cargo build --release --lib --features ssh --target aarch64-apple-ios-sim

# 3. macOS slice staging
if [ "$IOS_ONLY" -ne 1 ]; then
    mkdir -p target/macos
    cp target/aarch64-apple-darwin/release/libtako_core.a target/macos/libtako_core.a
fi

# 4. Generate Swift bindings via UniFFI (proc-macro / library-mode workflow, UniFFI 0.32).
echo "🔗 Generating Swift bindings via UniFFI..."
mkdir -p target/bindings
cargo run --quiet --bin uniffi-bindgen --features uniffi-cli -- \
    generate \
    --language swift \
    --out-dir target/bindings \
    target/aarch64-apple-darwin/release/libtako_core.dylib

# UniFFI 0.32 emits trailing spaces on generated Swift lines. Strip only
# end-of-line whitespace so regenerated bindings stay reviewable and pass the
# repository whitespace gate without changing any tokens.
LC_ALL=C sed -i '' -E 's/[[:space:]]+$//' target/bindings/tako_core.swift
LC_ALL=C sed -i '' -E 's/[[:space:]]+$//' target/bindings/tako_coreFFI.h

# Clang/SwiftPM only auto-discovers a module map in an XCFramework Headers
# directory when it has the conventional filename. UniFFI names the file
# after the crate, which works with an explicit bridging header but made
# `canImport(tako_coreFFI)` false for the TakoCoreUI SwiftPM target. Stage a
# dedicated header directory so target/bindings keeps only UniFFI's original
# map; the Tako test target also puts that directory on its header search
# path, and two discoverable maps would redefine the module.
rm -f target/bindings/module.modulemap
rm -rf target/xcframework-headers
mkdir -p target/xcframework-headers
cp target/bindings/tako_coreFFI.h target/xcframework-headers/
cp target/bindings/tako_core.swift target/xcframework-headers/
cp target/bindings/tako_coreFFI.modulemap target/xcframework-headers/tako_coreFFI.modulemap
cp target/bindings/tako_coreFFI.modulemap target/xcframework-headers/module.modulemap

mkdir -p swift/Sources/TakoCoreUI/Generated
cp target/bindings/tako_core.swift swift/Sources/TakoCoreUI/Generated/tako_core.swift

# 5. Assemble XCFramework
echo "🍏 Packaging into TakoCore.xcframework..."
rm -rf TakoCore.xcframework
if [ "$IOS_ONLY" -eq 1 ]; then
    xcodebuild -create-xcframework \
        -library target/aarch64-apple-ios/release/libtako_core.a -headers target/xcframework-headers \
        -library target/aarch64-apple-ios-sim/release/libtako_core.a -headers target/xcframework-headers \
        -output TakoCore.xcframework
else
    xcodebuild -create-xcframework \
        -library target/macos/libtako_core.a -headers target/xcframework-headers \
        -library target/aarch64-apple-ios/release/libtako_core.a -headers target/xcframework-headers \
        -library target/aarch64-apple-ios-sim/release/libtako_core.a -headers target/xcframework-headers \
        -output TakoCore.xcframework
fi

# Ensure deterministic plist ordering for stable, idempotent XCFramework outputs.
python3 - << 'PY'
import plistlib
from pathlib import Path

INFO_PLIST = Path("TakoCore.xcframework/Info.plist")

with INFO_PLIST.open("rb") as handle:
    plist = plistlib.load(handle)

libraries = plist.get("AvailableLibraries")
if isinstance(libraries, list):
    plist["AvailableLibraries"] = sorted(
        libraries,
        key=lambda lib: (
            lib.get("LibraryIdentifier", ""),
            lib.get("SupportedPlatformVariant", ""),
        ),
    )

with INFO_PLIST.open("wb") as handle:
    plistlib.dump(plist, handle, fmt=plistlib.FMT_XML, sort_keys=True)
PY

echo "✅ TakoCore.xcframework built successfully!"
echo "ℹ️  Generated Swift sources are in target/bindings/*.swift and swift/Sources/TakoCoreUI/Generated/tako_core.swift"
