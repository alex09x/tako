# Tako roadmap

Tako helps you get back to terminal work after a relaunch, see what happened across several
sessions, and find the output you need. Underneath that sits ordinary daily reliability: shell,
SSH and full-screen programs, input, copy and paste, scrolling and tabs. TakoCore, the embeddable
engine, is a separate track for applications that need a terminal inside them.

This roadmap sets an order, not dates. Each step moves on when the previous one is reliable and
the people using it say it helps, not when a list of items is done.

## Before inviting outside users

**Install and update.** A clean install on another Mac opens without working around Gatekeeper,
and the in-app updater installs only builds that are signed and notarized. This gates inviting
outside testers; it does not hold up development, which runs on local builds.

**Daily reliability.** Shells, SSH and full-screen programs keep working; input methods and
non-Latin text, selection, copy and paste, scrolling and many tabs behave correctly. The first
round of outside feedback looks for anything that stops someone from working before it looks at
new features.

## Tako.app, in order

### 1. Pick up where you left off

Status: shipped in 0.1.4.

Each tab saves a snapshot of its screen and scrollback periodically and when the app quits. On
the next launch the tab shows the last snapshot, followed by a separator with the time it was
taken, so new output is visibly apart from restored text. A snapshot does not bring the old shell
back: a new shell starts, and the tab makes that clear. The working directory comes back only
when the shell reported it (OSC 7 or shell integration); otherwise the new shell starts where Tako
starts any shell, by the `working-directory` setting.

Saved content is private data. It has a size limit, a setting that turns it off, and secure-input
sessions are never saved.

Done when:

- after a relaunch, every tab shows its last saved screen and scrollback with the snapshot time;
- the new shell is never presented as the old process;
- the working directory comes back wherever the shell reported it;
- storage stays within the configured limit;
- with the setting off, nothing is written;
- secure-input sessions are excluded.

### 2. See which tab needs attention

Status: shipped in 0.1.4.

When a long command finishes or fails, its tab shows it, and a notification is sent according to
the user's setting. The state comes only from shell integration (OSC 133) and exit status, never
from guessing at the text on screen.

Done when the marker matches the command's real outcome, the `never`, `unfocused` and `always`
modes behave predictably, and the signal can be turned off.

### 3. Find output across sessions

Status: shipped in 0.1.4, including grouping by command.

One search covers the open tabs and any restored text the user allows it to read; choosing a
result opens that tab at that place. Where command boundaries are known, results can be grouped by
command, working directory, time and exit status. Over SSH, those boundaries exist only when the
remote host has shell integration; otherwise the search is plain text search over the screen and
scrollback.

Done when someone finds a given piece of output among several sessions and jumps to it without
going through tabs by hand, the search stays local, and it never invents details the shell did not
report.

### 4. Keep the same session across a relaunch

Status: in 0.1.4 as an experimental setting (`session-persistence`), off by default; behaviour across sleep and wake is not yet verified.

Quitting Tako detaches its tabs instead of ending them: the shell and the programs running in it
stay alive on this Mac. On the next launch Tako restores the layout and reattaches each tab to its
session by a stable id, passing input, terminal size and what is on screen between them. Closing a
tab ends its process, explicitly. This works locally and needs no network service.

If the local session host is not running, or the Mac restarted, the tab shows its saved snapshot
(step 1) and starts a new shell, without presenting it as the old process. Surviving a restart of
the Mac itself is not part of this.

Done when:

- after quitting normally and relaunching, every tab has the same process and interactive state;
- full-screen programs and SSH sessions take input and respond correctly to resizing;
- no session is duplicated;
- the user has a clear action that ends a live session;
- when the host is gone, the fallback above is what happens.

## TakoCore

A small track that runs alongside the app:

- minimal sample apps for macOS and iOS;
- a headless example over the C ABI;
- a page of limits and compatibility;
- a versioning policy for the API.

When an app feature needs something new from the engine, it is designed and tested in TakoCore
first, then used by the app.

Done when a developer outside the project builds a sample and embeds a terminal from the
instructions alone. Success is counted in real integrations and their feedback.

## Later, only if users need it

Reconnecting to sessions on other machines, companion devices and new transports. The first version also leaves out cloud sync, vendor-specific agent
panels and inferring state from screen text. No telemetry is sent by default.
