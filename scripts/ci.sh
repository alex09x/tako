#!/bin/bash
# The whole check, run on the test Mac through scripts/mac-remote.sh. There is
# no hosted CI: this is it.
#
#   export TAKO_MAC=user@test-mac.local
#   scripts/ci.sh                 # every stage
#   scripts/ci.sh rust swift      # only those stages
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

stages=("$@")
[ ${#stages[@]} -gt 0 ] || stages=(rust cli swift apps persist uitest)

script="set -e"
for stage in "${stages[@]}"; do
    case "$stage" in
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
./scripts/uitest.sh" ;;
        *) echo "unknown stage: $stage (rust, cli, swift, apps, persist, uitest)" >&2; exit 2 ;;
    esac
done

exec scripts/mac-remote.sh "$script"
