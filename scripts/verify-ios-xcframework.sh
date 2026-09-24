#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

echo "🔍 Verifying TakoCore.xcframework for production distribution..."

XCFRAMEWORK_DIR="TakoCore.xcframework"
INFO_PLIST="$XCFRAMEWORK_DIR/Info.plist"

if [ ! -d "$XCFRAMEWORK_DIR" ]; then
    echo "❌ Error: $XCFRAMEWORK_DIR directory does not exist" >&2
    exit 1
fi

if [ ! -f "$INFO_PLIST" ]; then
    echo "❌ Error: $INFO_PLIST does not exist" >&2
    exit 1
fi

# 1. Verify exact directory slices
ACTUAL_DIRS=$(find "$XCFRAMEWORK_DIR" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort)
EXPECTED_DIRS=$(printf "ios-arm64\nios-arm64-simulator\nmacos-arm64\n" | sort)
if [ "$ACTUAL_DIRS" != "$EXPECTED_DIRS" ]; then
    echo "❌ Error: Framework slice directories mismatch." >&2
    echo "Expected: $EXPECTED_DIRS" >&2
    echo "Actual:   $ACTUAL_DIRS" >&2
    exit 1
fi

# 2. Verify Info.plist contains exactly the 3 slices
python3 - << 'PY_EOF'
import plistlib
import sys

with open("TakoCore.xcframework/Info.plist", "rb") as f:
    plist = plistlib.load(f)

libraries = plist.get("AvailableLibraries", [])
if len(libraries) != 3:
    print(f"❌ Error: Expected 3 AvailableLibraries, found {len(libraries)}", file=sys.stderr)
    sys.exit(1)

identifiers = sorted([lib.get("LibraryIdentifier") for lib in libraries])
expected_identifiers = ["ios-arm64", "ios-arm64-simulator", "macos-arm64"]
if identifiers != expected_identifiers:
    print(f"❌ Error: Library identifiers mismatch. Expected {expected_identifiers}, got {identifiers}", file=sys.stderr)
    sys.exit(1)

for lib in libraries:
    ident = lib.get("LibraryIdentifier")
    platform = lib.get("SupportedPlatform")
    archs = lib.get("SupportedArchitectures", [])
    if "arm64" not in archs:
        print(f"❌ Error: Missing arm64 in {ident}", file=sys.stderr)
        sys.exit(1)
    if ident.startswith("ios") and platform != "ios":
        print(f"❌ Error: Expected ios platform for {ident}, got {platform}", file=sys.stderr)
        sys.exit(1)
    if ident.startswith("macos") and platform != "macos":
        print(f"❌ Error: Expected macos platform for {ident}, got {platform}", file=sys.stderr)
        sys.exit(1)
PY_EOF

# 3. Verify static library binaries exist and are non-empty
for slice in ios-arm64 ios-arm64-simulator macos-arm64; do
    lib_file="$XCFRAMEWORK_DIR/$slice/libtako_core.a"
    if [ ! -s "$lib_file" ]; then
        echo "❌ Error: Static library missing or empty: $lib_file" >&2
        exit 1
    fi
done

# 4. Verify all blobs/files are strictly below 100 MB (< 100,000,000 bytes)
OVERSIZED_FILES=$(find "$XCFRAMEWORK_DIR" -type f -size +100000000c -print)
if [ -n "$OVERSIZED_FILES" ]; then
    echo "❌ Error: Found file(s) >= 100 MB in $XCFRAMEWORK_DIR:" >&2
    echo "$OVERSIZED_FILES" >&2
    exit 1
fi

# 5. Verify byte-identical Swift bindings and headers across copies
GENERATED_SWIFT="swift/Sources/TakoCoreUI/Generated/tako_core.swift"
MACOS_SWIFT="$XCFRAMEWORK_DIR/macos-arm64/Headers/tako_core.swift"
DEVICE_SWIFT="$XCFRAMEWORK_DIR/ios-arm64/Headers/tako_core.swift"
SIM_SWIFT="$XCFRAMEWORK_DIR/ios-arm64-simulator/Headers/tako_core.swift"
MACOS_HEADER="$XCFRAMEWORK_DIR/macos-arm64/Headers/tako_coreFFI.h"
DEVICE_HEADER="$XCFRAMEWORK_DIR/ios-arm64/Headers/tako_coreFFI.h"
SIM_HEADER="$XCFRAMEWORK_DIR/ios-arm64-simulator/Headers/tako_coreFFI.h"

for required_file in "$GENERATED_SWIFT" "$MACOS_SWIFT" "$DEVICE_SWIFT" "$SIM_SWIFT" "$MACOS_HEADER" "$DEVICE_HEADER" "$SIM_HEADER"; do
    if [ ! -f "$required_file" ]; then
        echo "❌ Error: Required header or binding file missing: $required_file" >&2
        exit 1
    fi
done

if ! cmp -s "$GENERATED_SWIFT" "$MACOS_SWIFT"; then
    echo "❌ Error: Generated Swift ($GENERATED_SWIFT) does not match macOS framework copy ($MACOS_SWIFT)" >&2
    diff -u "$GENERATED_SWIFT" "$MACOS_SWIFT" || true
    exit 1
fi

if ! cmp -s "$GENERATED_SWIFT" "$DEVICE_SWIFT"; then
    echo "❌ Error: Generated Swift ($GENERATED_SWIFT) does not match device framework copy ($DEVICE_SWIFT)" >&2
    diff -u "$GENERATED_SWIFT" "$DEVICE_SWIFT" || true
    exit 1
fi

if ! cmp -s "$GENERATED_SWIFT" "$SIM_SWIFT"; then
    echo "❌ Error: Generated Swift ($GENERATED_SWIFT) does not match simulator framework copy ($SIM_SWIFT)" >&2
    diff -u "$GENERATED_SWIFT" "$SIM_SWIFT" || true
    exit 1
fi

if ! cmp -s "$DEVICE_HEADER" "$MACOS_HEADER"; then
    echo "❌ Error: Header mismatch between device ($DEVICE_HEADER) and macOS ($MACOS_HEADER)" >&2
    diff -u "$DEVICE_HEADER" "$MACOS_HEADER" || true
    exit 1
fi

if ! cmp -s "$DEVICE_HEADER" "$SIM_HEADER"; then
    echo "❌ Error: Header mismatch between device ($DEVICE_HEADER) and simulator ($SIM_HEADER)" >&2
    diff -u "$DEVICE_HEADER" "$SIM_HEADER" || true
    exit 1
fi

if [ -f "target/bindings/tako_core.swift" ]; then
    if ! cmp -s "$GENERATED_SWIFT" "target/bindings/tako_core.swift"; then
        echo "❌ Error: Generated Swift does not match target/bindings/tako_core.swift" >&2
        exit 1
    fi
fi

if [ -f "target/bindings/tako_coreFFI.h" ]; then
    if ! cmp -s "$DEVICE_HEADER" "target/bindings/tako_coreFFI.h"; then
        echo "❌ Error: Device header does not match target/bindings/tako_coreFFI.h" >&2
        exit 1
    fi
fi

echo "✅ TakoCore.xcframework verified: 3 slices (macos-arm64, ios-arm64, ios-arm64-simulator), all files < 100MB, byte-identical headers."
