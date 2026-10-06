#!/bin/bash
# Builds zmx, the session runtime Tako can keep shells alive with across a
# relaunch (session-persistence, experimental), from a pinned commit with a
# pinned Zig, and prints the path of the result.
#
#   scripts/build-zmx.sh
#
# Only packaging calls this (scripts/build-macapp.py with TAKO_WITH_ZMX=1, and
# release builds): ordinary checks never fetch Zig or zmx. The result is
# cached under target/ by commit, Zig version and build options, so a second
# call does nothing.
set -euo pipefail
cd "$(dirname "$0")/.."

ZMX_REPO=https://github.com/neurosnap/zmx
ZMX_VERSION=0.8.1
ZMX_COMMIT=8bab1f0173b07e79835ea372d749af3dbf0d0842
ZIG_VERSION=0.16.0
ZIG_TARBALL=zig-aarch64-macos-$ZIG_VERSION.tar.xz
ZIG_SHA256=b23d70deaa879b5c2d486ed3316f7eaa53e84acf6fc9cc747de152450d401489
OPTIMIZE=ReleaseSafe

PATCH_KEY=""
if [ -d "patches/zmx" ]; then
    patches=$(ls patches/zmx/*.patch 2>/dev/null || true)
    if [ -n "$patches" ]; then
        PATCH_HASH=$(cat patches/zmx/*.patch | shasum -a 256 | cut -c1-16)
        PATCH_KEY="-patch$PATCH_HASH"
    fi
fi

KEY="$ZMX_COMMIT$PATCH_KEY-zig$ZIG_VERSION-$OPTIMIZE-aarch64-macos"
OUT="target/zmx/$KEY"
# A cache entry is the executable, the record of where it came from and the
# notices that must ship with it -- all of them or it is not used.
complete() {
    [ -x "$1/zmx" ] && [ -s "$1/source.json" ] && [ -s "$1/LICENSE-zmx" ] && [ -s "$1/LICENSE-ghostty" ]
}
if complete "$OUT"; then
    echo "$OUT/zmx"
    exit 0
fi
rm -rf "$OUT"

log() { echo "[build-zmx] $*" >&2; }

# Zig, pinned and checked, kept under target/ -- never installed anywhere else.
ZIG_DIR="target/toolchains/zig-$ZIG_VERSION"
if [ ! -x "$ZIG_DIR/zig" ]; then
    log "fetching Zig $ZIG_VERSION"
    tmp=$(mktemp -d)
    curl -fsSL -o "$tmp/$ZIG_TARBALL" "https://ziglang.org/download/$ZIG_VERSION/$ZIG_TARBALL"
    got=$(shasum -a 256 "$tmp/$ZIG_TARBALL" | cut -d' ' -f1)
    if [ "$got" != "$ZIG_SHA256" ]; then
        log "Zig tarball checksum mismatch: $got"
        rm -rf "$tmp"
        exit 1
    fi
    tar -xJf "$tmp/$ZIG_TARBALL" -C "$tmp"
    mkdir -p target/toolchains
    rm -rf "$ZIG_DIR"
    mv "$tmp/zig-aarch64-macos-$ZIG_VERSION" "$ZIG_DIR"
    rm -rf "$tmp"
fi

# The source at exactly the pinned commit.
SRC="target/zmx-src/$ZMX_COMMIT"
if [ ! -d "$SRC/.git" ]; then
    log "fetching zmx $ZMX_VERSION ($ZMX_COMMIT)"
    rm -rf "$SRC"
    mkdir -p "$SRC"
    git -C "$SRC" init -q
    git -C "$SRC" remote add origin "$ZMX_REPO"
    git -C "$SRC" fetch -q --depth 1 origin "$ZMX_COMMIT"
    git -C "$SRC" checkout -q FETCH_HEAD
fi
if [ "$(git -C "$SRC" rev-parse HEAD)" != "$ZMX_COMMIT" ]; then
    log "zmx source is not at $ZMX_COMMIT"
    exit 1
fi

git -C "$SRC" checkout -f FETCH_HEAD -q
git -C "$SRC" clean -fd -q
root="$(pwd)"
if [ -d "patches/zmx" ]; then
    for patch in patches/zmx/*.patch; do
        [ -f "$patch" ] || continue
        log "applying patch $(basename "$patch")"
        git -C "$SRC" apply "$root/$patch"
    done
fi

log "building zmx $ZMX_VERSION with Zig $ZIG_VERSION ($OPTIMIZE)"
prefix="$root/target/zmx-build/$KEY"
# Zig's global cache under target/ too, not in the user's home.
export ZIG_GLOBAL_CACHE_DIR="$root/target/zig-cache"
rm -rf "$prefix"
(cd "$SRC" && "$root/$ZIG_DIR/zig" build -Doptimize="$OPTIMIZE" --prefix "$prefix" >&2)

# zmx bundles ghostty-vt, fetched by Zig at the hash its build.zig.zon pins.
ghostty_hash=$(sed -n 's/.*\.hash = "\(ghostty-[^"]*\)".*/\1/p' "$SRC/build.zig.zon" | head -1)
# Zig 0.16 unpacks a project's packages into its own zig-pkg/.
ghostty_license="$SRC/zig-pkg/$ghostty_hash/LICENSE"
[ -s "$ghostty_license" ] || { log "no license for the bundled ghostty-vt at $ghostty_license"; exit 1; }

# The whole entry is assembled aside and renamed into place in one step: a
# run interrupted half way never leaves something the cache check accepts.
stage="target/zmx/.$KEY.$$"
rm -rf "$stage"
mkdir -p "$stage"
cp "$prefix/bin/zmx" "$stage/zmx"
chmod 0755 "$stage/zmx"
cp "$SRC/LICENSE" "$stage/LICENSE-zmx"
cp "$ghostty_license" "$stage/LICENSE-ghostty"
printf '{"name":"zmx","version":"%s","commit":"%s","zig":"%s","optimize":"%s","ghostty":"%s"}\n' \
    "$ZMX_VERSION" "$ZMX_COMMIT" "$ZIG_VERSION" "$OPTIMIZE" "$ghostty_hash" > "$stage/source.json"
complete "$stage" || { log "incomplete runtime entry"; exit 1; }
rm -rf "$OUT"
mv "$stage" "$OUT"
echo "$OUT/zmx"
