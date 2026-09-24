#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

BUILD_DIR="target/ios_test_build"
mkdir -p "$BUILD_DIR"
trap 'rm -rf "$BUILD_DIR"' EXIT

echo "=== 1. Running Rust Parity and Core Surface Tests ==="
cargo test --test parity_input_encoding --test parity_resize --test pty_chunk_boundary

echo "=== 2. Building iOS App and Terminal Surface ==="
python3 scripts/build-iosapp.py

# Rust's Apple target defaults do not propagate into C dependencies compiled
# by build scripts. If IPHONEOS_DEPLOYMENT_TARGET is missing, those objects can
# silently inherit the installed SDK's minimum (for example iOS 26.x) while
# the Swift app still claims iOS 17 support. Inspect every archive member so a
# future build-script change fails here instead of on an older phone.
IOS_CORE_LIB="$(pwd)/target/aarch64-apple-ios-sim/release/libtako_core.a"
TOO_NEW_MINIMUMS="$(otool -l "$IOS_CORE_LIB" 2>/dev/null \
    | awk '/^[[:space:]]+minos / && $2 + 0 > 17.0 { print $2 }' \
    | sort -Vu)"
if [[ -n "$TOO_NEW_MINIMUMS" ]]; then
    echo "Rust iOS archive contains objects requiring newer than iOS 17:" >&2
    echo "$TOO_NEW_MINIMUMS" >&2
    exit 1
fi

echo "=== 3. Testing iOS Terminal Surface Build (Simulator) ==="
SDK_PATH="$(xcrun --sdk iphonesimulator --show-sdk-path)"
PLATFORM_PATH="$(xcrun --sdk iphonesimulator --show-sdk-platform-path)"

HEADERS_DIR="$(pwd)/target/bindings"
if [ ! -f "$HEADERS_DIR/tako_coreFFI.h" ]; then
    HEADERS_DIR="$(pwd)/TakoCore.xcframework/ios-arm64-simulator/Headers"
fi

LIB_PATH="$(pwd)/target/aarch64-apple-ios-sim/release/libtako_core.a"
if [ ! -f "$LIB_PATH" ]; then
    LIB_PATH="$(pwd)/TakoCore.xcframework/ios-arm64-simulator/libtako_core.a"
fi

SWIFT_UI_FILES="$(find "$ROOT_DIR/swift/Sources/TakoCoreUI" -maxdepth 1 -name "*.swift")"
GENERATED_SWIFT="$ROOT_DIR/swift/Sources/TakoCoreUI/Generated/tako_core.swift"
if [ ! -f "$GENERATED_SWIFT" ] && [ -f "target/bindings/tako_core.swift" ]; then
    GENERATED_SWIFT="$ROOT_DIR/target/bindings/tako_core.swift"
fi

echo "Compiling TakoCoreUI module for iOS 17+ Simulator..."
swiftc -target arm64-apple-ios17.0-simulator \
    -sdk "$SDK_PATH" \
    -enable-testing \
    -module-name TakoCoreUI \
    -emit-module -emit-module-path "$BUILD_DIR/TakoCoreUI.swiftmodule" \
    -parse-as-library \
    -emit-library -o "$BUILD_DIR/libTakoCoreUI.dylib" \
    -Xlinker -install_name -Xlinker "$(pwd)/$BUILD_DIR/libTakoCoreUI.dylib" \
    -Xcc -I"$HEADERS_DIR" \
    -import-objc-header "$HEADERS_DIR/tako_coreFFI.h" \
    $SWIFT_UI_FILES \
    "$GENERATED_SWIFT" \
    "$LIB_PATH" \
    -framework UIKit -framework Foundation -framework CoreText

cat << 'EOF' > "$BUILD_DIR/main.swift"
import XCTest
import TakoCoreUI
import UIKit

class TestObserver: NSObject, XCTestObservation {
    var failureCount = 0
    var totalCount = 0

    func testCaseDidFinish(_ testCase: XCTestCase) {
        totalCount += 1
        if testCase.testRun?.hasSucceeded == false {
            failureCount += 1
            print("❌ FAIL: \(testCase.name)")
        } else {
            print("✅ PASS: \(testCase.name)")
        }
    }

    func testCase(_ testCase: XCTestCase, didFailWithDescription description: String, inFile filePath: String?, atLine lineNumber: Int) {
        print("  Description: \(description) at \(filePath ?? "?"):\(lineNumber)")
    }
}

let observer = TestObserver()
XCTestObservationCenter.shared.addTestObserver(observer)

let suite = XCTestSuite.default
print("=== Running \(suite.testCaseCount) XCTest cases on iOS Simulator ===")
suite.run()

print("=== Completed \(observer.totalCount) tests with \(observer.failureCount) failures ===")
if observer.failureCount > 0 || observer.totalCount == 0 {
    exit(1)
} else {
    exit(0)
}
EOF

SWIFT_TEST_FILES="$(find "$ROOT_DIR/swift/Tests/TakoCoreUITests" -name "*.swift")"

echo "Compiling XCTest runner binary for iOS 17+ Simulator..."
swiftc -target arm64-apple-ios17.0-simulator \
    -sdk "$SDK_PATH" \
    -F "$PLATFORM_PATH/Developer/Library/Frameworks" \
    -I "$PLATFORM_PATH/Developer/usr/lib" \
    -L "$PLATFORM_PATH/Developer/usr/lib" \
    -Xlinker -rpath -Xlinker "$PLATFORM_PATH/Developer/Library/Frameworks" \
    -Xlinker -rpath -Xlinker "$PLATFORM_PATH/Developer/usr/lib" \
    -Xlinker -rpath -Xlinker "$(pwd)/$BUILD_DIR" \
    -I "$BUILD_DIR" \
    -L "$BUILD_DIR" \
    -lTakoCoreUI \
    -o "$BUILD_DIR/test_runner" \
    $SWIFT_TEST_FILES \
    "$BUILD_DIR/main.swift" \
    -framework UIKit -framework Foundation -framework CoreText -framework XCTest

SIM_DEVICE="$(xcrun simctl list devices booted | grep -E -o '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}' | head -n 1 || true)"
if [ -z "$SIM_DEVICE" ]; then
    SIM_DEVICE="$(xcrun simctl list devices available | grep -E 'iPhone|iPad' | grep -E -o '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}' | head -n 1)"
    xcrun simctl boot "$SIM_DEVICE" || true
fi

echo "Executing XCTest suite on iOS Simulator ($SIM_DEVICE)..."
xcrun simctl spawn "$SIM_DEVICE" "$BUILD_DIR/test_runner"

echo "✅ All iOS terminal surface tests and builds passed successfully!"
