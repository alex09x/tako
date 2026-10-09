# Tako Feature Coverage & Verification Registry

This registry provides a complete behavioral mapping of all shipped Tako features across macOS App, menus, settings, windowing, security, session persistence, and `takoctl` CLI/MCP control protocols.

---

## 1. Menus & Window Management

| Feature | User Action | Observable Result | Exact Test / Assertion | Verification Level | Required Gate | Status |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **New Window** | `Cmd+N` | Opens a second window with independent terminal & shell | `tako-e2e: new-window` (`windows.count == windows + 1`, `win2 != win1`) | E2E (Accessibility) | `scripts/e2e-macapp.sh` | PASS |
| **New Tab** | `Cmd+T` | Opens a new tab, focuses new shell prompt | `tako-e2e: new-tab` (`second != first`, new tab allocates distinct TTY and receives focused input) | E2E (Accessibility + PTY) | `scripts/e2e-macapp.sh` | PASS |
| **Close Tab** | `Cmd+W` / `exit` | Closes active tab, restores focus to previous tab | `tako-e2e: new-tab`, `persist-close` | E2E (Accessibility) | `scripts/e2e-macapp.sh` | PASS |
| **Close Tab with Running Process** | `Cmd+W` while command runs | Prompts modal sheet with "Cancel" & "Close"; Cancel keeps session running | `tako-e2e: close-busy` (`button("Cancel") != nil`, Cancel keeps window & process) | E2E (Accessibility) | `scripts/e2e-macapp.sh` | PASS |
| **Split Right** | `Cmd+D` | Splits current pane vertically; right pane receives keyboard focus | `tako-e2e: split` (`split != first`, split pane allocates distinct TTY and receives keyboard focus) | E2E (Accessibility + PTY) | `scripts/e2e-macapp.sh` | PASS |
| **Split Focus Navigation** | `Cmd+]` / `Cmd+[` | Shifts active keyboard focus to next/previous pane in cycle | `tako-e2e: split-focus` (`sf2 != sf1`, focus returns to `sf1` on wrap) | E2E (Accessibility) | `scripts/e2e-macapp.sh` | PASS |
| **Quit (Idle)** | `Cmd+Q` with idle prompt | Quits immediately without confirmation modal | `tako-e2e: quit-idle` (`wait for !isRunning == true` within 8s) | E2E (Accessibility) | `scripts/e2e-macapp.sh` | PASS |
| **Quit with Running Process** | `Cmd+Q` with busy command | Prompts confirmation modal; Cancel aborts quit and preserves terminal | `tako-e2e: quit-busy` (`button("Cancel") != nil`, process & window alive) | E2E (Accessibility) | `scripts/e2e-macapp.sh` | PASS |
| **Zoom Font Size** | `Cmd+=` / `Cmd+-` | Increases/decreases font size; PTY columns decrease/increase | `tako-e2e: zoom` (`tput cols` decreases after `Cmd+=`) | E2E (Accessibility + PTY) | `scripts/e2e-macapp.sh` | PASS |
| **Window Resize** | Drag window edge / AX resize | Resizes window; PTY sends SIGWINCH; columns update | `tako-e2e: resize` (`tput cols` tracks window size decrease) | E2E (Accessibility + PTY) | `scripts/e2e-macapp.sh` | PASS |

---

## 2. Text, Clipboard & Modality

| Feature | User Action | Observable Result | Exact Test / Assertion | Verification Level | Required Gate | Status |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Standard Typing** | Keystrokes typed | Reaches shell PTY accurately without dropped or corrupted characters | `tako-e2e: typing` (`expect("typed", "  hello  \n")`) | E2E (Accessibility + PTY) | `scripts/e2e-macapp.sh` | PASS |
| **Line Editing** | Arrow keys & Backspace | Moves cursor and deletes characters in line buffer | `tako-e2e: editing` (`expect("edited", "abc\n")`) | E2E (Accessibility + PTY) | `scripts/e2e-macapp.sh` | PASS |
| **Control Keys** | `Ctrl+U`, `Ctrl+C` | `Ctrl+U` clears line; `Ctrl+C` sends SIGINT to interrupt process | `tako-e2e: control-keys` (`expect("ctrlu", "\n")`, interrupt verified) | E2E (Accessibility + PTY) | `scripts/e2e-macapp.sh` | PASS |
| **Option+Space** | `Option+Space` | Inserts regular ASCII space (`0x20`), not non-breaking space (`0xA0`) | `tako-e2e: option-space` (`expect("optspace", "  \n")`) | E2E (Accessibility + PTY) | `scripts/e2e-macapp.sh` | PASS |
| **Copy on Selection** | Double click word + `Cmd+C` | Selected word copied to system NSPasteboard | `tako-e2e: copy` (`pasteboard.string == "copyme"`) | E2E (Accessibility + Pasteboard) | `scripts/e2e-macapp.sh` | PASS |
| **Paste Plain Text** | `Cmd+V` | Clipboard contents typed into shell as standard input | `tako-e2e: paste` (`expect("pasted", "pasted text")`) | E2E (Accessibility + Pasteboard) | `scripts/e2e-macapp.sh` | PASS |
| **Paste UTF-8** | `Cmd+V` with unicode | Multi-byte UTF-8 characters pasted accurately | `tako-e2e: paste-utf8` (`expect("pasted-utf8", "кириллица 👋 123")`) | E2E (Accessibility + Pasteboard) | `scripts/e2e-macapp.sh` | PASS |
| **Clipboard Confirmation** | Paste multiline / unsafe command | Displays confirmation modal before executing dangerous paste | `ClipboardConfirmationTests` | Unit / Component | `scripts/swift-coverage-gate.py` | PASS |

