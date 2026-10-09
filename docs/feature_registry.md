# Tako Feature Coverage & Verification Registry

This registry provides a complete behavioral mapping of all shipped Tako features across macOS App, menus, settings, windowing, security, session persistence, and `takoctl` CLI/MCP control protocols.

---

## 1. Menus & Window Management

| Feature | User Action | Observable Result | Exact Test / Assertion | Verification Level | Required Gate | Status |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **New Window** | `Cmd+N` | Opens a second window with independent terminal & shell | `tako-e2e: new-window` (`windows.count == windows + 1`, `win2 != win1`) | E2E (Accessibility) | `scripts/e2e-macapp.sh` | PASS |
| **New Tab** | `Cmd+T` | Opens a new tab, focuses new shell prompt | `tako-e2e: new-tab` (`tabs.count == 2`, initial shell yields focus) | E2E (Accessibility) | `scripts/e2e-macapp.sh` | PASS |
| **Close Tab** | `Cmd+W` / `exit` | Closes active tab, restores focus to previous tab | `tako-e2e: new-tab`, `persist-close` | E2E (Accessibility) | `scripts/e2e-macapp.sh` | PASS |
| **Close Tab with Running Process** | `Cmd+W` while command runs | Prompts modal sheet with "Cancel" & "Close"; Cancel keeps session running | `tako-e2e: close-busy` (`button("Cancel") != nil`, Cancel keeps window & process) | E2E (Accessibility) | `scripts/e2e-macapp.sh` | PASS |
| **Split Right** | `Cmd+D` | Splits current pane vertically; right pane receives keyboard focus | `tako-e2e: split` (`takoctl tree` shows 2 panes in split node; typing enters right pane) | E2E (Accessibility + CLI) | `scripts/e2e-macapp.sh` | PASS |
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
| **Settings Dialog Presentation** | `Cmd+,` | Opens in-terminal TUI settings card with search field and buttons | `tako-e2e: settings`, `TakoFeatureJourneysUITests` | E2E / XCUITest | `scripts/e2e-macapp.sh` | PASS |
| **Keybinding Recorder** | Click "Record" in Settings | Enters live shortcut recording mode; captures modifiers | `tako-e2e: settings-record` | E2E (Accessibility) | `scripts/e2e-macapp.sh` | PASS |
| **Settings Dismissal** | Press `Escape` in Settings | Dismisses settings dialog and returns first responder to terminal | `tako-e2e: settings`, `TakoFeatureJourneysUITests` | E2E / XCUITest | `scripts/e2e-macapp.sh` | PASS |
| **Keybinding Uniqueness** | Register shortcut | Checks for conflict against menu, default, and custom overrides | `KeybindingValidatorTests` | Unit / Validation | `scripts/swift-coverage-gate.py` | PASS |
| **Conflict Reassignment** | Override existing shortcut | Shows confirmation modal; updates keybinding map atomically | `KeybindingConflictTests` | Unit / UI Modal | `scripts/swift-coverage-gate.py` | PASS |

---

## 4. Workspaces, Sidebar, Overview & Attention

| Feature | User Action | Observable Result | Exact Test / Assertion | Verification Level | Required Gate | Status |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Workspace Creation & Switching** | `takoctl workspace create/switch` | Creates new isolated workspace and switches active surface context | `tako-e2e: workspace-switch` | Integration (CLI) | `scripts/e2e-macapp.sh` | PASS |
| **Session Sidebar Toggle** | `Cmd+Option+S` | Opens/closes left session management drawer | `tako-e2e: sidebar`, `TakoFeatureJourneysUITests` | E2E / XCUITest | `scripts/e2e-macapp.sh` | PASS |
| **Pane Overview Overlay** | `Cmd+Shift+O` | Shows full-window visual grid of all active pane thumbnails | `tako-e2e: overview`, `TakoFeatureJourneysUITests` | E2E / XCUITest | `scripts/e2e-macapp.sh` | PASS |
| **Overview Open Latency (<150ms)** | Trigger Pane Overview with 30 panes | View hierarchy layouts and draws first frame in under 150 ms | `PaneOverviewTests: overviewActualOpenPresentationLatencyWith30PanesMeetsBudget` | Benchmark / Render | `scripts/swift-coverage-gate.py` | PASS |
| **Overview Store Latency (<50ms)** | Refresh overview data with 30 panes | Store data model refresh completes in under 50 ms | `PaneOverviewTests: storeRefreshBenchmarkWith30PanesMeetsDataBudget` | Benchmark | `scripts/swift-coverage-gate.py` | PASS |
| **Attention Navigation** | `Cmd+Option+]` / `[` | Cycles between panes requesting operator attention | `BaseTerminalControllerCoverageTests` | Unit / AppKit | `scripts/swift-coverage-gate.py` | PASS |
| **Notification Center** | `Cmd+Option+N` | Opens notification center drawer; lists pending signals | `TakoFeatureJourneysUITests` | XCUITest | `scripts/uitest.sh` | PASS |

---

## 5. Input Ownership, Broadcast, Overlays & Review

| Feature | User Action | Observable Result | Exact Test / Assertion | Verification Level | Required Gate | Status |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Broadcast Input Across Splits** | `takoctl broadcast start/stop` | Replicates typed keystrokes across all split panes in active tab | `tako-e2e: broadcast` | Integration (CLI + PTY) | `scripts/e2e-macapp.sh` | PASS |
| **Input Ownership Locking** | `takoctl input lock/unlock` | Locks pane keyboard input to prevent accidental human interference | `tako-e2e: input-ownership` | Integration (CLI) | `scripts/e2e-macapp.sh` | PASS |
| **Terminal Overlay Presentation** | `takoctl overlay open/close` | Displays markdown / diff card overlay over active terminal surface | `tako-e2e: overlay` | Integration (CLI) | `scripts/e2e-macapp.sh` | PASS |
| **Diff Review Status** | `takoctl review status` | Queries worktree review state and pending diffs | `tako-e2e: diff-review` | Integration (CLI) | `scripts/e2e-macapp.sh` | PASS |

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
| **Physical Session Reflow** | Restore in widened window | Terminal unwraps wrapped rows; reconstructed multi-line marker collapses into a single row | `tako-e2e: persist-reflow` (dynamic marker, narrow wrapped boundary, wide unwrap) | E2E (Persistence + Reflow) | `scripts/e2e-persist.sh` | PASS |
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
| **Diagnostics Privacy** | Export diagnostic report | Redacts secrets; terminal contents excluded by default | `DiagnosticsTests: testCollectReportExcludesTerminalByDefault` | Unit / Security | `scripts/swift-coverage-gate.py` | PASS |
| **Imported Session Safety** | Import exported session file | Never auto-runs commands even if prefix is pre-approved | `SessionExportTests: testImportedSessionNeverRunsAutomatically` | Unit / Security | `scripts/swift-coverage-gate.py` | PASS |
| **Visual Readback (Pixels)** | `takoctl screenshot` | Captures rendered PNG; verifies expected header color region and negative control | `VisualReadBackTests: tuiRenderedLookAssertion` | Unit / Pixel Buffer | `scripts/swift-coverage-gate.py` | PASS |
| **Update & Notice Suppression** | Launch with `--no-update` | Disables update check and suppresses launch notice dialogs | `AppUpdaterLaunchTests: testChecksAtLaunchSuppressedByCommandLineFlag` | Unit / Launch | `scripts/swift-coverage-gate.py` | PASS |

---

## 9. Public Test Runners & Complete Isolation Architecture

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
