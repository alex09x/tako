#!/usr/bin/env bash
# Build TakoCore and launch it. Pass --test to run Rust + Swift tests first.
set -euo pipefail
cd "$(dirname "$0")"

TEST=0
for arg in "$@"; do
    [[ "$arg" == "--test" ]] && TEST=1
done

if [[ $TEST -eq 1 ]]; then
    echo "==> cargo test"
    cargo test
    # The Swift package compiles against generated bindings that live in
    # target/, so on a fresh clone they have to exist before `swift test`
    # will even parse the bridging header.
    ./scripts/bindings.sh
    echo "==> swift test"
    # AppKit pasteboard and WindowServer tests can deadlock when Swift Testing
    # runs them concurrently. Keep the full package suite deterministic.
    (cd swift && swift test --no-parallel)
    # TakoCoreUI compiles for iOS too, and nothing above notices when it
    # stops doing so: a macOS-only API in a shared file breaks the phone
    # build at link time and nowhere else. Two minutes here beats finding
    # out the next time someone builds for a device.
    echo "==> ios build"
    python3 scripts/build-iosapp.py
fi

echo "==> build"
python3 scripts/build-macapp.py

echo "==> relaunch"
pkill -x Tako 2>/dev/null || true
sleep 0.3
open target/macapp/Tako.app
echo "done"
