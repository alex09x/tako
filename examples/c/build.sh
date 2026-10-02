#!/bin/sh
# Builds the TakoCore static library and links this example against it.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
cargo build --release --lib --manifest-path "$root/Cargo.toml"
# The system libraries the Rust standard library needs on this platform.
libs=$(cargo rustc --release --lib --manifest-path "$root/Cargo.toml" --crate-type staticlib \
    -- --print native-static-libs 2>&1 | sed -n 's/.*native-static-libs: //p' | tail -1 \
    | tr ' ' '\n' | awk 'NF && !seen[$0]++' | tr '\n' ' ')
${CC:-cc} -std=c11 -Wall -Wextra -O2 -I "$root/include" "$here/headless.c" \
    "$root/target/release/libtako_core.a" $libs -o "$here/headless"
echo "built $here/headless"
