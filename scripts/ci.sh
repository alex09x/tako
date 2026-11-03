#!/bin/bash
# tako — Terminal emulator CI stages
# Copyright (c) 2026 Alexander Panasenko
# Contact: alex@prod.codes
# Author: https://prod.codes/about/
# Project: https://github.com/alex09x/tako
# SPDX-License-Identifier: MIT
#
# The full LAN quality gates run through scripts/mac-remote.sh by default.
# Hosted CI uses explicit local execution and the test-only stages below.
#
#   export TAKO_MAC=user@test-mac.local
#   scripts/ci.sh                 # every stage
#   scripts/ci.sh rust swift      # only those stages
#   scripts/ci.sh --local swift-tests
#
# Test-only stages (no coverage or clippy gate): engine-tests, cli-tests,
# python-tests, swift-tests, macapp-tests, ios-unit-tests, macos-ui-tests,
# macapp-e2e-tests, persist-e2e-tests, ios-surface-tests, ios-simtest. They retain full
# logs under target/ci-logs, reject empty runs, and show hardware skips.
# They do not replace the full LAN gates or produce release artifacts.
#
# For a change, run only what it touches with scripts/check.sh (named Rust
# tests, Swift test filters, e2e scenarios, no coverage); this script is the
# full run, kept for releases and wide changes.
#
# Stages, in order:
#   rust     clippy over every target, then the engine suite with pty and ssh
#            under the per-file line-coverage gate (every src/ file >= 80%)
#   cli      clippy and tests for takoctl (CLI/MCP/hooks)
#   swift    build the xcframework, then the Swift package under its gate
#            (TakoCoreUI, TakoKit, the shim and the app directories covered
#            so far, every file >= 80%)
#   apps     build Tako.app, run its self-test and drive it with real input
#            (scripts/e2e-macapp.sh), the terminal view's tests
#            on the iOS simulator, the iOS scenarios and walkthrough, and the
#            iOS app under its gate
#   persist  run the complete session persistence suite (scripts/e2e-persist.sh)
#   uitest   run the XCUITest accessibility and UI test suite (scripts/uitest.sh)
set -euo pipefail
cd "$(dirname "$0")/.."

run_local=0
if [ "${1:-}" = --local ]; then
    run_local=1
    shift
fi
stages=("$@")
[ ${#stages[@]} -gt 0 ] || stages=(rust cli swift apps persist uitest)

ci_logged() {
    local name="$1"
    shift
    mkdir -p target/ci-logs
    "$@" 2>&1 | tee "target/ci-logs/$name.log"
}

ci_require() {
    if ! grep -Eq -- "$2" "target/ci-logs/$1.log"; then
        echo "FAIL: $1 lacks completion evidence: $2" >&2
        exit 1
    fi
}

ci_simulator_name() {
    xcrun simctl list devices available --json | python3 -c '
import json, sys
for runtime, devices in sorted(json.load(sys.stdin)["devices"].items(), reverse=True):
    if ".iOS-" in runtime:
        for device in devices:
            if device.get("isAvailable") and device["name"].startswith("iPhone"):
                print(device["name"])
                sys.exit(0)
sys.exit("FAIL: no available iPhone simulator")
'
}

ci_test_stage() {
    local stage="$1" result_dir destination device_id mode
    # Each standard hosted arm64 VM has 7 GB. Bound compiler/test fan-out;
    # swiftc is called directly by the native app builder, outside SwiftPM.
    export CARGO_BUILD_JOBS=2 RUST_TEST_THREADS=2
    export TAKO_CODESIGN_IDENTITY=- PROD_CODE_LOCAL=1
    mkdir -p target/ci-bin
    cat > target/ci-bin/swiftc <<'SH'
#!/bin/bash
exec /usr/bin/xcrun swiftc -j 2 "$@"
SH
    chmod +x target/ci-bin/swiftc
    export PATH="$PWD/target/ci-bin:$PATH"
    echo "== $stage (test-only; full LAN quality gates are separate)"
    case "$stage" in
        engine-tests)
            ci_logged "$stage" cargo test --locked --no-fail-fast --features pty,ssh -- --test-threads=2
            ci_require "$stage" 'test result: ok\. [1-9][0-9]* passed'
            ;;
        cli-tests)
            ci_logged "$stage" cargo test --locked --no-fail-fast --manifest-path takoctl/Cargo.toml -- --test-threads=2
            ci_require "$stage" 'test result: ok\. [1-9][0-9]* passed'
            ;;
        python-tests)
            ci_logged "$stage" python3 -m unittest discover -s scripts -p 'test_*.py' -v
            ci_require "$stage" '^Ran [1-9][0-9]* tests? in '
            ci_require "$stage" '^OK'
            ;;
        swift-tests)
            # Explicitly refresh the host slice and bindings before SwiftPM
            # plans the graph. No iOS cross-compiles for this macOS suite.
            ./scripts/build-xcframework.sh --macos-only
            ci_logged "$stage" ./scripts/swift-test.sh --jobs 2 --no-parallel \
                --enable-xctest --enable-swift-testing
            ci_require "$stage" "Test Case .* passed"
            ci_require "$stage" 'Test run with [1-9][0-9]* tests?( in [0-9]+ suites?)? passed after'
            # The existing gate tracks the root XCTest and Swift Testing
            # summaries: a process that stops its run loop can exit zero.
            python3 - <<'PY'
