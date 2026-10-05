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
#
# A run holds a lock on its remote directory from before the old copy is
# removed until the command ends: two runs against the same directory would
# otherwise replace each other's sources or built app while the other is
# using them. A run against another directory (TAKO_MAC_DIR) is not held up.
set -euo pipefail

HOST="${TAKO_MAC:?set TAKO_MAC to user@host of the test Mac}"
DIR="${TAKO_MAC_DIR:-ci/tako}"
XCODE="${TAKO_MAC_XCODE:-/Applications/Xcode-26.3.app/Contents/Developer}"

[ $# -gt 0 ] || { echo "usage: $0 <command...>" >&2; exit 2; }
cd "$(dirname "$0")/.."

RUN="/tmp/tako-remote-$$-$RANDOM"
# The command travels base64-encoded: nothing in it is expanded on this side.
CMD_B64=$(printf '%s\n' "set -e" "cd \"$DIR\"" "export DEVELOPER_DIR=\"$XCODE\"" \
    'export PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"' "$*" | base64)

# The remote login shell may not be bash, so scripts go through `bash -s`
# on stdin rather than through ssh's command string. The first connection
# only writes this run's scripts to files of its own; the second holds the
# lock, refreshes the copy from the tar on its stdin and runs the command.
ssh -o BatchMode=yes -o ConnectTimeout=10 "$HOST" bash -s <<OUTER
set -e
echo "$CMD_B64" | base64 -D > "$RUN.cmd"
cat > "$RUN.sync" <<'SYNC'
set -e
mkdir -p "$DIR" && cd "$DIR"
find . -mindepth 1 -maxdepth 1 ! -name target ! -name swift ! -name TakoCore.xcframework ! -name TakoCore.xcframework.macos-only ! -name TakoCore.xcframework.inputs -exec rm -rf {} +
if [ -d swift ]; then find swift -mindepth 1 -maxdepth 1 ! -name .build -exec rm -rf {} +; fi
tar -xf -
cd - >/dev/null
exec bash "$RUN.cmd"
SYNC
cat > "$RUN.lock.py" <<'LOCK'
import fcntl, os, subprocess, sys, time
fd = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)
started = time.monotonic()
fcntl.flock(fd, fcntl.LOCK_EX)
print("[lock] checkout waited %.0fs" % (time.monotonic() - started), file=sys.stderr, flush=True)
# The command holds the locked descriptor too (flock belongs to the open
# file), so killing this wrapper cannot let another run replace the copy
# under a command that is still running; cancelling it cancels the command.
import signal
child = subprocess.Popen(["bash", sys.argv[2]], pass_fds=(fd,), start_new_session=True)
def forward(signum, _frame):
    try:
        os.killpg(child.pid, signum)
    except ProcessLookupError:
        pass
for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    signal.signal(sig, forward)
timeout_env = os.environ.get("TAKO_REMOTE_TIMEOUT", "180")
timeout_sec = float(timeout_env) if timeout_env else 180.0
try:
    code = child.wait(timeout=timeout_sec)
except subprocess.TimeoutExpired:
    print(f"\n[remote-timeout] Command timed out after {timeout_sec:.0f}s. Terminating process group {child.pid}...", file=sys.stderr, flush=True)
    try:
        os.killpg(child.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    code = 124
code = 128 - code if code < 0 else code
for suffix in (".cmd", ".sync", ".lock.py"):
    try:
        os.remove(sys.argv[3] + suffix)
    except OSError:
        pass
sys.exit(code)
LOCK
OUTER

git ls-files -z --cached --others --exclude-standard \
    | perl -0ne 'chomp; print "$_\0" if -e $_ || -l $_' \
    | tar --null -T - -cf - \
    | ssh -o BatchMode=yes "$HOST" "mkdir -p $(dirname "$DIR") && python3 $RUN.lock.py $DIR.lock $RUN.sync $RUN"