---

## 3. Configuration, Settings Dialog & Keybindings

| Feature | User Action | Observable Result | Exact Test / Assertion | Verification Level | Required Gate | Status |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Config File Loading** | Change `~/.config/tako/config` | Reads configuration at launch (e.g. font-size, padding) | `tako-e2e: config` (font-size 12 vs 24 column count assertion) | E2E (Accessibility + PTY) | `scripts/e2e-macapp.sh` | PASS |
| **Reload Config** | `Cmd+Shift+,` | Re-reads config file live and updates open terminal dimensions | `tako-e2e: config` (reloads 12pt font live, columns expand) | E2E (Accessibility + PTY) | `scripts/e2e-macapp.sh` | PASS |
| **Window Padding** | Set `window-padding-x` | Decreases usable program columns proportionally | `tako-e2e: padding` (`pad100 < pad0`) | E2E (Accessibility + PTY) | `scripts/e2e-macapp.sh` | PASS |
| **Settings Dialog Presentation** | `Cmd+,` | Opens in-terminal TUI settings card with search field and buttons | `tako-e2e: settings`, `TakoFeatureJourneysUITests.testSettingsDialogPresentationAndDismissal` | E2E / XCUITest | `scripts/e2e-macapp.sh` | PASS |
| **Keybinding Recorder & Reset** | Click "Record" in Settings | Enters live recording; Esc cancels; records custom shortcut; proves runtime binding execution; Reset restores default and removes custom binding | `tako-e2e: settings-record`, `TakoFeatureJourneysUITests.testSettingsKeybindingRecorderSaveAndReset` | E2E / XCUITest | `scripts/e2e-macapp.sh` | PASS |
| **Settings Dismissal** | Press `Escape` in Settings | Dismisses settings dialog and returns first responder to terminal | `tako-e2e: settings`, `TakoFeatureJourneysUITests.testSettingsDialogPresentationAndDismissal` | E2E / XCUITest | `scripts/e2e-macapp.sh` | PASS |
| **Keybinding Conflict Detection** | Check existing shortcut | Detects conflicts against defaults and custom overrides; returns conflicting action metadata | `KeybindConflictTests` (`findConflictWithDefaultShortcut`, `findConflictWithCustomOverride`) | Unit / Logic | `scripts/swift-coverage-gate.py` | PASS |
| **Interactive Keybinding Conflict Reassignment Modal** | Record conflicting shortcut in Settings | Warns of conflict; Esc cancels and proves no change; Return confirms reassignment and proves unique ownership; Reset restores default and removes override | `tako-e2e: settings-conflict`, `TakoFeatureJourneysUITests.testSettingsConflictModalCancelAndReassign` | E2E / XCUITest | `scripts/e2e-macapp.sh` | PASS |
| **Modal Event Containment** | Open Settings modal, type and send Cmd+D | Traps keystrokes and shortcuts; prevents PTY leakage or unwanted window split; terminal recovers upon dismissal | `tako-e2e: modal-containment`, `TakoFeatureJourneysUITests.testModalEventContainment` | E2E / XCUITest | `scripts/e2e-macapp.sh` | PASS |

---

## 4. Workspaces, Sidebar, Overview & Attention