import pathlib, runpy, sys
tracker = runpy.run_path("scripts/swift-coverage-gate.py")["TestCompletionTracker"]()
for line in pathlib.Path("target/ci-logs/swift-tests.log").read_text().splitlines():
    tracker.feed_line(line)
if not (tracker.finished and tracker.xctest_completed and tracker.swift_testing_completed):
    sys.exit("FAIL: both full Swift test runners must finish")
PY
            ;;
        macapp-tests)
            # Keep the default bundled session runtime; build-zmx.sh fetches
            # its pinned Zig/source and checks the toolchain checksum.
            export TAKO_WITH_ZMX=1
            export TAKO_BUNDLE_ID=com.tako-core.terminal.ci
            export TAKO_APP_DIR=target/macapp-ci
            ci_logged macapp-build python3 scripts/build-macapp.py
            ci_logged "$stage" env APP=target/macapp-ci/Tako.app ./scripts/selftest-macapp.sh
            ci_require "$stage" '^macapp self-test: ok$'
            ;;
        macapp-e2e-tests)
            export TAKO_WITH_ZMX=1 TAKO_BUNDLE_ID=com.tako-core.terminal.e2e
            export TAKO_APP_DIR=target/macapp-e2e
            ci_logged macapp-e2e-build python3 scripts/build-macapp.py
            ci_logged "$stage" ./scripts/e2e-macapp.sh
            ci_require "$stage" '^ok '
            ci_require "$stage" '^tako e2e: ok$'
            ;;
        persist-e2e-tests)
            # All isolated persistence scenarios in the driver registry,
            # including the newer recovery, grouping and appearance cases.
            ci_logged "$stage" ./scripts/e2e-persist.sh \
                persist-live persist-gone persist-close persist-cancel \
                persist-close-asks persist-close-quit persist-second-owner persist-reflow \
                persist-workspaces persist-missing-layout persist-damaged-record \
                persist-damaged-placeholder persist-lost-workspaces persist-workspace-archive \
                persist-crash persist-screen-archive persist-layout-archive persist-legacy-upgrade \
                persist-name-collision persist-agent-conversation persist-sidebar-workspace-move \
                persist-partial-group persist-empty-workspace-group persist-task-workspace-group \
                persist-intentional-windows persist-assign-selected persist-inactive-recovery-group \
                persist-cross-window-workspace-move persist-legacy-window-choice \
                persist-legacy-workspace-choice persist-sidebar-long-list persist-scoped-appearance
            ci_require "$stage" '^ok +persist-'
            ci_require "$stage" '^tako e2e: ok$'
            ;;
        ios-surface-tests)
            ./scripts/bindings.sh
            ci_logged "$stage" ./scripts/test-ios-surface.sh
            ci_require "$stage" 'Completed [1-9][0-9]* tests with 0 failures'
            ;;
        ios-simtest)
            ./scripts/bindings.sh
            export TAKO_SIM_DEVICE="${TAKO_SIM_DEVICE:-$(ci_simulator_name)}"
            ci_logged "$stage" python3 scripts/simtest.py
            ci_require "$stage" '\[simtest\] [1-9][0-9]*/[1-9][0-9]* scenarios passed'
            ci_logged ios-coverage python3 scripts/ios-coverage-gate.py
            ci_require ios-coverage '^ok +[0-9]'
            ;;
        ios-unit-tests)
            # This Xcode project links the simulator archive directly. Its
            # pre-build phase builds that archive; bindings must exist when
            # Xcode plans the hosted test target's bridging header.
            ./scripts/bindings.sh
            xcodegen -s ios/project.yml -p ios --quiet
            if [ -n "${TAKO_SIM_DEVICE:-}" ]; then
                destination="platform=iOS Simulator,name=$TAKO_SIM_DEVICE"
            else
                # Hosted image device names change; select an available iPhone
                # by UUID, without relying on a developer's personal simulator.
                device_id=$(xcrun simctl list devices available --json | python3 -c '
import json, sys
devices = json.load(sys.stdin)["devices"]
for runtime, phones in sorted(devices.items(), reverse=True):
    if ".iOS-" in runtime:
        for phone in phones:
            if phone.get("isAvailable") and phone["name"].startswith("iPhone"):
                print(phone["udid"])
                sys.exit(0)
sys.exit("FAIL: no available iPhone simulator")
')
                destination="platform=iOS Simulator,id=$device_id"
            fi
            echo "== iOS unit destination: $destination"
            result_dir=$(mktemp -d target/ci-ios.XXXXXX)
            ci_logged "$stage" xcodebuild test -project ios/TakoCore.xcodeproj \
                -scheme TakoCore -configuration Debug -jobs 2 \
                -destination "$destination" \
                -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
                -derivedDataPath target/ci-ios-derived -resultBundlePath "$result_dir/tests.xcresult" \
                -only-testing:TakoCoreUnitTests CODE_SIGNING_ALLOWED=NO DEVELOPMENT_TEAM=
            ci_require "$stage" 'Test Case .* passed'
            ci_require "$stage" '\*\* TEST SUCCEEDED \*\*'
            ;;
        macos-ui-tests)
            export TAKO_WITH_ZMX=1
            export TAKO_BUNDLE_ID=com.tako-core.terminal.uitest
            export TAKO_APP_DIR=target/macapp-uitest
            # Xcode enables Automation Mode when tests start. Disabled at
            # rest is valid if the host permits activation without a prompt.
            # The -Run scheme enables
            # discovery of the inherited UI suites as well as our journeys.
            mode=$(/usr/bin/automationmodetool 2>&1)
            printf '%s\n' "$mode"
            if [[ "$mode" == *"Automation Mode is disabled"* && "$mode" != *"DOES NOT REQUIRE user authentication"* ]]; then
                echo 'FAIL: enabling Automation Mode requires authentication; no XCUITest executed' >&2
                exit 3
            fi
            result_dir=$(mktemp -d target/ci-ui.XXXXXX)
            ci_logged "$stage" python3 scripts/gui_lock.py -- xcodebuild test \
                -project macos_uitests/TakoUITests.xcodeproj -scheme TakoUITests-Run \
                -destination platform=macOS -jobs 2 -parallel-testing-enabled NO \
                -resultBundlePath "$result_dir/tests.xcresult"
            if grep -q 'placeholder host app was kept' "target/ci-logs/$stage.log"; then
                echo 'FAIL: Xcode kept the placeholder host app' >&2
                exit 1
            fi
            ci_require "$stage" '^Test Case .* passed'
            ci_require "$stage" '\*\* TEST SUCCEEDED \*\*'
            ;;
    esac
}

