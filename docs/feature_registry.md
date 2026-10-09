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
| **Pane Status & Progress Indicators** | `takoctl status set/get/clear`, `progress <0-100\|error\|pause\|clear>` | Sets and retrieves explicit pane status pill, custom status text, and progress state; reflected immediately in overview and sidebar | `status_command_parses_get_set_clear_and_options`, `progress_command_parses_get_set_error_pause_indeterminate_clear`, `liveStatusUpdateReflectsImmediatelyInStore` | Integration (CLI + Rust) & Unit (Swift) | `scripts/ci.sh cli`, `scripts/swift-coverage-gate.py` | PASS |
| **Structured System Notifications** | `takoctl notify TEXT --title T` | Dispatches macOS system notification with pane association; user click activates target pane | `notify_takes_its_text_and_a_title` | Integration (CLI + Rust) | `scripts/ci.sh cli` | PASS |
| **Interactive Agent Prompt Modal** | `takoctl ask MESSAGE [--choice C1,C2 \| --confirm]` | Opens interactive modal prompt in target window; user selection or text input returns structured JSON to caller | `ask_command_parses_options_and_renders_json` | Integration (CLI + Rust) | `scripts/ci.sh cli` | PASS |
| **Terminal Event Stream** | `takoctl events [--pane ID] [--workspace NAME]` | Streams terminal lifecycle, status, command, and focus events as structured newline-delimited JSON | `events_command_parses_filters_and_cursor`, `stream_events_yields_lines_until_closed` | Integration (CLI + Rust) | `scripts/ci.sh cli` | PASS |
| **Agent Lifecycle Hook Adapters** | `takoctl hooks install/uninstall/status <AGENT>` | Atomically manages lifecycle hooks for Claude Code, Gemini CLI, Codex, and Aider with restrictive backup permissions and symlink validation | `claude_adapter_injects_and_removes_hooks`, `gemini_adapter_injects_and_removes_hooks`, `codex_adapter_injects_and_removes_hooks`, `aider_adapter_injects_and_removes_hooks` | Integration (CLI + Rust) | `scripts/ci.sh cli` | PASS |
| **Declarative Layouts & Trust Approval** | `takoctl layout apply/save/approve/status <FILE>` | Saves and applies declarative multi-pane layouts; refuses automated program execution until explicitly approved | `layout_subcommands_and_options_parsed_and_rendered` | Integration (CLI + Rust) | `scripts/ci.sh cli` | PASS |
| **Project-Local Actions** | `takoctl action list/run/approve/status` | Discovers repository actions from `.tako/actions.json`; validates execution trust barrier before running | `action_subcommands_and_options_parsed_and_rendered` | Integration (CLI + Rust) | `scripts/ci.sh cli` | PASS |
| **Worktree Task Panes** | `takoctl task list/create/delete` | Manages git worktree-associated task tabs and isolated working environments | `task_subcommands_and_options_parsed_and_rendered`, `WorktreeTaskTests` | Integration (CLI + Rust) & Unit (Swift) | `scripts/ci.sh cli`, `scripts/swift-coverage-gate.py` | PASS |
| **Subagent Context Hierarchy & Collapsing** | `takoctl split --child-of <PANE> --label <NAME>`, `collapse`, `expand` | Links child subagent pane to parent; hierarchical nesting in tree and sidebar; closing parent triggers recursive confirmation sheet | `subagent_panes_and_hierarchy_options_and_rendering`, `BaseTerminalController.closeSurface(parentSurfaces)` | Integration (CLI + Rust) & Unit (Swift) | `scripts/ci.sh cli`, `scripts/swift-coverage-gate.py` | PASS |
| **Automated Resume Session Management** | `takoctl resume set/show/clear/run/approve` | Records resumption command for pane; requires directory prefix approval before automatic re-execution | `test_resume_cli_parsing`, `test_resume_report_rendering` | Integration (CLI + Rust) | `scripts/ci.sh cli` | PASS |
| **Bundled MCP Server & Agent Skills** | `takoctl mcp`, `takoctl skills install/status <AGENT>` | Runs stdio Model Context Protocol server exposing terminal control tools; installs agent skill definitions | `test_mcp_initialize_and_tools_list`, `test_mcp_capabilities_parsing_and_checking`, `test_skill_install_and_uninstall_lifecycle` | Integration (CLI + Rust) | `scripts/ci.sh cli` | PASS |

---

## 10. Commands, Output, Prompts & Semantic Triggers