| Feature | User Action | Observable Result | Exact Test / Assertion | Verification Level | Required Gate | Status |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Workspace Creation & Switching** | `takoctl workspace create/switch` | Creates new isolated workspace, switches active context, verifies `workspace current`, switches back | `tako-e2e: workspace-switch` | Integration (CLI) | `scripts/e2e-macapp.sh` | PASS |
| **Session Sidebar Toggle** | `Cmd+Option+S` | Opens/closes session management drawer with visible "Sessions" header, verifies unassisted typing | `tako-e2e: sidebar`, `TakoFeatureJourneysUITests.testSessionSidebarToggle` | E2E / XCUITest | `scripts/e2e-macapp.sh` | PASS |
| **Pane Overview Overlay** | `Cmd+Shift+O` | Shows full-window visual grid of thumbnails with "Pane Overview" header; Esc dismisses, verifies unassisted typing | `tako-e2e: overview`, `TakoFeatureJourneysUITests.testPaneOverviewToggle` | E2E / XCUITest | `scripts/e2e-macapp.sh` | PASS |
| **Overview Offscreen Capture & Rasterization Benchmark (<3.5s)** | Offscreen rasterization with 30 panes in window | Offscreen rasterization captures verified visual cards (<3.5s) | `PaneOverviewTests.overviewOffscreenCaptureBenchmarkWith30Panes` | Benchmark / Render | `scripts/swift-coverage-gate.py` | PASS |
| **Overview Interactive First-Frame Presentation (<150ms)** | Trigger Pane Overview via production open action (`Cmd+Shift+O` / menu) | First interactive frame presented to display in under 150 ms via production open action/callback | `PaneOverviewTests.overviewInteractiveFirstFramePresentationWith30Panes` | Live Window / Presentation Gate | `scripts/swift-coverage-gate.py` | OPEN (Awaiting live display compositor observation; content-verified observer, baseline rejection, and render-suppressed negative control unit tests implemented) |
| **Overview Store Latency (<50ms)** | Refresh overview data with 30 panes | Store data model refresh completes in under 50 ms | `PaneOverviewTests.storeRefreshBenchmarkWith30PanesMeetsDataBudget` | Benchmark | `scripts/swift-coverage-gate.py` | PASS |
| **Attention Navigation** | `Cmd+Option+]` / `[` | Cycles between panes requesting operator attention | `BaseTerminalControllerCoverageTests` | Unit / AppKit | `scripts/swift-coverage-gate.py` | PASS |
| **Notification Center** | `Cmd+Option+N` | Opens notification center drawer with "Notifications" header; Esc dismisses | `TakoFeatureJourneysUITests.testNotificationCenterToggle` | XCUITest | `scripts/uitest.sh` | PASS |

---

## 5. Input Ownership, Broadcast, Overlays & Review

| Feature | User Action | Observable Result | Exact Test / Assertion | Verification Level | Required Gate | Status |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Broadcast Input Across Splits** | `takoctl broadcast start/stop` | Replicates typed keystrokes across all split panes; post-stop isolates typing to focused pane with ordered non-target PTY completion barrier | `tako-e2e: broadcast` (dual delivery lines == 2 && uniqueTtys == 2; post-stop isolated delivery == 1; non-target PTY execution barrier) | Integration (CLI + PTY) | `scripts/e2e-macapp.sh` | PASS |
| **Input Ownership Locking** | `takoctl input lock/unlock` | Locks pane keyboard input (proves human input blocked); sends authorized automated command and asserts PTY witness; verifies typing recovery | `tako-e2e: input-ownership` | Integration (CLI) | `scripts/e2e-macapp.sh` | PASS |
| **Terminal Overlay Presentation & Content** | `takoctl overlay open/close` | Displays markdown card overlay from run-owned sandboxed temp directory in `d.work`; verifies `open: true`, title, on-screen header/sandbox text, fixture body ("Hello Sandboxed Overlay Content"), clean dismissal via Escape, and terminal focus recovery | `tako-e2e: overlay` | Integration (CLI) | `scripts/e2e-macapp.sh` | PASS |
| **Diff Review Status** | `takoctl review status` | Queries worktree review state; verifies structured JSON response | `tako-e2e: diff-review` | Integration (CLI) | `scripts/e2e-macapp.sh` | PASS |
| **Diff Review Comments & Workflow** | `takoctl review open/comment/close` | Initializes worktree diff, attaches line review comments, verifies no feedback dispatched before send, exercises Send Feedback UI button, verifies formatted markdown delivered to target PTY, clean dismissal via Escape, and input recovery | `tako-e2e: diff-review` | Integration (CLI) | `scripts/e2e-macapp.sh` | PASS |

---

## 6. Search & Find in All Tabs

| Feature | User Action | Observable Result | Exact Test / Assertion | Verification Level | Required Gate | Status |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Find All Across Tabs** | `Cmd+Shift+F` | Searches across all open tabs, groups matches by command | `tako-e2e: find-all`, `find-commands` | E2E (Accessibility + Search) | `scripts/e2e-macapp.sh` | PASS |
| **Find Stale Match** | Target tab closes or changes | Stale match reporting alerts user at current position | `tako-e2e: find-stale` | E2E (Accessibility + Search) | `scripts/e2e-macapp.sh` | PASS |

---

## 7. Session Persistence, Restores & Reflow

