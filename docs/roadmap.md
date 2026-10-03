# Tako roadmap

Tako helps you get back to terminal work after a relaunch, see what happened across several
sessions, and find the output you need. Underneath that sits ordinary daily reliability: shell,
SSH and full-screen programs, input, copy and paste, scrolling and tabs. TakoCore, the embeddable
engine, is a separate track for applications that need a terminal inside them.

This roadmap sets an order, not dates. Each step moves on when the previous one is reliable and
the people using it say it helps, not when a list of items is done.

## Before inviting outside users

- [x] **Install and update.** Status: shipped in 0.1.5. A clean install on another Mac opens without working around Gatekeeper,
and the in-app updater installs only builds that are signed and notarized. This gates inviting
outside testers; it does not hold up development, which runs on local builds.

- [x] **Daily reliability.** Status: shipped in 0.1.5. Shells, SSH and full-screen programs keep working; input methods and
non-Latin text, selection, copy and paste, scrolling and many tabs behave correctly. The first
round of outside feedback looks for anything that stops someone from working before it looks at
new features.

## Tako.app, in order

### [x] 1. Pick up where you left off

Status: shipped in 0.1.4; the layout after a crash, and every tab after a normal quit, since.

Each tab saves a snapshot of its screen and scrollback periodically and when the app quits. On
the next launch the tab shows the last snapshot, and the new shell starts below it. A snapshot
does not bring the old shell back: a new shell starts.

Windows, tabs and splits are kept in a journal written as they change, so they come back after a
crash as well as after a normal quit -- every tab, not only the selected one. A damaged journal is
ignored in favour of what macOS saved. The working directory comes back only
when the shell reported it (OSC 7 or shell integration); otherwise the new shell starts where Tako
starts any shell, by the `working-directory` setting.

Saved content is private data. It has a size limit, a setting that turns it off, and secure-input
sessions are never saved.

Done when:

- after a relaunch, every tab shows its last saved screen and scrollback;
- after a crash or a normal quit, the same windows, tabs and splits come back, once each;
- the new shell is never presented as the old process;
- the working directory comes back wherever the shell reported it;
- storage stays within the configured limit;
- with the setting off, nothing is written;
- secure-input sessions are excluded.

### [x] 2. See which tab needs attention

Status: shipped in 0.1.4.

When a long command finishes or fails, its tab shows it, and a notification is sent according to
the user's setting. The state comes only from shell integration (OSC 133) and exit status, never
from guessing at the text on screen.

Done when the marker matches the command's real outcome, the `never`, `unfocused` and `always`
modes behave predictably, and the signal can be turned off.

### [x] 3. Find output across sessions

Status: shipped in 0.1.4, including grouping by command.

One search covers the open tabs and any restored text the user allows it to read; choosing a
result opens that tab at that place. Where command boundaries are known, results can be grouped by
command, working directory, time and exit status. Over SSH, those boundaries exist only when the
remote host has shell integration; otherwise the search is plain text search over the screen and
scrollback.

Done when someone finds a given piece of output among several sessions and jumps to it without
going through tabs by hand, the search stays local, and it never invents details the shell did not
report.

### [ ] 4. Keep the same session across a relaunch

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

### [x] 5. Drive Tako from a script

A command-line tool, `takoctl`, controls the running app: list windows, tabs and panes with their
directories; open a tab or split with a directory and a command; type into a pane or send it a key;
read its screen back; focus, retitle or close it; post a notification tied to it. It also reaches
what only Tako knows: the last command a pane ran, with its exit status and output, and a search
across every open tab grouped by command. A script or a coding agent running in one pane can
address its own pane by id instead of whatever the user has selected.

It works only on this Mac, over a socket only the user can open, and nothing is exposed over the
network. Any process running as this user that can open the socket can read terminal contents and
send input. By default the tool accepts requests made from inside a Tako pane; that checks where a
request comes from and is not a security boundary. It can be opened to scripts started elsewhere,
and it can be turned off entirely.

Done when a script can build a layout, run a command in a new pane, wait for it to finish and read
its exit status and output, without touching the keyboard; when a request names a pane that is gone
or ambiguous it fails with a clear error instead of acting on another one; and when no other user on
the Mac can reach it.

Status: shipped in 0.1.5.

## TakoCore

A small track that runs alongside the app:

- [ ] minimal sample apps for macOS and iOS;
- [ ] a headless example over the C ABI;
- [ ] a page of limits and compatibility;
- [ ] a versioning policy for the API.

When an app feature needs something new from the engine, it is designed and tested in TakoCore
first, then used by the app.

Done when a developer outside the project builds a sample and embeds a terminal from the
instructions alone. Success is counted in real integrations and their feedback.

## Engine updates and new settings

Each release, before it is tagged, the engine's changes since the last release are read into one
list of new capabilities and settings. Each is weighed for:

- compatibility: config keys, the Swift and C API, the checkpoint format, restored sessions;
- cost: memory, speed, privacy, and what it takes to support (UI, tests, documentation);
- use: a user asked for it, or terminals people know behave that way.

A setting with a use -- a user asked for it, or terminals people know behave that way -- no UI
and an acceptable cost is exposed as a config key and documented. A feature with UI or
a changed default becomes an item here and goes through review, with targeted e2e tests. The rest
is left out, with the reason written down. A setting existing in the engine does not by itself
put it in Tako.

## Later, only if users need it

- [ ] **Reconnecting to sessions:** (Other machines, companion devices, new transports). The first version leaves out cloud sync, vendor-specific agent panels and inferring state from screen text. No telemetry is sent by default.
- [ ] **AI / Copilot integration:** Revisit only if there is direct demand. Must be opt-in with explicit control over context sharing. (A user's external agent can already drive Tako through `takoctl`).
- [ ] **tmux control mode:** Revisit only if users need Tako to host or control existing tmux workflows (large compatibility surface).
- [ ] **Native scrollbars:** Revisit only if users specifically need a clearer position indicator to navigate history (scrollback search is already present).
- [ ] **Font ligatures:** Consider adding as a setting only if explicitly requested.
