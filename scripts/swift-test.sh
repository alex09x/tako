#!/bin/bash
set -e
cd "$(dirname "$0")/../swift"

# `swift test` alone fails to link: SPM auto-generates a per-package smoke
# bundle (TakoCoreUIPackageTests, named after the package, not any target)
# that links every product together, and it doesn't pick up TakoCoreUI's
# target-level linkerSettings the way a real consumer would. Passing the
# same flags globally via -Xlinker fixes it for every link step, synthetic
# bundle included.
#
# Several AppKit tests synchronously talk to NSPasteboard and WindowServer.
# Swift Testing's parallel scheduling can leave those calls mutually blocked,
# so the repository-wide entry point deliberately runs them serially.
#
# The generated header is passed to clang as a bare include path, not through
# a module map: TakoCoreUI already gets the tako_coreFFI module from the
# xcframework, and a second map for the same module is a redefinition error.
# The Tako target's bridging header only needs the header itself.
# The package links TakoCore.xcframework, which is build output rather than
# part of the repository. It is rebuilt when missing or older than the engine
# sources: a kept build directory (scripts/mac-remote.sh keeps one per job)
# would otherwise test the Swift code against an old engine, or fail to link
# a newly added FFI method. build-xcframework.sh also refreshes the macOS test
# library and the generated bindings.
stale() {
    [ ! -e "$1" ] || [ -n "$(find ../src ../Cargo.toml ../Cargo.lock -newer "$1" -print -quit)" ]
}
if stale ../TakoCore.xcframework; then ../scripts/build-xcframework.sh; fi
if stale ../target/macos/libtako_core.a; then ../scripts/build-macos-testlib.sh; fi

exec swift test --no-parallel -Xlinker -L../target/macos -Xlinker -ltako_core -Xcc -I../target/bindings "$@"