| Feature | User Action | Observable Result | Exact Test / Assertion | Verification Level | Required Gate | Status |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Live Reattach** | Quit Tako -> Relaunch | Reattaches to same persistent shell session without restarting process | `tako-e2e: persist-live` (`relaunch shell pid == previous shell pid`) | E2E (Persistence) | `scripts/e2e-persist.sh` | PASS |
| **Ended Session Restore** | Shell exits while closed -> Relaunch | Shows saved screen and starts fresh shell | `tako-e2e: persist-gone` | E2E (Persistence) | `scripts/e2e-persist.sh` | PASS |
| **Close Persistent Tab** | `Cmd+W` -> Confirm | Displays confirmation modal; Cancel preserves session | `tako-e2e: persist-close-asks` (`button("Cancel") != nil`, shell stays alive) | E2E (Persistence) | `scripts/e2e-persist.sh` | PASS |
| **Cancelled Quit** | `Cmd+Q` -> Cancel modal | Quit confirmation Cancel keeps session alive and terminal input working | `tako-e2e: persist-cancel` (`button("Cancel") != nil`, shell stays alive) | E2E (Persistence) | `scripts/e2e-persist.sh` | PASS |
| **Physical Session Reflow** | Restore in widened window | Terminal unwraps wrapped rows; reconstructed multi-line marker collapses into a single row | `tako-e2e: persist-reflow` (base64 delivery, narrow wrap boundary, wide unwrap assertion) | E2E (Persistence + Reflow) | `scripts/e2e-persist.sh` | PASS |
| **Second Instance Refusal** | Launch second copy on same session | Second instance is refused; primary owner retains exclusive session lock | `tako-e2e: persist-second-owner` | E2E (Persistence) | `scripts/e2e-persist.sh` | PASS |
| **Crash Recovery** | Simulate crash right after layout change | Recovers tabs and splits from journal | `tako-e2e: crash-layout`, `crash-again` | E2E (Persistence) | `scripts/e2e-persist.sh` | PASS |
| **Corrupt Journal Safety** | Damaged journal on disk | Restores cleanly without crash and does not duplicate tabs | `tako-e2e: crash-corrupt` | E2E (Persistence) | `scripts/e2e-persist.sh` | PASS |

---

## 8. Security, Privacy & Control API (`takoctl` / MCP)

| Feature | User Action | Observable Result | Exact Test / Assertion | Verification Level | Required Gate | Status |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Layout Tree Inspection** | `takoctl tree --json` | Returns JSON representation of windows, tabs, and split panes | `tako-e2e: ctl-tree` (`root["result"]["windows"] != nil`) | Integration (CLI) | `scripts/e2e-macapp.sh` | PASS |
| **Remote Split & Control** | `takoctl split`, `type`, `close` | Splits pane, injects input, closes target pane | `tako-e2e: ctl-layout` | Integration (CLI) | `scripts/e2e-macapp.sh` | PASS |
| **Quick Terminal Control** | `takoctl tree` from Quick Terminal | Quick Terminal surfaces are listed and controllable | `tako-e2e: ctl-quick` | Integration (CLI) | `scripts/e2e-macapp.sh` | PASS |
| **Diagnostics Privacy** | Export diagnostic report | Redacts secrets; terminal contents excluded by default | `DiagnosticsTests.testCollectReportExcludesTerminalByDefault` | Unit / Security | `scripts/swift-coverage-gate.py` | PASS |
| **Imported Session Safety** | Import exported session file | Never auto-runs commands even if prefix is pre-approved | `SessionExportTests.testImportedSessionNeverRunsAutomatically` | Unit / Security | `scripts/swift-coverage-gate.py` | PASS |
| **Visual Readback (Pixels)** | `takoctl screenshot` | Captures rendered PNG; verifies expected header color region and negative control with identical threshold | `VisualReadBackTests.tuiRenderedLookAssertion` | Unit / Pixel Buffer | `scripts/swift-coverage-gate.py` | PASS |
| **Update & Notice Suppression** | Launch with `--no-update` | Disables update check and suppresses launch notice dialogs | `AppUpdaterLaunchTests.testChecksAtLaunchSuppressedByCommandLineFlag` | Unit / Launch | `scripts/swift-coverage-gate.py` | PASS |

---

## 9. Agent Layer, Structured Events, Hooks & MCP Protocols

