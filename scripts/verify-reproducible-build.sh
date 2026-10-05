#!/bin/bash
#
# tako — Terminal emulator
# Copyright (c) 2026 Alexander Panasenko
#
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT
#

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Verify bit-for-bit reproducible compilation of TakoCore's engine library
(libtako_core.a) across isolated build roots using pinned build inputs.

Options:
  --verify       Default. Build in two independent isolated directories and
                 verify identical SHA-256 hashes.
  --build-only   Build reproducible libtako_core.a in current repository.
  --help, -h     Show this help message.

Environment:
  SOURCE_DATE_EPOCH   Deterministic timestamp epoch (defaults to git commit timestamp)
  ZERO_AR_DATE        Set to 1 to zero archive member timestamps (default: 1)
  MACOSX_DEPLOYMENT_TARGET Deployment target (default: 14.0)
EOF
}

MODE="verify"
for arg in "$@"; do
    case "$arg" in
        --verify)
            MODE="verify"
            ;;
        --build-only)
            MODE="build-only"
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $arg" >&2
            usage >&2
            exit 1
            ;;
    esac
done

# Ensure cargo and rustc are present
command -v cargo >/dev/null 2>&1 || { echo "error: cargo not found" >&2; exit 1; }
command -v rustc >/dev/null 2>&1 || { echo "error: rustc not found" >&2; exit 1; }

# Pinned build inputs
EPOCH="${SOURCE_DATE_EPOCH:-$(git -C "$ROOT" log -1 --pretty=%ct 2>/dev/null || echo 1700000000)}"
export SOURCE_DATE_EPOCH="$EPOCH"
export ZERO_AR_DATE=1
export MACOSX_DEPLOYMENT_TARGET="14.0"

sha256() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        python3 -c "import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], 'rb').read()).hexdigest())" "$1"
    fi
}

if [ "$MODE" = "build-only" ]; then
    echo "🔨 Building reproducible TakoCore engine in ${ROOT}..."
    export RUSTFLAGS="--remap-path-prefix=${ROOT}=/tako"
    cargo build --release --lib --features ssh --target aarch64-apple-darwin
    LIB_PATH="${ROOT}/target/aarch64-apple-darwin/release/libtako_core.a"
    HASH="$(sha256 "$LIB_PATH")"
    echo "✅ Engine artifact built successfully:"
    echo "   File:   $LIB_PATH"
    echo "   SHA256: $HASH"
    exit 0
fi

# Verification mode: build across two independent isolated directories
echo "🔬 Starting reproducible build verification across isolated build trees..."
echo "   Rustc:               $(rustc --version)"
echo "   Cargo:               $(cargo --version)"
echo "   SOURCE_DATE_EPOCH:   $SOURCE_DATE_EPOCH"
echo "   ZERO_AR_DATE:        $ZERO_AR_DATE"
echo "   DEPLOYMENT_TARGET:   $MACOSX_DEPLOYMENT_TARGET"

TMP_DIR="$(mktemp -d -t tako-repro-XXXXXX)"
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

BUILD_A="${TMP_DIR}/build-a"
BUILD_B="${TMP_DIR}/build-b"

copy_sources() {
    local dest="$1"
    mkdir -p "$dest"
    # Copy source tree excluding build artifacts and git internals
    tar -C "$ROOT" \
        --exclude="./target" \
        --exclude="./.git" \
        --exclude="./.build" \
        -cf - . | tar -C "$dest" -xf -
}

echo "📂 Staging Build A..."
copy_sources "$BUILD_A"

echo "📂 Staging Build B..."
copy_sources "$BUILD_B"

echo "🔨 [1/2] Compiling Build A (path prefix: ${BUILD_A} -> /tako)..."
(
    cd "$BUILD_A"
    export RUSTFLAGS="--remap-path-prefix=${BUILD_A}=/tako"
    cargo build --release --lib --features ssh --target aarch64-apple-darwin --quiet
)

echo "🔨 [2/2] Compiling Build B (path prefix: ${BUILD_B} -> /tako)..."
(
    cd "$BUILD_B"
    export RUSTFLAGS="--remap-path-prefix=${BUILD_B}=/tako"
    cargo build --release --lib --features ssh --target aarch64-apple-darwin --quiet
)

LIB_A="${BUILD_A}/target/aarch64-apple-darwin/release/libtako_core.a"
LIB_B="${BUILD_B}/target/aarch64-apple-darwin/release/libtako_core.a"

if [ ! -f "$LIB_A" ]; then
    echo "❌ Error: Build A did not produce $LIB_A" >&2
    exit 1
fi

if [ ! -f "$LIB_B" ]; then
    echo "❌ Error: Build B did not produce $LIB_B" >&2
    exit 1
fi

HASH_A="$(sha256 "$LIB_A")"
HASH_B="$(sha256 "$LIB_B")"

echo "📊 Comparing build artifacts:"
echo "   Build A SHA256: $HASH_A"
echo "   Build B SHA256: $HASH_B"

if [ "$HASH_A" = "$HASH_B" ]; then
    echo "✅ SUCCESS: Bit-for-bit reproducible engine artifact confirmed!"
    echo "   Both independent builds produced byte-identical libtako_core.a."
    echo "   Checksum: $HASH_A"
    exit 0
else
    echo "❌ FAILURE: Build artifacts differ between isolated trees." >&2
    echo "   Diff of sizes:" >&2
    ls -l "$LIB_A" "$LIB_B" >&2
    exit 1
fi
