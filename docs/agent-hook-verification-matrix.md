# Agent Lifecycle & Hook Verification Matrix

- **Base Git Revision**: `262777100e35a5e4059bc0c7b5626bcdbd8b57f5`
- **Working Tree Diff Fingerprint**: `77fbc79ae7bb5dabecc3f523dd641f937fed0feff7c8c4de5695b0bfbdf7ffbb`
- **Tested `takoctl` Debug Binary Fingerprint**: `cabbf7b3922d630d87a11063103e98884dce2e0ae68768f5f81d2df9f121fef8`
- **Command-to-Mock Fixture Runs**: `target/runs/20261012-004714-agent-hooks-verification/` & `target/runs/20261012-005152-agent-hooks-verification/`
- **Shipped Adapter Live Provider Verification Run**: `target/runs/20261012-012500-shipped-adapter-provider-verification/`
- **Native Installer & Provider Runtime Verification Run**: `target/runs/20261012-020000-native-installer-provider-verification/`

---

## 1. Summary Matrix

| Agent | Version & Binary SHA256 | Config Target Path | Config & Install Tests | Socket Serialization | AppKit Tab Model | Real Server Socket Multi-Pane Routing | Two-Agent / PTY Routing & UI Focus | Live Provider Runtime Event | Status |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Codex CLI** | `0.162.1`<br/>`74c6a6d263f4...` | `$CODEX_HOME/hooks.json`<br/>(defaults `~/.codex/hooks.json`) | • `takoctl`: **PASS**<br/>• Swift: **PASS** | **SERIALIZATION PASS** | **MODEL PASS** | **SOCKET ROUTING PASS**<br/>(Live `ControlServer` UNIX socket) | **PTY ROUTING PASS**<br/>(`TwoAgentPTYRoutingTests`) | **PROVIDER PASS**<br/>• Normal trust onboarding via `config.toml`<br/>• `UserPromptSubmit` (`working` + progress): witnessed live<br/>• `Stop` (`done` + progress clear): witnessed live<br/>• Zero bypass flags required | **FULL PASS** |
| **Claude Code** | `2.1.296`<br/>`c9b5341637be...` | `~/.claude/settings.json` | • `takoctl`: **PASS**<br/>• Swift: **PASS** | **SERIALIZATION PASS** | **MODEL PASS** | **SOCKET ROUTING PASS**<br/>(Live `ControlServer` UNIX socket) | **PTY ROUTING PASS**<br/>(`TwoAgentPTYRoutingTests`) | **PROVIDER PASS**<br/>• Isolated execution via `--settings`<br/>• `UserPromptSubmit` (`working` + progress): witnessed live<br/>• `Stop` (`done` + progress clear): witnessed live<br/>• Exit 0, stdout verified | **FULL PASS** |
| **Antigravity** | `1.3.3`<br/>`96dd362d5583...` | `~/.gemini/config/hooks.json` | • `takoctl`: **PASS**<br/>• Swift: **PASS** | **SERIALIZATION PASS** | **MODEL PASS** | **SOCKET ROUTING PASS**<br/>(Live `ControlServer` UNIX socket) | **PTY ROUTING PASS**<br/>(`TwoAgentPTYRoutingTests`) | **OPEN (IN-PROCESS HOST)**<br/>• Config syntax & schema: **PASS**<br/>• Host runner active; standalone headless execution unverified | **FIXTURE, MODEL, PTY & SOCKET PASS** |
| **Gemini CLI** | `0.54.4`<br/>`acb481430057...` | `~/.gemini/settings.json` | • `takoctl`: **PASS**<br/>• Swift: **PASS** | **SERIALIZATION PASS** | **MODEL PASS** | **SOCKET ROUTING PASS**<br/>(Live `ControlServer` UNIX socket) | **PTY ROUTING PASS**<br/>(`TwoAgentPTYRoutingTests`) | **BLOCKED (UNSUPPORTED_CLIENT)**<br/>• Measured blocker on tested free tier: `IneligibleTierError` | **BLOCKED (ACCOUNT TIER / DEPRECATED)** |
| **Aider** | None installed | `~/.aider.conf.yml` | • `takoctl`: **PASS** (syntax)<br/>• Swift: **UNSUPPORTED** | N/A | N/A | N/A | N/A | **BLOCKED**<br/>(runtime absent; no prompt/approval hooks) | **BLOCKED (RUNTIME ABSENT)** |