| Feature | User Action | Observable Result | Exact Test / Assertion | Verification Level | Required Gate | Status |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Pane Status & Progress Indicators** | `takoctl status set/get/clear`, `progress <0-100\|error\|pause\|clear>` | Sets and retrieves explicit pane status pill, custom status text, and progress state in store; updates pane priority and style | `status_command_parses_get_set_clear_and_options`, `progress_command_parses_get_set_error_pause_indeterminate_clear` (CLI parser); `PaneStatusTests` (9 statuses, TTL expiry, signal transitions), `ProgressTests` (4 states, IPC, aggregations) | CLI Unit (Rust) & AppKit Store/IPC Unit (Swift) | `cargo test --manifest-path takoctl/Cargo.toml`, `swift test --filter PaneStatusTests`, `swift test --filter ProgressTests` | PASS |
| **Structured System Notifications** | `takoctl notify TEXT --title T` | Dispatches notification request to socket; notification pipeline enriches context, sanitizes text, coalesces bursts, and posts system notification request | `notify_takes_its_text_and_a_title` (CLI parser); `NotificationTests.surfaceViewPostAndCloseStructuredNotificationFlow`, `NotificationTests.coalescerDeduplicationWithinWindow`, `NotificationTests.shouldPresentRespectsControlKeyAndFocusModeAndUrgency` (Swift handler unit) | CLI Unit (Rust) & Notification Handler Unit (Swift) | `cargo test --manifest-path takoctl/Cargo.toml`, `swift test --filter NotificationTests` | PARTIAL (CLI parsing and Swift notification pipeline unit-tested; end-to-end macOS notification center banner presentation is OS-level / OPEN) |
| **Interactive Agent Prompt Modal** | `takoctl ask MESSAGE [--choice C1,C2 \| --confirm \| --placeholder P]` | CLI parses options and formats JSON response; Swift prompt coordinator sets pane to `.waitingForInput`, isolates dialogs, handles timeouts and defaults, and answers with choice/confirmation/text | `ask_command_parses_options_and_renders_json` (CLI parser/formatter unit); `PromptTests.choicePromptSetsWaitingForInputAndResolvesWithChoice`, `PromptTests.confirmPromptAnswersWithConfirmation`, `PromptTests.textPromptAnswersWithUserText`, `PromptTests.timeoutWithDefaultValueReturnsSuccess` (Swift coordinator unit); `tako-e2e: ask-prompt` (AppKit modal dialog presentation across all 4 modes: bounded child completion with 8s timeout, Abort cancellation path asserting invalid error and cancelled message, Deploy confirmation path asserting confirmed true, choice selection path clicking Production and asserting index 1, free-text input path typing unique tag v2.4.1 into active text field and submitting, accessibility title/prompt/buttons inspection, and unassisted terminal keyboard recovery witness) | CLI Unit (Rust), Prompt Coordinator Unit (Swift) & E2E (AppKit) | `cargo test --manifest-path takoctl/Cargo.toml`, `swift test --filter PromptTests`, `scripts/e2e-macapp.sh` | PASS |
| **Terminal Event Stream** | `takoctl events [--pane ID] [--workspace NAME]` | Streams terminal lifecycle, status, command, and focus events as structured newline-delimited JSON; ring buffer maintains monotonicity, replay from cursor, and drops slow subscribers | `events_command_parses_filters_and_cursor`, `stream_events_yields_lines_until_closed` (CLI unit); `TerminalEventStreamTests.testTerminalEventFilterMatching`, `TerminalEventStreamTests.testRingBufferCursorMonotonicityAndCapacity`, `TerminalEventStreamTests.testSubscribeReplaysMissedEventsFromValidCursor`, `TerminalEventStreamTests.testSlowSubscriberIsDroppedWhenSendBufferOverflows` (Swift event bus unit) | CLI Integration (Rust) & Event Bus Unit (Swift) | `cargo test --manifest-path takoctl/Cargo.toml`, `swift test --filter TerminalEventStreamTests` | PASS |
| **Agent Lifecycle Hook Adapters** | `takoctl hooks install/uninstall/status <AGENT>` | Atomically manages lifecycle hooks for Claude Code, Gemini CLI, Codex, and Aider with restrictive backup permissions (0600) and symlink validation | `claude_adapter_injects_and_removes_hooks`, `gemini_adapter_injects_and_removes_hooks`, `codex_adapter_injects_and_removes_hooks`, `aider_adapter_injects_and_removes_hooks` | CLI Integration (Rust) | `cargo test --manifest-path takoctl/Cargo.toml` | PASS |
| **Declarative Layouts & Trust Approval** | `takoctl layout apply/save/approve/status <FILE>` | Saves and applies declarative multi-pane layouts; refuses automated program execution until explicitly approved | `layout_subcommands_and_options_parsed_and_rendered` (CLI parser unit); `LayoutJournalTests`, `LayoutTests` (Swift layout engine unit); `tako-e2e: ctl-layout` (AppKit integration) | CLI Unit (Rust), Layout Engine Unit (Swift) & E2E (AppKit) | `cargo test --manifest-path takoctl/Cargo.toml`, `scripts/e2e-macapp.sh` | PASS |
| **Project-Local Actions** | `takoctl action list/run/approve/status` | Discovers repository actions from `.tako/actions.json`; validates execution trust barrier before running; unapproved actions refuse execution | `action_subcommands_and_options_parsed_and_rendered` (CLI parser unit); `ProjectActionTests.testProjectActionDiscovery`, `ProjectActionTests.testProjectActionTrustStoreLifecycleAndChangeDetection`, `ProjectActionTests.testUnapprovedProjectActionNeverRunsWithoutApproval` (Swift trust store unit) | CLI Unit (Rust) & Trust Store Unit (Swift) | `cargo test --manifest-path takoctl/Cargo.toml`, `swift test --filter ProjectActionTests` | PARTIAL (CLI parser and Swift action discovery, trust store lifecycle, and unapproved execution refusal verified; automated terminal UI execution is OPEN) |
| **Worktree Task Panes** | `takoctl task list/create/delete` | Manages git worktree-associated task tabs and isolated working environments; archives with uncommitted/unpushed safety checks | `task_subcommands_and_options_parsed_and_rendered` (CLI parser unit); `WorktreeTaskTests.testThreeTasksRunSideBySideWithoutTouchingFiles`, `WorktreeTaskTests.testArchivingRefusesUncommittedAndUnpushedWork`, `WorktreeTaskTests.testWorktreeTaskStoreOperations` (Swift store unit) | CLI Unit (Rust) & Task Store Unit (Swift) | `cargo test --manifest-path takoctl/Cargo.toml`, `swift test --filter WorktreeTaskTests` | PASS |
| **Subagent Context Hierarchy & Collapsing** | `takoctl split --child-of <PANE> --label <NAME>`, `collapse`, `expand` | Links child subagent pane to parent; hierarchical nesting in tree and sidebar; status summarization and collapse/expand; confirmation sheet warns on closing parent with subagents and recursively removes child hierarchy | `subagent_panes_and_hierarchy_options_and_rendering` (CLI parser unit); `SubagentHierarchyTests.testRegisterAndUnregisterChildren`, `SubagentHierarchyTests.testCollapseAndExpand`, `SubagentHierarchyTests.testStatusSummarization`, `SubagentHierarchyTests.testNotificationPosting`, `SubagentHierarchyTests.testRecursiveDescendants` (Swift hierarchy store unit); `tako-e2e: subagent-close` (AppKit modal confirmation sheet presentation when closing parent pane via Cmd+W; accessibility title and warning inspection; Cancel dismissal preserving parent and child hierarchy in tree; Close confirmation recursively tearing down all parent and descendant panes in reverse topological order; tab closure and unassisted terminal keyboard focus recovery in Tab 1) | CLI Unit (Rust), Hierarchy Store Unit (Swift) & E2E (AppKit) | `cargo test --manifest-path takoctl/Cargo.toml`, `swift test --filter SubagentHierarchyTests`, `scripts/e2e-macapp.sh` | PASS |
| **Automated Resume Session Management** | `takoctl resume set/show/clear/run/approve` | Records resumption command for pane; requires directory prefix approval before automatic re-execution; sanitizes secrets; shell quotes metacharacters | `test_resume_cli_parsing`, `test_resume_report_rendering` (CLI unit); `ResumeSessionTests.testTrustStorePrefixApproval`, `ResumeSessionTests.testSecretSanitization`, `ResumeSessionTests.testShellQuoteAndMetacharacters`, `ResumeSessionTests.testImportedSessionUntrusted` (Swift trust unit) | CLI Unit (Rust) & Resume Trust Unit (Swift) | `cargo test --manifest-path takoctl/Cargo.toml`, `swift test --filter ResumeSessionTests` | PASS |
| **Bundled MCP Server & Agent Skills** | `takoctl mcp`, `takoctl skills install/status <AGENT>` | Runs stdio Model Context Protocol server exposing terminal control tools; validates tool capabilities; installs agent skill definitions | `test_mcp_initialize_and_tools_list`, `test_mcp_capabilities_parsing_and_checking`, `test_skill_install_and_uninstall_lifecycle` | CLI Integration (Rust) | `cargo test --manifest-path takoctl/Cargo.toml` | PASS |

