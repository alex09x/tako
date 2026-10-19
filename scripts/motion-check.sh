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
#
# Needs Screen Recording and Accessibility for the terminal running it, so it
# runs on a Mac with a logged-in screen -- not over ssh on the test Mac. The
# motion app comes to the front for about ten seconds; the app that was in
# front gets the focus back.
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE=com.tako-core.terminal.motion
DIR=target/macapp-motion
APP="$DIR/Tako.app"
CTL="$APP/Contents/MacOS/takoctl"
TITLE="motion"

if [ "${1:-}" = "--build" ] || [ ! -d "$APP" ]; then
    TAKO_APP_DIR="$DIR" TAKO_BUNDLE_ID="$BUNDLE" python3 scripts/build-macapp.py >&2
fi

mkdir -p target
swiftc -O -o target/motion-check scripts/e2e/motion/*.swift

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
open -n "$APP" --args --config-file="$work/config" --no-launch-notices
tree() { "$CTL" --bundle-id "$BUNDLE" --json tree 2>/dev/null; }
for _ in $(seq 1 40); do tree | grep -q '"panes"' && break; sleep 0.5; done

first="$(tree | python3 -c 'import json, sys; print(json.load(sys.stdin)["result"]["windows"][0]["tabs"][0]["panes"][0]["id"])')"
pane="$("$CTL" --bundle-id "$BUNDLE" tab-new --target "$first" --no-select | tail -1)"
"$CTL" --bundle-id "$BUNDLE" title --target "$pane" "$TITLE"
sleep 1

MOTION_PANE="$pane" MOTION_OTHER_PANE="$first" python3 scripts/gui_lock.py -- target/motion-check "$BUNDLE" "$CTL" "$TITLE" ${MOTION_FRAMES:+"$MOTION_FRAMES"}