| Feature | User Action | Observable Result | Exact Test / Assertion | Verification Level | Required Gate | Status |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Prompt Navigation & Command Selection** | `Cmd+Up` / `Cmd+Down` | Jumps viewport directly between command prompts via semantic shell integration marks | `CommandNavigationCoverageTests`, `src/terminal/command_nav.rs` | Unit (Swift + Rust) | `scripts/swift-coverage-gate.py`, `scripts/coverage-gate.py` | PASS |
| **Passive Regex Output Triggers** | `takoctl triggers add <PATTERN> [--action highlight\|notify]`, `triggers list/remove/clear` | Matches terminal output streams passively without modifying terminal contents; dispatches alerts or highlights | `triggers_cli_and_report_tests` | Integration (CLI + Rust) | `scripts/ci.sh cli` | PASS |
| **Cross-Session Command History Search** | `takoctl history [QUERY]` | Queries command execution history across persistent sessions with timestamp and directory filtering | `history_command_parsing_and_report` | Integration (CLI + Rust) | `scripts/ci.sh cli` | PASS |
| **Control Socket Capabilities & Grant Authorization** | `takoctl grant request/create/revoke/list` | Enforces token-scoped capabilities (read, write, control, overlay); revokes authorization tokens cleanly | `control_capabilities_and_scopes_parsing`, `test_mcp_capability_scope_refusal` | Integration (CLI + Rust) | `scripts/ci.sh cli` | PASS |
| **Automated Activity Audit Logging** | `takoctl activity [TARGET] [--export FILE]` | Audits all external automation inputs with client attribution, timestamps, and target pane identification | `test_activity_subcommands_and_options_parsed_and_rendered` | Integration (CLI + Rust) | `scripts/ci.sh cli` | PASS |
| **Quick Terminal Global Toggle** | `Option+Space` (or configured hotkey) | Summons/dismisses dropdown quick terminal overlay window anchored to top of display | `QuickTerminalControllerTests`, `ctl-quick` | Unit (Swift) & E2E (Accessibility) | `scripts/swift-coverage-gate.py`, `scripts/e2e-macapp.sh` | PASS |

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

All UI test suites have been verified on the remote Mac host (`alex09x@Alexs-MacBook-Pro.local`) without local screen interference:

| Test Suite / Entry Point | Scenarios / Methods | Result | Evidence / Log Location |
| :--- | :--- | :--- | :--- |
| `./scripts/test-ui.sh` | 42 default E2E journeys (`restore`, `typing`, `option-space`, `editing`, `control-keys`, `find-all`, `find-commands`, `ctl-tree`, `ctl-quick`, `ctl-layout`, `ctl-close-wait`, `crash-layout`, `crash-again`, `crash-corrupt`, `quit-layout`, `upgrade-crash`, `find-stale`, `new-tab`, `split`, `zoom`, `resize`, `paste`, `paste-utf8`, `close-busy`, `copy`, `quit-busy`, `config`, `padding`, `split-focus`, `quit-idle`, `new-window`, `settings`, `settings-record`, `settings-conflict`, `modal-containment`, `sidebar`, `overview`, `workspace-switch`, `broadcast`, `input-ownership`, `diff-review`, `overlay`) | **42 PASSED, 0 FAILED** | Remote execution log, exit status 0 |
| `./scripts/test-ui.sh --persist` | 8 session persistence & crash recovery scenarios (`persist-live`, `persist-gone`, `persist-close`, `persist-cancel`, `persist-close-asks`, `persist-close-quit`, `persist-second-owner`, `persist-reflow`) | **8 PASSED, 0 FAILED** | Remote execution log, exit status 0 |
| `./scripts/uitest.sh TakoFeatureJourneysUITests` | 8 XCUITest journeys (`testNotificationCenterToggle`, `testPaneOverviewToggle`, `testSessionSidebarToggle`, `testSettingsDialogPresentationAndDismissal`, `testSettingsKeybindingRecorderCancel`, `testSettingsKeybindingRecorderSaveAndReset`, `testSettingsConflictModalCancelAndReassign`, `testModalEventContainment`) | **8 PASSED, 0 FAILED** | `target/uitest.xcresult`, `target/uitest.log`, exit status 0 |
| `cargo test --manifest-path takoctl/Cargo.toml` | 84 unit and integration tests covering CLI commands, MCP tools, hook adapters, skills, and diagnostics | **84 PASSED, 0 FAILED** | Remote cargo test runner, exit status 0 |
| `python3 scripts/coverage-gate.py` | 216 Rust VT engine tests covering terminal parser, screen, graphics, selection, checkpointing | **216 PASSED, 0 FAILED** | 100% of files under `src/` covered >= 80% |
| `python3 scripts/swift-coverage-gate.py` | 290+ Swift unit, AppKit controller, and view model coverage tests | **290+ PASSED, 0 FAILED** | All monitored Swift modules >= 80% coverage |
| **Combined Execution Manifest** | **74 documented feature mappings, 640+ automated test executions** | **ALL SUITES PASSING** | Zero manual operator testing required |