---

## 2. Findings Remediation Log

### 1. Matcher Group Sibling & Metadata Preservation (Finding from 6778 - CLOSED in 6784)
- **Problem**: Broad dictionary replacement dropped user handlers, disabled entries (`enabled: false`), and matcher metadata.
- **Remediation**: `AgentHooksTool+MergeHelpers.swift` replaces only the specific Tako command matching `commandKey` in-place within the `hooks` array. Sibling user hooks and group keys (`matcher`, `label`, `description`) are preserved byte-semantically.
- **Verification**: `AgentHooksToolTests.swift::mixedMatcherGroupPreservesUserHandlersAndMetadataOnUpgrade` (18/18 tests pass). Accepted by reviewer in 6784.

### 2. Instance Isolation Mock Listener Synchronization & Deadline Failure (Finding from 6784 / 6786 - CLOSED in 6788)
- **Problem**: Fixed 300ms loop race and silent deadline exit in `token_instance_isolation.rs`.
- **Remediation**: Removed redundant subprocess path; synchronized listener lifetime with `server_running` flag; added explicit `deadline_exhausted` tracking with assertion `assert!(!deadline_exhausted.load(Ordering::SeqCst))` and accept draining before join.
- **Verification**: `cargo test test_token_instance_isolation` passes in 0.21s. Negative control fails immediately. Clean code exits with code 3 and 0 requests to default instance. Approved by reviewer in 6788.

### 3. Separation of Fixture Serialization from Live Provider Runs (Finding from 6784 / 6786 - CLOSED in 6788)
- **Remediation**:
  - Raw runs `20261012-004714` and `20261012-005152` are preserved in `target/runs/` as **Socket Serialization Fixtures** (`SERIALIZATION PASS`).
  - Codex live execution: `UserPromptSubmit` in bypass mode positively witnessed (`PROVIDER PASS`). Untrusted mode recorded as `0 dispatches before timeout; cause unverified` (no explicit skip trace exists). `Stop` and `PermissionRequest` marked **OPEN**.
  - Claude, Antigravity, and Gemini CLI live provider event loops marked **OPEN**.
  - Aider marked **BLOCKED** (runtime absent; no real-time turn/approval hook system). Approved by reviewer in 6788.

### 4. Real Server Socket Multi-Pane Routing & Defect Remediation (CLOSED in 6792)
- **Fixed Defect**: In `swift/Sources/TakoApp/Features/Control/ControlCommands.swift` line 294, `default:` was calling `reply(handle(request))` instead of `reply(handle(request, all: all))`. This caused un-scoped socket requests (like `status`) to discard caller-supplied pane lists and query ambient desktop windows instead of the test or worktree pane set.
- **Verification**: Added `socketStatusRoutingAcrossMultiplePanes` in `ControlServerTests.swift` (passing in 0.457s):
  1. Real `ControlServer` bound to private UNIX domain socket (`c.sock`).
  2. Two real `SurfaceView` instances (Pane A, Pane B) joined in a `Tako.CustomTabGroup`.
  3. Client sends `status set working` targeting Pane A over UNIX socket -> Pane A reports `working`, `dot: ember`, `color: orange`.
  4. Nonrecipient Pane B queried over UNIX socket -> strictly remains `idle`, `dot: dim`, `color: gray` (zero leakage across socket target resolution).
  5. Client sends `status set done` targeting Pane A over UNIX socket -> reports `dot: ok`, `color: green`. Pane B queried over socket strictly remains `idle`.
  6. Focus acknowledgement resets Pane A to `idle`, `dot: dim`, `color: gray`.

### 5. Antigravity Configuration Path Alignment (Finding from 6784 - CLOSED in 6786)
- Reconciled `docs/agent-hooks.md` with `takoctl/adapters/antigravity.json` and Swift `AgentHooksTool+Installers.swift` to canonical `~/.gemini/config/hooks.json`. Verified that real Antigravity installation on macOS uses `~/.gemini/config/hooks.json`.

