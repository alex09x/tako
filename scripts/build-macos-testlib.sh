#!/bin/bash
# The macOS-only subset of build-xcframework.sh: the static library and the
# generated bindings `scripts/swift-test.sh` links against, and nothing else.
#
# A full xcframework is four slices (arm64 macOS, x86_64 macOS, iOS device, iOS
# simulator) plus xcodebuild packaging -- far too slow to sit in front of every
# Swift test run. `swift test` only ever links target/macos/libtako_core.a and
# reads target/xcframework-headers, so that is all this builds.
set -e

cd "$(dirname "$0")/.."

echo "🔨 Compiling release build (aarch64-apple-darwin)..."
MACOSX_DEPLOYMENT_TARGET=13.0 cargo build --release --lib --features ssh --target aarch64-apple-darwin

echo "🧬 Staging target/macos/libtako_core.a..."
mkdir -p target/macos
# Single slice, but still through lipo: the file swift-test.sh links has to be
# produced the same way the xcframework's macOS slice is.
lipo -create -output target/macos/libtako_core.a \
    target/aarch64-apple-darwin/release/libtako_core.a

echo "🔗 Generating Swift bindings via UniFFI..."
./scripts/bindings.sh --force

# Clang/SwiftPM only auto-discovers a module map under the conventional
# filename, so the staged header directory carries both names -- exactly as
# build-xcframework.sh stages it.
echo "📁 Staging target/xcframework-headers..."
rm -f target/bindings/module.modulemap
rm -rf target/xcframework-headers
mkdir -p target/xcframework-headers
cp target/bindings/tako_coreFFI.h target/xcframework-headers/
cp target/bindings/tako_core.swift target/xcframework-headers/
cp target/bindings/tako_coreFFI.modulemap target/xcframework-headers/tako_coreFFI.modulemap
cp target/bindings/tako_coreFFI.modulemap target/xcframework-headers/module.modulemap

mkdir -p swift/Sources/TakoCoreUI/Generated
cp target/bindings/tako_core.swift swift/Sources/TakoCoreUI/Generated/tako_core.swift

echo "✅ macOS test library ready (target/macos/libtako_core.a)."
