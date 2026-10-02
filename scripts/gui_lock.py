#!/usr/bin/env python3
"""Run a command holding an OS lock: `gui_lock.py [--file PATH] -- cmd...`.

The lock is flock(2) on a file, so the kernel releases it when this process
ends however it ends -- no pid files, no stale owners, no one deleting a
lock someone else holds. Prints how long it waited, so timings can tell
waiting from working.

Used for the test Mac's GUI session (the app's self-test, the e2e
scenarios: two at once steal each other's focus and hang) and, by
scripts/mac-remote.sh, for a checkout directory, so one run cannot replace
the sources or the built app another run is using.
"""
import fcntl
import os
import signal
import subprocess
import sys
import time

args = sys.argv[1:]
path = os.environ.get("TAKO_GUI_LOCK", "/tmp/tako-gui.lock")
if args[:1] == ["--file"]:
    path, args = args[1], args[2:]
if args[:1] == ["--"]:
    args = args[1:]
if not args:
    sys.exit("usage: gui_lock.py [--file PATH] -- command...")

timeout = float(os.environ.get("TAKO_LOCK_TIMEOUT", "3600"))
fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
started = time.monotonic()
while True:
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        break
    except BlockingIOError:
        if time.monotonic() - started > timeout:
            sys.exit(f"[lock] gave up on {path} after {timeout:.0f}s")
        time.sleep(0.5)
print(f"[lock] {os.path.basename(path)} waited {time.monotonic() - started:.0f}s", file=sys.stderr, flush=True)
# The command gets the locked descriptor too: flock belongs to the open file,
# so the lock lasts while any holder lives -- this wrapper or the command.
# Killing the wrapper alone cannot free the session under a running test.
child = subprocess.Popen(args, pass_fds=(fd,), start_new_session=True)


def forward(signum, _frame):
    # Cancelling the wrapper cancels the command, its whole process group.
    try:
        os.killpg(child.pid, signum)
    except ProcessLookupError:
        pass


for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    signal.signal(sig, forward)
code = child.wait()
# A command ended by a signal reports it the way a shell would.
sys.exit(128 - code if code < 0 else code)
