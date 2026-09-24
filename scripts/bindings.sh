#!/usr/bin/env bash
# Generate the UniFFI Swift bindings the Swift package compiles against.
#
# `swift/Sources/TakoApp/_bindings` is a tracked symlink to
# `target/bindings`, which is a build artifact. On a fresh clone that symlink
# therefore dangles, and `swift build` fails on a missing `tako_coreFFI.h`
# with no hint that anything needs generating first. Run this once after
# cloning; `dev.sh` calls it for you.
#
# Regenerating is also mandatory after any change to the FFI surface -- a new
# record, method or enum case -- because a stale file silently describes a
# different ABI than the library it is bound to.
#
#   ./scripts/bindings.sh          # generate if out of date
#   ./scripts/bindings.sh --force  # always regenerate
set -euo pipefail

cd "$(dirname "$0")/.."

OUT=target/bindings
HEADER="$OUT/tako_coreFFI.h"

force=0
[[ "${1:-}" == "--force" ]] && force=1

# The generator reads the compiled library, so it has to exist and be no older
# than the sources that describe it.
newest_source=$(find src Cargo.toml Cargo.lock -type f -newer "$HEADER" -print -quit 2>/dev/null || true)
if [[ $force -eq 0 && -f "$HEADER" && -z "$newest_source" ]]; then
    echo "bindings up to date"
    exit 0
fi

# The apps link the ssh transport, so the bindings have to describe it.
echo "==> cargo build --release"
cargo build --release --features ssh

echo "==> uniffi-bindgen"
mkdir -p "$OUT"
cargo run --quiet --bin uniffi-bindgen --features uniffi-cli,ssh -- \
    generate --language swift --out-dir "$OUT" \
    target/release/libtako_core.dylib

# build-macapp.py normalizes these the same way; keeping it here means a
# tree bootstrapped by either route looks identical.
sed -i '' -E 's/[[:space:]]+$//' "$OUT/tako_core.swift" "$HEADER"

mkdir -p swift/Sources/TakoCoreUI/Generated
cp "$OUT/tako_core.swift" swift/Sources/TakoCoreUI/Generated/tako_core.swift

echo "generated $OUT"
ls -1 "$OUT"

# The Swift package links TakoCore.xcframework, a prebuilt binary, not
# target/release. So a new FFI method appears in the generated Swift the
# moment this script runs, while the symbol it calls does not exist until the
# framework is rebuilt -- and `swift test` fails with a bare "linker command
# failed" that names nothing. Say so here instead.
if [[ -d TakoCore.xcframework ]] \
   && [[ -n "$(find src/ffi -type f -newer TakoCore.xcframework -print -quit 2>/dev/null)" ]]; then
    echo
    echo "warning: src/ffi is newer than TakoCore.xcframework."
    echo "         The Swift package links that framework, so any FFI method"
    echo "         added since it was built will fail to link. Run:"
    echo "             ./scripts/build-xcframework.sh"
fi