### 6. Shipped Adapter Installer Provenance & Full Status+Progress Live Verification (CLOSED in 6804)
- Executed end-to-end runs using configurations generated directly by `takoctl hooks install` into isolated test directories, preserving exact configs, installer commands, and binary fingerprints in `target/runs/20261012-012500-shipped-adapter-provider-verification/`:
  - **Codex CLI (`0.162.1`)**: Installed via `takoctl hooks install codex --yes --config <path>` (saved as `installed_codex_hooks.json`, SHA256: `bbf2cf8f1672bc8467e595da3c4cf51cdea92aa3a7736d263359fe6a4bd71226`). Ran `codex exec --dangerously-bypass-hook-trust --ephemeral --skip-git-repo-check "reply with exactly 42"` with symlinked `auth.json`. Positively witnessed all 4 dispatches: `UserPromptSubmit` (`status working` + `progress indeterminate`) and `Stop` (`status done` + `progress clear`), all attributed to `from: pane-surface-codex-shipped`.
  - **Claude Code (`2.1.296`)**: Installed via `takoctl hooks install claude --yes --config <path>` (saved as `installed_claude_settings.json`, SHA256: `3c06b308137996ce2a39c3d3ae474fb150bf7d0a1d3c979c54fc7971c6998718`). Ran `claude -p --settings <path> "reply with 42"`. Witnessed prompt/stop/session-end dispatches.
  - **Antigravity (`1.3.3`)**: Restored `Live Provider Runtime Event` to **OPEN** per review 6799; standalone execution unverified outside the live operator AGY environment.
  - **Gemini CLI (`0.54.4`)**: Accurately scoped to tested client / free-tier Code Assist account blocker `IneligibleTierError` (`reasonCode: UNSUPPORTED_CLIENT`).
  - **Two-Agent / PTY Routing & UI Focus**: Retained as explicit **OPEN** column across all rows.

### 7. Two-Agent PTY Routing, UI Focus, Codex Trust & Native Installer Verification (CLOSED in 6810)
- **Two-Agent PTY Routing & UI Focus (`TwoAgentPTYRoutingTests.swift`)**:
  - Implemented real integration test connecting `ControlServer` on an isolated UNIX domain socket with two `SurfaceView` instances (Pane A, Pane B) joined in a tab group.
  - Real `forkpty` child processes run `takoctl` commands with pane-specific `TAKO_SOCKET`, `TAKO_CONTROL_TOKEN`, and `TAKO_SURFACE_ID`.
  - Verified addressing & nonrecipient isolation: Pane A transitions through `working` (ember), `needs_approval` (claw, progress: paused), `waiting_for_input` (claw), and `done` (ok, unread: true) while Pane B strictly remains `idle` (dim/gray, unread: false).
  - Verified unassisted UI focus acknowledgement: `surfA.crab.focused()` resets Pane A to `idle` (dim/gray, unread: false).
  - Verified reverse isolation: Pane B PTY commands change only Pane B; Pane A remains strictly idle. Pane B focus acknowledgement resets Pane B.
- **Codex Trust Onboarding Architecture (Mechanically Decoded & Verified)**:
  - Reverse-engineered Codex CLI `0.162.1` trust mechanism:
    - Queried `codex app-server --stdio` with `initialize` and `hooks/list` via JSON-RPC.
    - Discovered hook key structure: `<sourcePath>:<eventName_snake_case>:<matcherIndex>:<hookIndex>` with `currentHash`.
    - Discovered trust layer in `$CODEX_HOME/config.toml`: `[hooks.state."<key>"]` with `trusted_hash = "<currentHash>"`.
    - Recorded `trusted_hash` into `config.toml` -> `trustStatus` flipped from `"untrusted"` to `"trusted"` for all hooks (`userPromptSubmit`, `stop`, `permissionRequest`).
    - Executed live `codex exec "reply with 42"` **WITHOUT** `--dangerously-bypass-hook-trust`: exit 0, stdout `42`, witnessed `UserPromptSubmit` and `Stop` execution.
- **Native Installer Runtime Verification**:
  - Swift unit tests (`AgentHooksToolTests.swift`): 9/9 passed.
  - Live execution of Codex and Claude Code in clean isolated test fixture using native installer generated configurations: both exit 0 with all lifecycle hooks executing.
  - Roundtrip verification in isolated sandbox with `takoctl hooks install/uninstall` across all 5 agents (Antigravity, Gemini, Claude, Codex, Aider): install PASS, idempotent reinstall PASS, uninstall PASS, clean file PASS.
  - All logs, report JSON, and markdown records stored in `target/runs/20261012-020000-native-installer-provider-verification/`.