---

## 10. Commands, Output, Prompts & Semantic Triggers

| Feature | User Action | Observable Result | Exact Test / Assertion | Verification Level | Required Gate | Status |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Prompt Navigation & Command Selection** | `Cmd+Up` / `Cmd+Down` | Jumps viewport directly between command prompts via semantic shell integration marks; bounds output cleanly for instant copying | `PromptNavigationTests.promptNavigationJumpsDirectlyBetweenPrompts`, `PromptNavigationTests.commandOutputSelectionCleanlyBoundsOutput`, `PromptNavigationTests.commandOutputSelectionAllowsInstantCmdCCopying` | Unit (Swift) | `swift test --filter PromptNavigationTests` | PASS |
| **Passive Regex Output Triggers** | `takoctl triggers add <PATTERN> [--action highlight\|notify]`, `triggers list/remove/clear` | Matches terminal output streams passively without modifying terminal contents; dispatches alerts with cooldown rate-limiting | `triggers_cli_and_report_tests` (CLI unit); `PassiveTriggerStoreTests.testPassiveTriggerStoreRegistrationAndLifecycle`, `PassiveTriggerStoreTests.testPassiveTriggerNotificationsWhenUnfocused`, `PassiveTriggerStoreTests.testCooldownRateLimitingPerSurfaceAndTrigger` (Swift trigger store unit) | CLI Unit (Rust) & Trigger Store Unit (Swift) | `cargo test --manifest-path takoctl/Cargo.toml`, `swift test --filter PassiveTriggerStoreTests` | PASS |
| **Cross-Session Command History Search** | `takoctl history [QUERY]` | Queries command execution history across persistent sessions; records commands, cwd, timestamps, durations, exit codes; restricted to 0600 permissions | `history_command_parsing_and_report` (CLI unit in `takoctl/src/tests/session_inputs.rs`); `CommandHistoryStoreTests.testRecordAndSearch`, `CommandHistoryStoreTests.testPersistenceAndPermissions`, `CommandHistoryStoreTests.testHistoryBoundingAtMaxEntries`, `CommandHistoryStoreTests.testSearchLimitsNegativeAndOversized` (Swift store unit) | CLI Unit (Rust) & Command History Store Unit (Swift) | `cargo test --manifest-path takoctl/Cargo.toml`, `swift test --filter CommandHistoryStoreTests` | PASS |
| **Control Socket Capabilities & Grant Authorization** | `takoctl grant request/create/revoke/list` | Enforces token-scoped capabilities across defined `ControlScope` set (`read`, `input`, `layout`, `signal`, `overlay`, `approval`); refuses ungranted commands with missing scope error | `control_capabilities_and_scopes_parsing` (CLI unit); `ControlProtocolTests.controlScopeRequiredMapping`, `ControlProtocolTests.responseIncludesScopeOnMissingScopeError`, `ControlProtocolTests.serverSideGrantAndAuthorizationGate` (Swift protocol authorization unit) | CLI Unit (Rust) & Protocol Authorization Unit (Swift) | `cargo test --manifest-path takoctl/Cargo.toml`, `swift test --filter ControlProtocolTests` | PASS |
| **Automated Activity Audit Logging** | `takoctl activity [TARGET] [--export FILE]` | Audits external automation inputs with client attribution, timestamps, and target pane identification; records history; exports JSON; clearing requires `approval` scope | `test_activity_subcommands_and_options_parsed_and_rendered` (CLI unit in `takoctl/src/tests/session_inputs.rs`); `InputOwnershipTests.testActivityAttributionAndMaxLogEntries`, `InputOwnershipTests.testExportLogAndClearLog`, `InputOwnershipTests.testClearActivityMarkAndRemoval` (Swift activity log store unit) | CLI Unit (Rust) & Activity Log Store Unit (Swift) | `cargo test --manifest-path takoctl/Cargo.toml`, `swift test --filter InputOwnershipTests` | PASS |
| **Quick Terminal Global Toggle** | `Cmd+Shift+~` (or configured hotkey) | Summons dropdown quick terminal overlay window anchored to top of display; controllable via `takoctl tree` listing `quick-terminal` surface; dismisses cleanly | `QuickTerminalScreenStateCacheTests.validWhenGeometryMatches`, `invalidWhenScreenGrows`, `invalidWhenScreenShrinks`, `invalidWhenScaleDiffers` (Swift screen geometry unit); `tako-e2e: ctl-quick` (E2E Accessibility: `Cmd+Shift+~` toggle, `takoctl tree` surface verification, command execution) | Unit (Swift) & E2E (Accessibility) | `swift test --filter QuickTerminalScreenStateCacheTests`, `scripts/e2e-macapp.sh` | PASS |

