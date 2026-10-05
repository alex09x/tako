# Tako roadmap

Tako helps you get back to terminal work after a relaunch, see what happened across several
sessions, and find the output you need. Underneath that sits ordinary daily reliability: shell,
SSH and full-screen programs, input, copy and paste, scrolling and tabs. TakoCore, the embeddable
engine, is a separate track for applications that need a terminal inside them.

The direction from here: Tako becomes the native macOS terminal for agentic development -- the
place where a developer runs many coding agents, scripts and shells side by side, always knows
which one needs them, and stays in control of what each one may do. It stays an ordinary
terminal first: everything here works with any program that runs in a terminal, and nothing
requires an account, a cloud service or a particular agent vendor.

This roadmap sets an order, not dates. Each step moves on when the previous one is reliable and
the people using it say it helps, not when a list of items is done.

## How to read this roadmap

- `[x]` shipped, `[ ]` not shipped yet. A **Status** line says how far an item has got
  (experimental, in progress, candidate).
- Every new item has an ID (`A1`, `B4`, ...) so issues, branches and commits can name it.
  The numbered steps 1-8 keep their original numbers.
- Every actionable item ends with **Done when**: the observable behaviour that closes it. An item is not
  done because code exists; it is done when that behaviour holds and has tests.
- Milestones group items into releases. Versions are indicative; the order is what matters.
- Items marked *evaluate* (D5, F4, F7) are open questions, not commitments: they close with a written
  decision record based on verified evidence before any implementation is scheduled.

## Principles

These hold for every item below. A feature that needs to break one of them is redesigned or
left out.

1. **Signals, not guesses.** State comes from what programs and shells report -- shell
   integration (OSC 133, OSC 7), exit status, progress and notification sequences, explicit
   `takoctl` calls and agent hooks. Tako never infers state by reading the text on the screen.
   When nothing reported a state, Tako says "unknown" rather than inventing one.
2. **Local and private by default.** No telemetry, no account, no network service. The control
   socket is reachable only by the user on this Mac. Saved content is private data with size
   limits and an off switch; secure-input sessions are never saved, searched or read back.
3. **Provider-neutral.** Tako works with any agent that runs in a terminal. Integrations with
   particular agent tools are optional adapters shipped as data (hook configs, skill files),
   never patches to someone else's binary and never vendor panels in the core UI.
4. **The human stays in control.** Automation can only do what the user allowed. Scripted and
   agent input is targeted to carry visible attribution badges (landing in C7 and G2; currently
   `takoctl` writes directly to the target PTY without an actor mark); nothing escalates on its
   own; anything that would run a command on the user's behalf asks first or is limited to commands
   the user approved.
5. **Native, fast and calm under load.** AppKit and Metal, no web runtime for the terminal
   itself. Twenty panes streaming agent output must not make typing in the twenty-first slower.
6. **Engine first.** When an app feature needs something new from the engine, it is designed and
   tested in TakoCore first, then used by the app.
7. **Small, honest surface.** A setting existing in the engine does not by itself put it in
   Tako; a feature with UI or a changed default goes through review with targeted e2e tests.

## Where Tako stands (0.1.7)

What exists today, so that the plan below starts from facts:

- **Engine (TakoCore, Rust):** VT parser and screen model with parity tests against an upstream
  suite; kitty keyboard protocol, modifyOtherKeys, bracketed paste, mouse modes, synchronized
  output (2026), grapheme clustering (2027), color-scheme reports (2031); kitty graphics
  protocol (with known gaps); OSC 4/10/11/12/104/110-112 colours, OSC 7 working directory,
  OSC 8 hyperlinks, OSC 9 and OSC 777 notifications, OSC 9;4 progress, OSC 52 clipboard (a
  read request is handed to the host's policy), OSC 133 shell integration with command records, versioned
  checkpoints; a C ABI and an SSH transport for iOS; fuzz targets and per-file coverage gates.
- **Tako.app (macOS):** windows, tabs, splits, quick terminal, command palette, find in all tabs
  grouped by command, command-finished marks and notifications, the per-tab status indicator
  (idle, running, succeeded, failed, attention, reconnecting, disconnected), progress in the dock
  and tab title, layout journal and screen snapshots across relaunch and crash, experimental
  session persistence, secure input, native scrollbars, ligatures, signed and notarized updates.
- **Shell integration:** zsh, bash, fish, nushell and elvish.
- **`takoctl`:** `version`, `tree`, `send`, `type`, `key`, `text`, `tab-new`, `split`, `focus`,
  `title`, `close`, `notify`, `find`, `dialog`, `last`, `wait`, `run`, addressed by pane id,
  over a user-only local socket.
- **iOS app:** SSH sessions over the engine's own transport, host-key prompts, key row.

## Milestones at a glance

| Milestone | Theme | Items |
|---|---|---|
| M0 (0.1.x, shipped) | Daily reliability, relaunch, attention marks, cross-session search, scripting | Before inviting outside users, steps 1, 2, 3, 5 |
| M1 (0.2) | Finish the foundations | Steps 4, 6, 7; A1-A7; E1; G3, G4, G6 |
| M2 (0.3) | Attention layer: know what every session needs | B1-B10; E2, E3, E8; G1, G2, G5 |
| M3 (0.4) | Agent workspaces: many agents, one calm window | C1-C10; E4, E9 |
| M4 (0.5) | Artifacts, preview and review | D1-D5; E5, E6, E7, E10 |
| M5 (0.6) | Sessions, remote and devices | F1-F7 |
| M6 (0.7) | Customization, ecosystem, accessibility | H1-H8 |
| 1.0 | Stable surfaces and support promises | See "What 1.0 means" |

Trust and safety (track G) is not a milestone of its own: each G item is a gate for the milestone
that first needs it.

---

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
The work to make it the default is item A1.

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

### [x] 6. Prompt navigation and command selection

Status: shipped in [#12](https://github.com/alex09x/tako/pull/12). Part of M1.

Jump between commands and select their exact output using shell integration boundaries (OSC 133):
- `Cmd+Up` and `Cmd+Down` to navigate directly between prompt markers without scrolling manually.
- `Cmd+Shift+A` to select the entire output of the current or previous command cleanly bounded by prompt marks.

Done when:
- prompt navigation relies strictly on verified OSC 133 marks without guessing or screen scraping;
- command output selection never bleeds into adjacent commands, timestamps, or prompts;
- over SSH or in shells without integration, the keys fall back cleanly to ordinary scrollback page jumps;
- keyboard selection allows instant copying with `Cmd+C` without requiring mouse interaction.

### [x] 7. Safe paste guard

Status: shipped in [#10](https://github.com/alex09x/tako/pull/10). Part of M1.

Starting point, verified in the code: the app already has a confirmation sheet for pastes and
clipboard requests, and the engine already exposes an "unsafe paste" check, but nothing connects
them yet -- no code path raises the paste confirmation today.

Protects against accidental execution of pasted multi-line snippets:
- Warns with a confirmation sheet when the clipboard contains multiple lines or any newline separator at a shell prompt.
- Active only when shell integration reports that the session is at a shell prompt, avoiding false positives inside full-screen terminal applications (editors, pagers, TUIs).
- Purely structural: no fragile keyword or regex heuristics (such as matching `sudo` or `rm`).

Done when:
- text containing any newline separator (or multiple lines) pasted at a shell prompt displays a confirmation sheet containing a scrollable preview of the text;
- pressing Enter confirms the paste; pressing Escape or clicking Cancel dismisses it without emitting characters to the PTY;
- confirmation strictly guards pastes with newlines at shell prompts regardless of bracketed paste mode, unless a verified shell contract explicitly handles multi-line input;
- can be toggled on or off via a configuration key (`safe-paste = true|false`).

### [ ] 8. Agent-first terminal platform

Status: primary focus track alongside core reliability. Broken down into tracks B, C and D below.

Tako aims to be the native macOS terminal for agentic development workflows (coding agents, subagents, headless automation).
While `takoctl` already provides full headless socket control (`tree`, `send`, `type`, `key`, `text`, `last`, `wait`, `run`, `split`), an agent-first terminal needs seamless human-agent collaboration in the UI:

- **In-terminal artifact and document overlays** -- item D1.
- **Session and agent status badges** -- items B1, B4 and B5.
- **Interactive agent prompt (`takoctl ask`)** -- item B10.
- **Bundled agent skills and protocol** -- items B8 and C10.
- **Terminal event stream (`takoctl events`)** -- item B9.

Done when:
- an agent can create a split, run a test suite, update its status badge to `thinking`, and open a visual HTML coverage overlay when finished;
- a developer working with multiple agents can see which ones require input directly from the tab bar;
- bundled agent skills allow agents to drive Tako without manual user setup or shell scraping.

---

## Track A -- Finish the foundations (M1)

The base every later track stands on. Nothing in tracks B-D should ship on top of a session
model, paste path or engine gap that is known to be wrong.

### [ ] A1. Session persistence becomes the default

Status: experimental since 0.1.4 (step 4).

- Verify and fix behaviour across sleep and wake, display changes, low-memory pressure and an
  app update while sessions are live (the app and the session host must agree on a versioned
  protocol; an old host keeps working with a new app or is replaced without losing sessions,
  with a clear message when it cannot be).
- A visible list of live sessions (window menu and `takoctl sessions`), with the memory each
  uses, and an explicit "end session" action.
- Limits: a cap on detached sessions and on their scrollback, with what happens at the cap
  written down.

Done when step 4's acceptance holds on a test Mac through 50 quit/relaunch cycles, 10 sleep/wake
cycles and one app update with live sessions; `takoctl sessions` and the window menu list all
live sessions with per-session memory and provide an explicit end action; detached-session and
scrollback limits are enforced with documented eviction/cap semantics; and `session-persistence`
defaults to on.

### [x] A2. Prompt navigation and command selection

Status: shipped in [#12](https://github.com/alex09x/tako/pull/12). Step 6, unchanged in scope.

### [x] A3. Safe paste guard

Status: shipped in [#10](https://github.com/alex09x/tako/pull/10). Step 7, unchanged in scope.

### [x] A4. Paste and drop hardening

Status: shipped in [#8](https://github.com/alex09x/tako/pull/8).

Today the engine removes the bracketed-paste terminator and normalizes newlines, but other
control characters in pasted text (for example `0x03`, `ESC`, C1 controls) reach the program
unchanged. Hidden control characters in copied text are a known command-injection technique.

- Strip or neutralize C0 controls other than tab and newline, `DEL`, and C1 controls in pasted
  text, in both bracketed and unbracketed mode; keep the existing terminator removal.
- Apply the same rules to text dropped onto a pane; dropped file names are shell-quoted.
- `takoctl type` and `send` stay literal (they are explicit input), but are covered by G1.

Done when engine tests cover each control class in both modes, a hostile clipboard (embedded
`ESC [ 201 ~`, `0x03`, `0x9b`, OSC introducers) cannot leave bracketed paste or interrupt the
foreground program, and ordinary pastes of code (tabs, Unicode, multi-line blocks) preserve line
boundaries and content under standard terminal newline normalization.

### [ ] A5. Engine and iOS conformance backlog

Known gaps, each with a reproducer:

- kitty graphics: spec-following image clients cannot show images (placement and transmission
  gaps);
- iOS: a single-codepoint emoji draws as a missing-glyph box;
- iOS: output received before the first resize never reaches the visible screen;
- SSH: some valid ECDSA P-256 private keys fail to load;
- SSH: keyboard-interactive authentication and multi-factor prompts are not implemented.

Done when each has a regression test that failed before the fix, and the iOS walkthrough passes
with images, emoji and an MFA-protected host.

### [ ] A6. Calm under agent load

Agentic work means many panes printing fast at once. Set budgets and hold them:

- render only what is visible; throttle background and occluded panes; never let a busy pane
  delay keystroke-to-screen latency in the focused one;
- bound memory per pane (scrollback compaction, image memory caps) and report it;
- a benchmark scenario in the repository: 20 panes streaming at full speed plus one interactive
  editor, measured for input latency, frame time, CPU and memory.

Done when the benchmark runs on the test Mac in `scripts/ci.sh`, its numbers are recorded per
release, and a regression beyond the written budget fails the run.

### [ ] A7. Diagnostics the user controls

- `takoctl diagnose` and *Help > Export Diagnostics*: versions, configuration with secrets and
  paths reduced, recent logs, crash reports and the benchmark of A6, written to a local file the
  user can read before sharing.
- Nothing is uploaded; there is no telemetry.

Done when a tester can attach one file to a bug report that contains what is needed to
reproduce, and contains no terminal contents unless the user explicitly adds them.

---

## Track B -- Attention layer: know what every session needs (M2)

The core of the agent-first direction. A developer running several agents should never cycle
through tabs to find the one that is waiting, and never miss the one that finished or failed.

### [x] B1. Pane status model

Status: shipped in [PR #17](https://github.com/alex09x/tako/pull/17).

One explicit status per pane, from reported signals only:

| Status | Meaning | Typical sources |
|---|---|---|
| `idle` | at a prompt, nothing pending | OSC 133 prompt mark |
| `running` | a command is running | OSC 133 command start |
| `working` | an agent is working (alias `thinking`) | `takoctl status`, agent hook |
| `waiting_for_input` | a program waits for the user | agent hook, `takoctl ask` |
| `needs_approval` | a program asks permission for an action | agent hook |
| `done` | finished while unfocused, not yet seen | OSC 133 end, agent hook |
| `error` | failed, not yet seen | exit status, agent hook |
| `disconnected` | the session's connection dropped | SSH/session host |
| `unknown` | nothing reported | -- |

- Extends the existing per-tab indicator and keeps its rule that a background tab that failed
  stays marked until the user looks at it. A fixed priority decides which status a tab shows when
  its panes disagree.
- `takoctl status set <status> [--text "Running tests"] [--ttl 10m]` and `takoctl status clear`;
  a status with a TTL expires to `unknown`, so a crashed agent does not show `working` forever.
- A documented escape sequence lets a program set the status of its own pane from anywhere,
  including over SSH. It can only affect the pane it is printed in; text is sanitized and
  length-limited.

Done when every status can be produced by a reported signal in an e2e test, no status is ever
derived from screen text, TTL expiry works, and a remote program can set its own pane's status but
no other's.

### [x] B2. Progress everywhere

Status: shipped in [PR #18](https://github.com/alex09x/tako/pull/18).

OSC 9;4 progress already shows in the dock and the tab title. Add:

- a thin progress bar in the pane header and tab, with distinct normal, error, paused and
  indeterminate styles;
- window-level aggregate progress when several panes report;
- `takoctl progress <0-100|indeterminate|error|pause|clear>` for scripts.

Done when every OSC 9;4 state renders distinctly, clearing works, the `progress-style` setting can
turn each surface off, and a pane that exits clears its progress.

### [x] B3. Structured notifications

Status: shipped in [PR #19](https://github.com/alex09x/tako/pull/19).

- Engine support for the structured desktop-notification sequence (OSC 99): identifiers, title
  and body, urgency, updating and closing a notification, action buttons, and reporting
  activation back to the program that asked. OSC 9 and OSC 777 keep working.
- Every notification carries its context: pane title, working directory, project, and the agent
  or command that sent it.
- Rate limits, de-duplication and body sanitization; respects macOS Focus and the
  `notify-on-command-finish` modes.

Done when a program can post, update and close a notification and learn that the user clicked it;
a flood of notifications is coalesced; and clicking any notification brings its pane forward.

### [x] B4. Notification center and unread state

Status: shipped in [PR #20](https://github.com/alex09x/tako/pull/20).

- A per-window panel listing notifications with pane, time and text; unread state per pane and
  tab; a ring around a pane that needs attention; a count on the Dock icon.
- Shortcuts: jump to the latest unread, mark read, mark all read. Focusing a pane marks it read.
- Unread state survives a relaunch.

Done when a developer with ten panes can go from "something needs me" to the right pane with
one shortcut, and nothing is marked read that the user did not see.

### [x] B5. Session sidebar (vertical tabs)

Status: shipped in [PR #21](https://github.com/alex09x/tako/pull/21).

An optional sidebar with one row per tab or workspace:

- title, status (B1), progress (B2), elapsed time of the running command;
- working directory (OSC 7) and, opt-in, git branch and dirty state read locally from that
  directory -- no network, no background polling of anything the shell did not report;
- latest notification text and a user-editable description;
- opt-in: ports the pane's processes are listening on, from local process inspection.

Keyboard-driven, reorderable, filterable to "needs attention". Off by default for people who
prefer the tab bar.

Done when the sidebar shows correct data for 30 tabs without measurable cost to typing latency
(A6 budget), every field has its source documented, and each opt-in field is off until enabled.

### [x] B6. Pane overview

A full-window overview of every pane across tabs and windows as live thumbnails, coloured by
status; type to filter by title, directory or status; Enter jumps to the pane.

Done when the overview opens in under 150 ms with 30 panes and reflects status changes live.

### [ ] B7. Attention navigation

- Next and previous "needs attention" shortcuts, across windows.
- "Go back" to the pane the user was in before the jump.
- Per-pane mute: a pane that is noisy by design stops raising attention without losing its
  status.

Done when attention navigation never lands on a muted or already-seen pane and "go back" always
returns to the previous one.

### [ ] B8. Agent hook adapters

Most coding-agent tools can run a command on lifecycle events (prompt submitted, permission
requested, waiting for input, turn finished, subagent started or finished, session ended).

- A documented, vendor-neutral contract: which `takoctl` calls (`status`, `notify`, `progress`)
  an event should map to, and the environment Tako provides (`TAKO_SOCKET`, `TAKO_SURFACE_ID`).
- `takoctl hooks install <agent>` for the most widely used agent tools: shows a diff of the
  change to the agent's own configuration, writes it only after confirmation, and
  `takoctl hooks uninstall <agent>` removes exactly what it added.
- Adapters are data files with tests against each tool's current hook format; they never patch
  binaries.

Done when, for each supported tool, a session shows `working`, `needs_approval`,
`waiting_for_input` and `done` at the right moments with a useful notification text, and
uninstall leaves the tool's configuration byte-identical to before.

### [ ] B9. Terminal event stream (`takoctl events`)

Streaming subscription for terminal events (command completion, process exit, cwd change), allowing external orchestrators to react without busy-polling.

- Newline-delimited JSON; filters by pane, tab, workspace and event type.
- Events: command start and end (with exit status and ref), status and progress changes,
  notifications, cwd and title changes, pane created, closed and focused, `ask` answered.
- A resumable cursor so a reconnecting subscriber misses nothing within a bounded window; a slow
  subscriber is dropped with a clear error rather than slowing the app.

Done when an orchestrator can follow ten agents without polling, survives its own restart without
losing events inside the window, and a stalled subscriber cannot affect terminal latency.

### [ ] B10. Interactive agent prompt (`takoctl ask`)

A native modal or inline prompt allowing background agents to ask the user a structured question or choice with immediate typed response returned to stdout.

- Choices, free text, confirmation; optional timeout and default.
- The question appears in the pane header, the notification center and as a notification; the
  pane shows `waiting_for_input` until it is answered.
- The answer is printed as JSON; closing the pane or a timeout returns a distinct exit status.

Done when an agent in a background tab can ask a question, the user answers it from the
notification without switching tabs, and the agent receives the typed answer.

---

## Track C -- Agent workspaces: many agents, one calm window (M3)

### [ ] C1. Workspaces

A workspace groups tabs that belong to one project: a name, a root directory, a colour or icon,
its own tab order and its own attention count. Switching workspaces is one shortcut; workspaces
restore after a relaunch like everything else.

Done when a developer can keep three projects open with their agents and switch between them
without the tab bar of one getting in the way of another.

### [ ] C2. Declarative layouts

- A layout file describes windows, tabs, splits, working directories, titles, environment and
  the program to run in each pane (an argument vector, no shell unless asked).
- `takoctl layout apply <file>` and `takoctl layout save <file>` (the current window as a file).
- A layout file found in a project is untrusted until the user approves it; a changed file asks
  again.

Done when saving and re-applying a layout reproduces it exactly, and an unapproved project layout
never starts a program.

### [ ] C3. Project actions

Project-local actions (build, test, start dev server, start an agent) defined in a project file
and shown in the command palette, trusted on first use and re-confirmed when they change. Each
action runs in a pane chosen by the action (new tab, split, existing pane).

Done when a project's actions appear in the palette only for panes inside that project and
nothing runs that the user did not approve.

### [ ] C4. Worktree tasks

Parallel agents need separate working copies.

- *New task*: create a git worktree and branch from a chosen base, open it as a tab or workspace,
  and run the user's configured agent command there.
- The task's row shows branch, ahead/behind, changed files and status.
- *Finish*: open in the user's editor, or archive -- remove the worktree after confirmation,
  refusing when it has uncommitted or unpushed work.
- Provider-neutral: the agent command is configuration; Tako runs git locally and never pushes.

Done when three tasks can run side by side without touching each other's files, and archiving
never deletes unsaved work.

### [ ] C5. Subagent panes and context hierarchy

- `takoctl split --child-of self --label <name>`: a child pane linked to its parent. The tree and
  sidebar show the hierarchy; a parent's status summarizes its children; a group can collapse;
  closing a parent asks about its children.
- Engine: hierarchical context signalling (OSC 3008) is parsed, so a pane can show where its
  output comes from (host, container, SSH, elevated shell) as breadcrumbs, and tint output from
  elevated contexts.

Done when an agent that starts three subagents gets three visible, labelled child panes, and the
breadcrumbs follow a session into a container and back.

### [ ] C6. Resume agent sessions after a relaunch

When a pane cannot keep its process (session persistence off, or the Mac restarted), it can still
offer to resume the agent session that was running.

- `takoctl resume set -- <argv>`: a pane records how to resume what runs in it (agent hooks can
  do this automatically with the agent's own session id). `takoctl resume show|clear`.
- After a relaunch, the restored pane shows a *Resume* button. Commands run automatically only
  when their prefix was approved by the user for that directory; anything else waits for a click.
- Environment variables that look like secrets are never stored. A session imported from a file
  is untrusted: nothing in it runs automatically.

Done when a relaunch restores agent panes with a working *Resume* that brings back the same agent
conversation, and nothing runs without approval.

### [ ] C7. Input ownership

- Lock a pane against accidental typing (for an agent pane the user is only watching).
- *Take over* and *hand back*: explicit transitions shown in the pane header.
- When a script or agent types into a pane through `takoctl`, the pane shows a short activity mark
  naming the client, so input that did not come from the keyboard is visible.

Done when a locked pane ignores keyboard input but still accepts approved automation, and every
automated keystroke is attributable in the activity log (G2).

### [ ] C8. Broadcast input

Type into several selected panes at once. Off by default, explicit per selection, with a visible
banner on every pane that receives the input.

Done when broadcast can never be left on by accident (it ends with the selection) and secure-input
panes never receive broadcast text.

### [ ] C9. Session export and import

Export a window or workspace -- layout, snapshots, resume bindings -- to a file, and import it on
another Mac or another build of Tako. Imported content is untrusted: control sequences in saved
scrollback are dropped, nothing runs automatically, and a file from a newer format is refused with
a clear error.

Done when an export from one Mac opens on another with the same layout and text, and nothing in a
hostile file can run a command.

### [ ] C10. Bundled agent skills and MCP server

Out-of-the-box skill packages and MCP integration for popular coding agents so they automatically discover and leverage Tako's pane splitting, background execution, and overlay features.

- `takoctl mcp`: a stdio MCP server exposing tree, split, run, wait, last, find, notify, status,
  progress, and ask (with overlay added when D1 lands in M4), each tool behind the capability model of G1.
- `takoctl skills install <agent>`: writes a skill description of these tools into the agent's
  skill directory, with the same diff-and-confirm flow as B8.
- The skill teaches agents to address their own pane, run long work in a split and wait for it
  through Tako instead of scraping output.

Done when an agent with no manual setup beyond `skills install` creates a split, runs a test suite,
sets its status, waits for the result through Tako and reports it -- without reading the screen
text to decide what happened.

---

## Track D -- Artifacts, preview and review (M4)

### [ ] D1. In-terminal artifact and document overlays

`takoctl overlay open --html <file>` (also Markdown, images, PDF and plain diffs).

Embedded sandboxed webview overlay over a pane for static previews of agent-generated HTML test summaries, coverage reports, documentation, or diffs styled with terminal theme variables (`--tako-bg`, `--tako-fg`, ANSI palette).

- Safety gate: strictly a read-only viewer with an explicit origin/filename bar; no JavaScript bridge to terminal control; local file access is strictly sandboxed to the pane's working directory.
- Dismissible with `Esc` or `Cmd+W`.
- Can open as an overlay or as its own split; reloads when the file changes.

Done when an agent opens its coverage report next to the terminal that produced it, the report
cannot reach the network, the terminal or files outside the pane's directory, and closing it
returns focus to the pane.

### [ ] D2. Visual read-back

- `takoctl screenshot` returns the pane as rendered (PNG), and `takoctl text --styled` returns
  text with colours and attributes, so an agent can check a TUI it is building.
- Secure-input panes are refused.

Done when a test can assert on the rendered look of a TUI through `takoctl` alone.

### [ ] D3. Diff review pane

- A read-only diff of a worktree (C4) against its base, with a file list.
- Comments on lines are collected locally and sent as plain text to a chosen pane only when the
  user presses *Send*.
- Tako never commits, pushes or edits files from this pane.

Done when reviewing an agent's change and sending batched feedback to it takes no other tool, and
nothing is written to the repository by Tako.

### [ ] D4. Inline images completeness

- Close the kitty graphics gaps (A5) and support the common inline-image escape used by many
  image-printing tools.
- *Evaluate* sixel support against its memory and security cost.
- Images count against a per-pane memory cap and are kept in snapshots only within the size
  limit.

Done when the common image-printing tools show images correctly in Tako, and a hostile image
stream cannot exceed the cap.

### [ ] D5. Text sizing (*evaluate*)

The text-sizing protocol (OSC 66) lets programs print larger headings in the grid. Decide with a
written reason whether Tako supports it, based on adoption by tools people use.

Done when: a written evaluation records current terminal tool adoption and either schedules an engine
implementation or closes the item as not planned.

---

## Track E -- Commands and output (M2-M4)

Small, independent items built on shell-integration marks. Each can ship alone.

### [x] E1. Prompt navigation and command selection

Status: shipped in [#12](https://github.com/alex09x/tako/pull/12). Step 6.

### [x] E2. Command marks in the gutter and scrollbar

Status: shipped in [PR #13](https://github.com/alex09x/tako/pull/13).

A thin mark beside each command's prompt line (success, failure with code, still running) and
matching marks on the scrollbar, plus marks for search hits.

Done when marks match exit status exactly, appear only where OSC 133 reported a command, and can
be turned off.

### [x] E3. Sticky command header

Status: shipped in [PR #14](https://github.com/alex09x/tako/pull/14).

While scrolling through a long output, the command that produced it stays pinned at the top of the
pane; clicking it jumps to the prompt.

Done when the header always names the command whose output is on screen and never appears without
OSC 133 boundaries.

### [x] E4. Command actions

Status: shipped in [PR #15](https://github.com/alex09x/tako/pull/15).

A context menu and palette actions on any command: copy command, copy output, copy both as a
Markdown block, re-run in this pane (inserted at the prompt, not executed), send the output to
another pane as text, save the output to a file, open the working directory.

Done when each action works on any recorded command and none of them executes anything without
the user pressing Enter.

### [ ] E5. Output filtering (Focus mode)

Temporary live view projection over the scrollback buffer by regex or text match to isolate compiler errors or test failures without mutating session history.

Done when: toggling the filter (`Cmd+Option+F` or configurable) opens an inline query bar that filters visible lines in real-time; non-matching lines are temporarily hidden while relative line ordering and timestamps are preserved; closing the filter immediately restores the complete scrollback without buffer mutation or process interruption.

### [ ] E6. Semantic path clicks (`Cmd+Click`)

Parse file paths with line/column numbers (`file:line[:col]`) from terminal text and pass them to the user's configured editor.

- Strictly user-initiated: clicking a path emits a validated event payload (`path`, `line`, `col`, `cwd` from OSC 7).
- Safety gate: validates the shape (rejects control characters, shell metacharacters, leading hyphens, and disguised OSC 8 targets); never executes binaries found in terminal text and never opens arbitrary paths via LaunchServices. The path is passed strictly as data arguments to the user's explicitly configured editor command or event hook.

Done when: clicking a path under `Cmd` resolves the file against the shell-reported working directory and passes the target to the configured editor command; non-existent files or invalid shapes are ignored without side effects.

### [ ] E7. Passive regex triggers

Opt-in rules for text highlighting or system notifications on specific output matches (e.g. build completion, test failures), strictly passive with no automated input dispatch.

Done when: user-defined regex rules can highlight matching text with specific colors or styles; triggers macOS notifications when long-running background tasks match while unfocused; strictly passive: never injects keystrokes, commands, or automated input into the terminal.

### [x] E8. Safer hyperlinks

Status: shipped in [PR #16](https://github.com/alex09x/tako/pull/16).

OSC 8 links show their real target on hover; schemes other than `http`, `https` and `file` ask
before opening; a link whose text looks like a different URL than its target is flagged.

Done when no link opens without showing where it goes, and the mismatch case is covered by tests.

### [ ] E9. Command history across sessions

A local, searchable history of commands from shell-integration records across all panes, with
directory, time, duration and exit status. Choosing an entry inserts it at the current prompt;
it never runs it.

Done when a command run last week in another tab can be found and inserted in a few keystrokes,
history obeys the same privacy rules as snapshots, and secure-input sessions contribute nothing.

### [ ] E10. Durations and timestamps

Optional per-command duration and start time in the gutter, and the duration in `last` and
`events` output.

Done when durations come only from OSC 133 boundaries and match `wait` results.

---

## Track F -- Sessions, remote and devices (M5)

### [ ] F1. Same session across a relaunch, by default

Step 4 and A1.

### [ ] F2. Resilient remote sessions

Bounded recovery for SSH sessions interrupted by transient disconnects. The tab indicator already
has designed `reconnecting` and `disconnected` states for this.

- Phase 1 bases automatic retry strictly on confirmed transport errors distinguished by the SSH client wrapper or transport layer from normal remote command exits (never inferring disconnect from bare exit status 255 alone, auth/config failures, or screen/stderr text scraping), with a bounded probe and exponential backoff while preserving the local scrollback buffer; ambiguous or unconfirmed exits remain in the `disconnected` state without automatic retry. Leaves broader network-change/sleep retries to later evaluation.

Done when: an explicit transport-loss event marks the session as `reconnecting` (or `disconnected` if unconfirmed or exhausted) rather than immediately closing the tab; attempts bounded probe reconnection only for confirmed transport drops; allows the user to cancel retry or start a fresh shell with a single click.

### [ ] F3. Shell integration over SSH

Opt-in: when the user connects with `ssh` from a Tako pane, Tako can make shell integration
available on the remote host for that session (building on the existing `ssh-terminfo` and
`ssh-env` settings), so command marks, search grouping, status and `last` work remotely. The user
sees what is installed and where, and can remove it.

Done when command boundaries, exit status and working directory work on a fresh remote host with
one setting, and nothing persists on the host unless the user chose to install it.

### [ ] F4. Durable remote sessions (*evaluate*)

Decide between a small remote helper that keeps shells alive across disconnects and attaching to
the user's existing remote multiplexer, based on security, maintenance and what testers use.

Done when: a written evaluation documents the trade-offs between a dedicated helper and multiplexer
attachment against user workflows and records an architectural decision.

### [ ] F5. iPhone companion for Mac sessions

Tako already has an iOS app with its own SSH transport. Extend it to pair with the Mac:

- pair by QR code over the local network or the user's own private network; end-to-end
  encrypted; no relay service by default; devices can be revoked from the Mac;
- see panes and their status, receive attention notifications, answer `takoctl ask` prompts,
  view a pane's screen and type into it, subject to the same capabilities as G1.

Done when a developer away from the Mac sees that an agent is waiting, answers it from the phone,
and the agent continues -- with no third-party service in the path.

### [ ] F6. iOS app maturity

Keyboard-interactive and MFA authentication (A5), host-key management, keys stored in the Secure
Enclave or keychain, agent forwarding as an explicit per-host choice, and graceful behaviour when
the app is backgrounded.

Done when the iOS walkthrough covers each of these against local test servers.

### [ ] F7. Read-only session sharing (*evaluate*)

Share one pane read-only with another device on the local network for pairing or demos, with an
explicit, visible, time-limited share.

Done when: a written evaluation assesses local discovery, encryption, and authorization trade-offs,
deciding whether to schedule an implementation or reject it.

---

## Track G -- Trust and safety for the agent era (gates M1-M5)

### [ ] G1. Control socket capabilities

- Scopes per client: read (tree, text, last, find, events, screenshot), input (send, type, key),
  layout (tab-new, split, close, focus), signal (notify, status, progress, ask), overlay.
- Pane-level switch: "automation may type here". Panes created by a client are writable by it;
  typing into a pane it did not create needs that switch or a one-time confirmation.
- The existing `remote-control` modes stay as the outer switch.

Done when an agent restricted to signal scope can set status and notify but cannot read, stream
events, take screenshots or type, and every refusal names the missing scope.

### [ ] G2. Activity log

Per pane: which client did what and when (action type, not content by default), viewable from the
pane header and exportable. The log is local, bounded and follows the snapshot privacy rules.

Done when every automated action from G1's scopes appears in the log with its client.

### [x] G3. Paste and drop hardening

Item A4; shipped in [#8](https://github.com/alex09x/tako/pull/8).

### [ ] G4. Escape-sequence policy

A single written policy of what a program may do through escape sequences -- set the title, write
the clipboard (with the confirmation setting), read it only through an explicit host policy that refuses by default, notify (rate-limited), report
progress and status, open links (with E8) -- with a fuzz target for every sequence Tako adds.

Done when the policy page exists, each new sequence lands with its fuzz target, and the policy is
enforced in the engine rather than by convention in the app.

### [ ] G5. Secret hygiene

- Secure-input sessions are excluded from snapshots, search, history, `takoctl text`, `last`,
  screenshots and the companion app (verified by tests, not only by design).
- Resume bindings and exports drop secret-looking environment values.
- Optional user-defined redaction patterns for persisted snapshots.

Done when a test that types a password under secure input finds it in none of these places.

### [ ] G6. Supply chain

Signed and notarized releases (shipped) plus a software bill of materials per release, pinned
build inputs and documented steps to reproduce a release build.

Done when a release ships its SBOM and a second machine reproduces the engine artifact from the
documented steps.

---

## Track H -- Customization, ecosystem and accessibility (M6)

### [ ] H1. Settings window over the config file

A native settings window that reads and writes `~/.config/tako/config`; the file stays the source
of truth, comments and ordering are preserved, and errors point to the exact line.

Done when every documented key can be changed from the window and a round trip leaves unrelated
lines byte-identical.

### [ ] H2. Keybindings

A keybinding editor with conflict detection, modal key tables, and chained sequences, all
expressible in the config file.

Done when every action in the command palette can be bound, and conflicts are reported before
they take effect.

### [ ] H3. Themes

Automatic light/dark switching, a theme browser with previews, and a per-workspace tint so
workspaces are recognizable at a glance.

Done when switching the system appearance switches Tako's theme in every open pane without a
relaunch.

### [ ] H4. macOS automation

Shortcuts actions (new tab with a command, run a command and get its output, post a notification,
set status) and an optional scripting dictionary, all going through the same capability model as
`takoctl`.

Done when a Shortcut can open a project layout and start its agents.

### [ ] H5. Event hooks

User scripts run on events (command finished, notification, status change, pane closed), as the
user, opt-in, with the event as JSON on stdin. Hooks observe; they cannot type into panes unless
granted input scope under G1.

Done when a hook can forward "agent needs approval" to any tool the user likes, and a failing hook
never blocks the app.

### [ ] H6. Accessibility

VoiceOver reads terminal lines and whole command outputs, announces command completion and status
changes, and can navigate by command; the sidebar, overview and notification center are fully
keyboard-operable; reduce-motion and increase-contrast are respected, including the tab
indicator's animations.

Done when the main flows (run a command, find output, answer an agent) are completed with
VoiceOver only in a recorded test session.

### [ ] H7. Documentation

A user guide in `docs/` (getting started, configuration reference generated from the code,
`takoctl` reference generated from its usage, shell integration, agent integration guide, privacy
and security), versioned with the app.

Done when every config key and `takoctl` command is documented by generation, and the docs build
fails when one is missing.

### [ ] H8. Quick terminal per workspace

The quick terminal can follow the active workspace (its directory and environment) instead of
being global, as a setting.

Done when the quick terminal opens in the active workspace's root directory with that setting on.

---

## TakoCore

A small track that runs alongside the app:

- [x] minimal sample apps for macOS and iOS (`examples/macos-sample`, `examples/ios-sample`);
- [x] a headless example over the C ABI (`examples/c`);
- [x] a page of limits and compatibility (`docs/takocore.md`);
- [x] a versioning policy for the API (`docs/takocore.md`).

When an app feature needs something new from the engine, it is designed and tested in TakoCore
first, then used by the app.

Done when a developer outside the project builds a sample and embeds a terminal from the
instructions alone. Success is counted in real integrations and their feedback.

Next:

- [ ] **Headless runner for agents and tests.** A small command that runs a program in a
  pseudo-terminal on TakoCore and returns the screen as text, styled text or PNG when a condition
  is met (text appears, output is quiet for N ms, the program exits). Agents can drive full-screen
  programs deterministically, and projects can write tests for their TUIs without a window.
  Done when a TUI test written against it passes identically on two Macs.
- [ ] **Protocol backlog in the engine**, each with parity or spec tests and a G4 fuzz target:
  structured notifications (OSC 99), hierarchical context (OSC 3008), the status sequence of B1,
  pointer shape (OSC 22), the common inline-image escape, kitty graphics gaps, and the text-sizing
  protocol if D5 says yes.
- [ ] **Event API parity.** Every new engine event (notification, context, status, progress)
  reaches Swift hosts through the view delegate and C hosts through the C ABI in the same release.
- [ ] **Linux CI for the crate.** The Rust engine builds and passes its tests on Linux in
  `scripts/ci.sh`, so embedders on other platforms are not surprised. There is no Linux app.

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

- [x] **Native scrollbars:** Status: shipped in 0.1.6 (draggable overlay with hover states and fast jumps).
- [x] **Font ligatures:** Status: shipped in 0.1.6 (`font-feature` setting and core font shaper support).
- [ ] **Reconnecting to sessions:** (Other machines, companion devices, new transports). The first version leaves out cloud sync, vendor-specific agent panels and inferring state from screen text. No telemetry is sent by default.
  The companion device part is planned as F5; other machines and new transports stay here.
- [ ] **AI / Copilot integration:** Revisit only if there is direct demand. Must be opt-in with explicit control over context sharing. (A user's external agent can already drive Tako through `takoctl`).
  Tracks B-D make Tako a better home for the user's own agents; a model built into Tako is not
  part of them.
- [ ] **tmux control mode:** Revisit only if users need Tako to host or control existing tmux workflows (large compatibility surface).
- [ ] **Local web preview pane:** a pane that shows a page from `localhost` next to the terminal
  for dev servers. If built, the first version has no automation API; letting agents click or
  read the page would be a separate, opt-in capability under G1.
- [ ] **Team sharing:** shared workspaces or live collaboration between people. Only with a
  design that keeps the local-first and no-account principles.

## Not planned

These are decisions, written down so they are not reopened without new information:

- **Inferring state from screen text.** Status, attention and command boundaries come only from
  reported signals (principle 1).
- **Telemetry by default, accounts, cloud sync.** Tako works fully offline and alone.
- **Vendor-specific agent panels in the core UI.** Agent tools integrate through hooks, skills,
  `takoctl` and escape sequences, which work for all of them.
- **A built-in model or chat by default.** See "AI / Copilot integration" above.
- **Replacing the shell's line editor.** Command-level features are built on shell-integration
  marks; the shell keeps its own prompt, completion and history.
- **Running agents in a hosted cloud.** Tako runs what the user runs, on machines the user owns.
- **A non-Apple desktop app.** The engine stays portable (TakoCore Linux CI), the app stays
  native to macOS and iOS.

## What 1.0 means

Tako reaches 1.0 when:

- milestones M1 to M3 are done and M4's D1 and D2 have shipped;
- the configuration keys, `takoctl` commands and JSON output, the event stream, the status escape
  sequence and the TakoCore Swift and C APIs are stable, with deprecations announced at least one
  minor release ahead;
- the A6 performance budgets and the G1-G5 safety items hold in CI on every release;
- outside testers have used it daily with several agents for at least one release cycle, and the
  issues that stopped them from working are fixed.
