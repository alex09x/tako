#!/bin/sh
# tako — C ABI example assembly
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT

# Builds the TakoCore static library and links this example against it.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
mitts build --release --lib --manifest-path "$root/Cargo.toml"
# The system libraries the Rust standard library needs on this platform.
native_info=$(mitts rustc --release --lib --manifest-path "$root/Cargo.toml" --crate-type staticlib \
    -- --print native-static-libs 2>&1) || { printf '%s\n' "$native_info" >&2; exit 1; }
libs=$(printf '%s\n' "$native_info" | sed -n 's/.*native-static-libs: //p' | tail -1 \
    | tr ' ' '\n' | awk 'NF && !seen[$0]++' | tr '\n' ' ')
${CC:-cc} -std=c11 -Wall -Wextra -O2 -I "$root/include" "$here/headless.c" \
    "$root/target/release/libtako_core.a" $libs -o "$here/headless"
echo "built $here/headless"