script=$'set -euo pipefail\n'
script+="$(declare -f ci_logged ci_require ci_simulator_name ci_test_stage)"
for stage in "${stages[@]}"; do
    case "$stage" in
        engine-tests|cli-tests|python-tests|swift-tests|macapp-tests|ios-unit-tests|macos-ui-tests|macapp-e2e-tests|persist-e2e-tests|ios-surface-tests|ios-simtest)
            script+=$'\n'
            script+="ci_test_stage $stage" ;;
        rust) script+="
echo '== rust'
cargo clippy --all-targets --features pty,ssh -- -D warnings
python3 scripts/coverage-gate.py --features pty,ssh" ;;
        cli) script+="
echo '== cli'
cargo clippy --manifest-path takoctl/Cargo.toml -- -D warnings
cargo test --manifest-path takoctl/Cargo.toml" ;;
        swift) script+="
echo '== swift'
./scripts/build-xcframework.sh
python3 scripts/swift-coverage-gate.py --module TakoCoreUI --module TakoKit --module TakoApp/_TakoShim \\
    --module TakoApp/Helpers --module TakoApp/Features/QuickTerminal \\
    --module 'TakoApp/Features/Secure Input' --module 'TakoApp/Features/Global Keybinds' \\
    --module TakoApp/Features/Services --module TakoApp/Features/Splits \\
    --module TakoApp/Features/About --module TakoApp/Features/Settings \\
    --module TakoApp/Features/ClipboardConfirmation --module 'TakoApp/Features/Custom App Icon' \\
    --module 'TakoApp/Features/Command Palette' \\
    --module TakoApp/App --module TakoApp/Features/Terminal" ;;
        apps) script+="
echo '== apps'
TAKO_BUNDLE_ID=com.tako-core.terminal.e2e TAKO_APP_DIR=target/macapp-e2e python3 scripts/build-macapp.py
APP=target/macapp-e2e/Tako.app ./scripts/selftest-macapp.sh
APP=target/macapp-e2e/Tako.app ./scripts/e2e-macapp.sh
./scripts/test-ios-surface.sh
python3 scripts/simtest.py
python3 scripts/ios-coverage-gate.py" ;;
        persist) script+="
echo '== persist'
./scripts/e2e-persist.sh" ;;
        uitest) script+="
echo '== uitest'
./scripts/uitest.sh --local" ;;
        *) echo "unknown stage: $stage (see scripts/ci.sh for full LAN and hosted stages)" >&2; exit 2 ;;
    esac
done

if [ "$run_local" -eq 1 ]; then
    export PROD_CODE_LOCAL=1
    exec /bin/bash -c "$script"
fi
exec scripts/mac-remote.sh "$script"
