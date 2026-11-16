#!/usr/bin/env bash
# Watch Tako's status motions on the real screen: a separate Tako (its own
# bundle id, config and saved state) gets one tab, which goes through
# working, done, failed and waiting while ScreenCaptureKit records its pill
# and its sidebar row at the display's rate. Says, for each, whether it moved
# as the design has it (spinner speed and direction, pop, glint crossing the
# surface, shake) and whether it ever stalled. See scripts/e2e/motion/.
#
#   ./scripts/motion-check.sh             # build the motion app if missing, then check
#   ./scripts/motion-check.sh --build     # rebuild it from this checkout first
#   MOTION_FRAMES=dir ./scripts/motion-check.sh   # also save the last recording's crops
#   MOTION_SCENE=switch ./scripts/motion-check.sh # sidebar clicks between two tabs: any flicker
#
# Needs Screen Recording and Accessibility for the terminal running it, so it
# runs on a Mac with a logged-in screen -- not over ssh on the test Mac. The
# motion app comes to the front for about ten seconds; the app that was in
# front gets the focus back.
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE=com.tako-core.terminal.motion
# Off any external volume, where macOS would ask for access on every build.
DIR="$(python3 scripts/app_locations.py dir macapp-motion)"
APP="$DIR/Tako.app"
python3 scripts/app_locations.py check-app "$APP"
CTL="$APP/Contents/MacOS/takoctl"
TITLE="motion"

if [ "${1:-}" = "--build" ] || [ ! -d "$APP" ]; then
    TAKO_APP_DIR="$DIR" TAKO_BUNDLE_ID="$BUNDLE" python3 scripts/build-macapp.py >&2
fi

mkdir -p target
swiftc -O -o target/motion-check scripts/e2e/motion/*.swift
# The switch judge on made-up frames first: a judge that passes anything proves nothing.
[ "${MOTION_SCENE:-}" = switch ] && target/motion-check --selftest-switch
# Before any app quits or opens: this terminal may click and record, or nothing runs.
target/motion-check --preflight || { echo "motion-check: no Accessibility or Screen Recording here; nothing launched" >&2; exit 3; }

work="$(mktemp -d "${TMPDIR:-/tmp}/tako-motion.XXXXXX")"
printf 'remote-control = on\nwindow-save-state = never\nsession-persistence = false\n' > "$work/config"
quit() {
    osascript -e "tell application id \"$BUNDLE\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do pgrep -f "$APP/Contents/MacOS/Tako" >/dev/null || break; sleep 0.5; done
    # A question about closing the shells would hold it open; it is a throwaway instance.
    pkill -f "$APP/Contents/MacOS/Tako" 2>/dev/null || true
}

front="$(osascript -e 'tell application "System Events" to get bundle identifier of first process whose frontmost is true' 2>/dev/null || true)"
trap 'quit; rm -rf "$work"; [ -n "$front" ] && osascript -e "tell application id \"$front\" to activate" >/dev/null 2>&1' EXIT

quit
# Its own profile, from nothing: no windows, tabs or sessions from a run before.
python3 scripts/e2e/forget-saved-state.py "$BUNDLE" >/dev/null 2>&1 || true
state="$HOME/Library/Application Support/$BUNDLE"
for d in layout Sessions SessionRecords; do [ -e "$state/$d" ] && trash "$state/$d"; done
defaults write "$BUNDLE" tako.session_sidebar_is_showing -bool true
# In front: with nothing to restore, a Tako opened in the background opens no window.
# Its own session namespace too: in the owner's, it finds every live session
# of the Tako in use and puts up Session Recovery over the tabs it checks.
# Short: its sockets live in it, and a socket path is cut at 104 bytes.
sessions="$(mktemp -d /tmp/tkm.XXXXXX)"
mkdir -p "$work/agent-hooks"
# The config goes in TAKO_CONFIG_PATH: the app ignores --config-file, and
# with the owner's config (session-persistence on) every run left its two
# shells behind as session daemons. Any daemon of this bundle's runtime the
# run adds, by PID and start, fails it, and its evidence is kept.
. scripts/e2e/motion/daemons.sh
pattern="$state/runtime/"
daemons_before="$work/daemons-before.txt"
daemon_ids "$pattern" > "$daemons_before"
cleanup() {
    local status=$? evidence
    trap - EXIT
    quit
    evidence="$PWD/target/motion-leaks/$(date +%Y%m%d-%H%M%S)-$$"
    motion_finish "$status" "$daemons_before" "$pattern" "$evidence" || status=$?
    if [ -d "$evidence" ]; then echo "motion-check: kept its session namespace $sessions" >&2; else rm -rf "$sessions"; fi
    rm -rf "$work"
    [ -n "$front" ] && osascript -e "tell application id \"$front\" to activate" >/dev/null 2>&1
    exit "$status"
}
trap cleanup EXIT
open -n "$APP" --env TAKO_CONFIG_PATH="$work/config" --env TAKO_SESSIONS_HOME="$sessions" \
    --env TAKO_AGENT_HOOKS_HOME="$work/agent-hooks" --args --no-launch-notices
tree() { "$CTL" --bundle-id "$BUNDLE" --json tree 2>/dev/null; }
for _ in $(seq 1 40); do tree | grep -q '"panes"' && break; sleep 0.5; done
reported="$("$CTL" --bundle-id "$BUNDLE" config path 2>&1 || true)"
[ "$(realpath "$reported" 2>/dev/null)" = "$(realpath "$work/config")" ] \
    || { echo "motion-check: the motion app is not on its private config: $reported" >&2; exit 4; }

first="$(tree | python3 -c 'import json, sys; print(json.load(sys.stdin)["result"]["windows"][0]["tabs"][0]["panes"][0]["id"])')"
pane="$("$CTL" --bundle-id "$BUNDLE" tab-new --target "$first" --no-select | tail -1)"
"$CTL" --bundle-id "$BUNDLE" title --target "$pane" "$TITLE"
if [ "${MOTION_SCENE:-}" = switch ]; then
    # Two tabs that look different, so a frame of neither shows.
    "$CTL" --bundle-id "$BUNDLE" title --target "$first" alpha
    # A shell may not be up yet in a session namespace of its own.
    send() { for _ in $(seq 1 40); do "$CTL" --bundle-id "$BUNDLE" send --target "$1" "$2" 2>/dev/null && return; sleep 0.25; done; return 1; }
    # MOTION_SWITCH_ALPHA: what alpha runs, e.g. a full-screen program
    # (`less /etc/services`) that repaints when told its size again.
    send "$first" "${MOTION_SWITCH_ALPHA:-clear; ls -la /usr/bin | head -60}"
    send "$pane" 'clear; seq 1000 1060'
fi
# No pane of the run may live past it.
tree | python3 -c 'import json, sys
panes = [p for w in json.load(sys.stdin)["result"]["windows"] for t in w["tabs"] for p in t["panes"]]
held = [p["id"] for p in panes if p.get("persistentSession")]
sys.exit(f"motion-check: persistent sessions in the run: {held}" if held or not panes else 0)' || exit 4
sleep 1

MOTION_PANE="$pane" MOTION_OTHER_PANE="$first" python3 scripts/gui_lock.py -- target/motion-check "$BUNDLE" "$CTL" "$TITLE" ${MOTION_FRAMES:+"$MOTION_FRAMES"}