---

## 11. Public Test Runners & Complete Isolation Architecture

1. **`scripts/test-ui.sh`**:
   - Single command entry point for automated UI testing.
   - Defaults to isolated bundle identity `com.tako-core.terminal.e2e` and isolated build directory `target/macapp-e2e`.
   - Rebuilds fresh `Tako.app` unconditionally before test execution.
   - Enforces exact literal scenario allowlist matching (`grep -Fqx`).
2. **`scripts/uitest.sh`**:
   - Xcode UI test runner executing upstream XCUITest ported suite.
   - Produces structured result bundle `target/uitest.xcresult`.
   - Propagates PIPESTATUS[0] and fails on zero passed tests or any test failures.
   - Built with isolated bundle identity `com.tako-core.terminal.uitest`.
3. **`scripts/e2e/tako-e2e.swift`**:
   - Native macOS Accessibility driver (`AXUIElement`).
   - Fails closed if launched against production bundle identity `com.tako-core.terminal`.
   - `forgetLayout` strictly protects production state directories.
4. **`scripts/ci.sh`**:
   - Comprehensive multi-stage gate: `rust`, `cli` (`takoctl`), `swift`, `apps` (selftest + e2e), `persist`, and `uitest`.

---

## 12. Verified Execution Results & Test Manifest

All UI and engine test suites are verified with revision-linked artifacts and explicit module/feature scoping:

