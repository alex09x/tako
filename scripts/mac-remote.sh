#!/bin/bash
# Run a command on the remote test Mac against this working tree.
#
#   export TAKO_MAC=user@test-mac.local
#   scripts/mac-remote.sh ./scripts/swift-test.sh
#   scripts/mac-remote.sh 'python3 scripts/swift-coverage-gate.py'
#
# The tree is copied as git sees it -- tracked files as they are on disk,
# plus untracked files that are not ignored -- so uncommitted work is tested
# and local build output is not shipped. The remote copy's target/,
# swift/.build/ and TakoCore.xcframework (build output, not in git) are kept
# between runs so builds stay incremental. The Mac
# has a logged-in GUI session, which XCUITest and simulators need.
set -euo pipefail

HOST="${TAKO_MAC:?set TAKO_MAC to user@host of the test Mac}"
DIR="${TAKO_MAC_DIR:-ci/tako}"
XCODE="${TAKO_MAC_XCODE:-/Applications/Xcode-26.3.app/Contents/Developer}"

[ $# -gt 0 ] || { echo "usage: $0 <command...>" >&2; exit 2; }
cd "$(dirname "$0")/.."

# The remote login shell may not be bash, so every remote script goes
# through `bash -s` on stdin rather than through ssh's command string.
ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" bash -s <<EOF
set -e
mkdir -p "$DIR" && cd "$DIR"
find . -mindepth 1 -maxdepth 1 ! -name target ! -name swift ! -name TakoCore.xcframework -exec rm -rf {} +
if [ -d swift ]; then find swift -mindepth 1 -maxdepth 1 ! -name .build -exec rm -rf {} +; fi
EOF

git ls-files -z --cached --others --exclude-standard \
    | perl -0ne 'chomp; print "$_\0" if -e $_ || -l $_' \
    | tar --null -T - -cf - \
    | ssh -o BatchMode=yes "$HOST" "cd $DIR && tar -xf -"

{
    echo "set -e"
    echo "cd \"$DIR\""
    echo "export DEVELOPER_DIR=\"$XCODE\""
    echo 'export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"'
    echo "$*"
} | ssh -o BatchMode=yes "$HOST" bash -s