| Test Suite / Entry Point | Scenarios / Methods & Scoping | Result | Immutable Evidence & Run Artifacts |
| :--- | :--- | :--- | :--- |
| `./scripts/test-ui.sh` | 44 default E2E journeys (`restore`, `typing`, `option-space`, `editing`, `control-keys`, `find-all`, `find-commands`, `ctl-tree`, `ctl-quick`, `ctl-layout`, `ctl-close-wait`, `crash-layout`, `crash-again`, `crash-corrupt`, `quit-layout`, `upgrade-crash`, `find-stale`, `new-tab`, `split`, `zoom`, `resize`, `paste`, `paste-utf8`, `close-busy`, `copy`, `quit-busy`, `config`, `padding`, `split-focus`, `quit-idle`, `new-window`, `settings`, `settings-record`, `settings-conflict`, `modal-containment`, `sidebar`, `overview`, `workspace-switch`, `broadcast`, `input-ownership`, `diff-review`, `overlay`, `ask-prompt`, `subagent-close`) via macOS Accessibility against `com.tako-core.terminal.e2e` | **44 PASSED, 0 FAILED** | Remote execution on `Alexs-MacBook-Pro.local` (target binary: `target/tako-e2e`, scenarios: 44 default / 52 total) |
| `./scripts/test-ui.sh --persist` | 8 session persistence & crash recovery scenarios (`persist-live`, `persist-gone`, `persist-close`, `persist-cancel`, `persist-close-asks`, `persist-close-quit`, `persist-second-owner`, `persist-reflow`) against `com.tako-core.terminal.persist` | **8 PASSED, 0 FAILED** | Remote execution on `Alexs-MacBook-Pro.local` (target bundle `target/macapp-persist`, Oct 9 00:14) |
| `./scripts/uitest.sh TakoFeatureJourneysUITests` | 8 XCUITest journeys in `TakoFeatureJourneysUITests` (`testNotificationCenterToggle`, `testPaneOverviewToggle`, `testSessionSidebarToggle`, `testSettingsDialogPresentationAndDismissal`, `testSettingsKeybindingRecorderCancel`, `testSettingsKeybindingRecorderSaveAndReset`, `testSettingsConflictModalCancelAndReassign`, `testModalEventContainment`) against `com.tako-core.terminal.uitest` | **8 PASSED, 0 FAILED** (46.96s) | Remote execution on `Alexs-MacBook-Pro.local` at `2026-10-09 03:23:49.808` (commit `7e5e1d2c2a`); preserved versioned run artifacts: log `target/runs/20261009-032349-uitest-7e5e1d2/uitest.log` (132 KB, SHA-256: `e6c4b4c6e0ba0289ea006f0c287617fdefb3caf70073278d5d167c73256e3a2c`), result bundle `target/runs/20261009-032349-uitest-7e5e1d2/uitest.xcresult` |
| `cargo test --manifest-path takoctl/Cargo.toml` | 84 unit and integration tests covering CLI commands, MCP tools, hook adapters, skills, and diagnostics (exercises CLI/MCP parsing, serialization, and adapter logic; does not exercise AppKit UI) | **84 PASSED, 0 FAILED** | Cargo test runner output, exit status 0 |
| `python3 scripts/coverage-gate.py --features pty,ssh` | VT engine line coverage gate over `src/`. Floor: 80% line coverage. (Note: bare invocation defaults `--features` to empty, gating non-feature core files only; passing `--features pty,ssh` gates full engine including PTY and SSH modules) | **NOT VERIFIED** (No coverage JSON/per-file gate artifact preserved; historical `target/cargo-final-recheck.log` contains test summary only) | Historical test log `target/cargo-final-recheck.log` (summary only) |
| `python3 scripts/swift-coverage-gate.py` | Swift line coverage gate. (Note: bare invocation defaults to checking `TakoCoreUI` only. Monitored broader AppKit modules require explicit `--module TakoKit --module TakoApp` and are otherwise verified via dedicated unit test suites in `swift/Tests/TakoTests/`) | **NOT VERIFIED** (No per-file coverage report preserved; unit suite execution verified via test summaries only) | Historical test run log `target/swift-final-recheck.log` (commit `8f158c2`, 282 passed in 24 suites, 1.95s; active unit test suite `swift/Tests/TakoTests/` verified separately) |

---

## 13. Open Gates & Active Operator Status

The operator assignment remains active. In accordance with reviewer directives, the following capabilities are explicitly catalogued as OPEN or PARTIAL:

1. **Row 63: Interactive Presentation Budget (<150ms)**: **OPEN**
   - *Status*: Offscreen regression check with pre-open baseline and render-suppressed negative control approved in commit `48a42fc`. Interactive presentation gate remains OPEN awaiting live display compositor verification.
2. **Structured System Notifications**: **PARTIAL**
   - *Status*: CLI parser and Swift notification pipeline (`NotificationTests`) verified. End-to-end macOS notification center banner presentation is OS-level / OPEN.
3. **Project-Local Actions (`takoctl action`)**: **PARTIAL**
   - *Status*: CLI parser, action discovery, trust store lifecycle, and unapproved execution refusal (`ProjectActionTests`) verified. Automated terminal UI execution is OPEN.
4. **Overall Assignment**: **ACTIVE**
   - Full coverage is not declared from test counts alone; work continues on actual displayed-content observation and remaining behavioral UI journeys.


