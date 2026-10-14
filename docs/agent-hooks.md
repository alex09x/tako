# Tako Agent Hook Adapters & Vendor-Neutral Contract

Tako coordinates coding agents and human developers seamlessly within a rich terminal interface. Unlike legacy multiplexers or terminals that attempt to guess what an agent is doing by scraping scrollback buffers or parsing ANSI strings, Tako uses an **explicit, vendor-neutral lifecycle contract**.

Agent tools (such as Claude Code, Gemini CLI / Antigravity, Codex, and Aider) run hook commands on lifecycle transitions. These hooks invoke `takoctl` to update pane status, display progress indicators, and post system notifications.

---

## 1. Environment Provided by Tako

When Tako launches a terminal pane or tab, it injects two environment variables into the process tree:

| Variable | Description |
| :--- | :--- |
| `TAKO_SOCKET` | Path to the active Tako UNIX domain control socket (e.g. `/var/folders/.../tako.sock`). |
| `TAKO_SURFACE_ID` | UUID string identifying the specific pane/surface running the process. |

When `takoctl` runs from inside a pane (e.g. within an agent hook script or command), it automatically uses `$TAKO_SOCKET` and `$TAKO_SURFACE_ID` to target the calling pane without requiring `--target` or `--socket` arguments.

---

## 2. Vendor-Neutral Lifecycle Event Contract

Agent lifecycle events map directly to `takoctl` invocations across three primary capabilities:

1. **Pane Status** (`takoctl status set <status> [--text <text>] [--ttl <duration>]` / `takoctl status clear`)
2. **Progress Indicator** (`takoctl progress <0-100|indeterminate|pause|error|clear>`)
3. **Notifications** (`takoctl notify <text> [--title <title>]`)

### Standard Event Mapping Table

| Lifecycle Event | `takoctl` Invocations | Visual & System Effect |
| :--- | :--- | :--- |
| **`prompt_submitted` / `turn_start`** | `takoctl status set working --text "Thinking..."`<br/>`takoctl progress indeterminate` | Pane and tab display `working` status and amber/ember indeterminate progress animation. |
| **`permission_requested` / `approval_needed`** | `takoctl status set needs_approval --text "Approval requested"`<br/>`takoctl notify "Approval required" --title "<Agent> Approval"`<br/>`takoctl progress pause` | Ember attention ring surrounds unfocused pane; dock badge updates; desktop notification posted; progress turns orange (`pause`). |
| **`waiting_for_input` / `user_prompt`** | `takoctl status set waiting_for_input --text "Waiting for input"`<br/>`takoctl notify "Waiting for your input" --title "<Agent>"`<br/>`takoctl progress clear` | Attention navigation targets pane; tab badge shows unread/waiting state; desktop notification posted. |
| **`turn_finished` / `done`** | `takoctl status set done --text "Task complete"`<br/>`takoctl notify "Task complete" --title "<Agent>"`<br/>`takoctl progress clear` | Pane marks task complete; if unfocused, status persists as unread until pane is viewed. |
| **`subagent_started`** | `takoctl status set working --text "Subagent: <name>"`<br/>`takoctl progress indeterminate` | Status updates to reflect background subagent activity. |
| **`subagent_finished`** | `takoctl status set working --text "Working..."` | Status reverts to primary agent state. |
| **`session_ended` / `exit`** | `takoctl status clear`<br/>`takoctl progress clear` | Resets pane status and clears all progress indicators. |
| **`error` / `crash`** | `takoctl status set error --text "<error message>"`<br/>`takoctl progress error` | Pane indicates red error state; attention ring raised. |

---

## 3. Supported Agent Tools & Adapter Data Files

Adapters are declarative data files residing in `takoctl/adapters/<agent>.json` (or embedded directly in the `takoctl` binary). They never patch agent binaries or inject closed-source extensions.

### Supported Tools

1. **Claude Code** (`claude`)
   - Configuration file: `~/.claude/settings.json`
   - Hook Schema: Nested matcher groups (`[{"matcher": "", "hooks": [{"type": "command", "command": "...", "timeout": 5}]}]`)
   - Events configured: `UserPromptSubmit` (working/progress), `Stop` (done), `PermissionRequest` (needs_approval), `Elicitation` (waiting_for_input).

2. **Antigravity** (`antigravity`)
   - Configuration file: `~/.gemini/config/hooks.json`
   - Hook Schema: Direct command handler arrays under hook events
   - Events configured: `PreInvocation` (working/progress), `Stop` (done).

3. **Gemini CLI** (`gemini`)
   - Configuration file: `~/.gemini/settings.json`
   - Hook Schema: Nested matcher groups (`[{"matcher": "", "hooks": [{"type": "command", "command": "..."}]}]`)
   - Events configured: `BeforeAgent` (working), `AfterAgent` (idle).

4. **Codex** (`codex`)
   - Configuration file: `$CODEX_HOME/hooks.json` (defaults to `~/.codex/hooks.json`)
   - Hook Schema: Nested matcher groups (`[{"matcher": "", "hooks": [{"type": "command", "command": "...", "timeout": 5}]}]`)
   - Events configured: `UserPromptSubmit` (working), `Stop` (done), `PermissionRequest` (needs_approval).
   - Trust Model: Codex validates hook commands against `trusted_hash` entries in `$CODEX_HOME/config.toml` under `[hooks.state."..."]`. In interactive mode, untrusted hooks prompt for user confirmation and record the hash; in non-interactive mode (`codex exec`), untrusted hooks are skipped unless `--dangerously-bypass-hook-trust` is supplied in isolated testing environments.

5. **Aider** (`aider`)
   - Configuration file: `~/.aider.conf.yml`
   - Hook Key: `notifications-command`.

---

## 4. Safe Installation and Byte-Identical Uninstallation

Tako adheres to strict safety guarantees for managing third-party tool configurations:

1. **Unified Diff Inspection**: Running `takoctl hooks install <agent>` displays a full unified diff of proposed changes before touching any files.
2. **Interactive Confirmation**: Changes are only written after the user confirms (`[y/N]`), unless `--yes` is explicitly passed.
3. **Byte-Identical Reversibility**: `takoctl hooks uninstall <agent>` removes exactly what was installed. When no unrelated manual edits were made after installation, the configuration is restored **byte-identical** to its pre-installation state (or deleted if created anew).
4. **Dry-Run Inspection**: `--diff-only` prints the diff and exits with code 0 without modifying the disk.

---

## 5. CLI Reference

```bash
# List supported agents and their hook installation status
takoctl hooks list

# Inspect detailed status for an agent or all agents
takoctl hooks status
takoctl hooks status claude

# Preview proposed configuration diff without installing
takoctl hooks install claude --diff-only

# Install hooks (prompts for confirmation)
takoctl hooks install claude

# Install hooks non-interactively
takoctl hooks install gemini --yes

# Uninstall hooks (restores byte-identical configuration)
takoctl hooks uninstall claude --yes

# Specify a custom config file path (e.g. for testing or isolated environments)
takoctl hooks install claude --config ./test-settings.json --yes
```

## 6. Dispatcher recipient and credential isolation

The source for an existing `tako-hook` installation is `scripts/tako-hook.py`.
`python3 scripts/install-tako-hook.py` updates only that executable atomically,
retaining a private backup. It does not edit provider configuration or hook trust.

The dispatcher requires an inherited absolute `TAKO_SOCKET`, a UUID
`TAKO_SURFACE_ID`, and a nonempty caller grant (`TAKO_CONTROL_TOKEN`, or
`TAKO_AUTH_TOKEN` when the primary variable is absent). It preserves those values
when invoking `takoctl`; a denied request is not retried with a different grant.
All notifications and status/progress commands identify the same recipient.

Detached Codex events resolve an explicitly enrolled Session ID from their hook
JSON payload. `scripts/bind-tako-hook.py` enrolls a specifically selected pane and
process with a signal-only grant stored in macOS Keychain. A direct provider
context is refreshed only when its inherited grant matches the exact retired
grant enrolled for that surface/socket. Unregistered session IDs are no-ops;
process names, shared directories and the active tab are never recipient
identities. Tako restores enrolled signal grants across application restarts.
Revoking a grant removes its persisted bindings as well. No provider trust hash
is seeded or modified by this enrollment.

Fresh terminal contexts enroll a signal-only lifecycle grant using their already
authorized parent credential. A restricted caller cannot create a broader grant.
The optional `--codex-wrapper` installer installs `tako-codex` and a Fish
autoload function: inside Tako, new Codex sessions use the supported
`--no-daemon` flag so hooks retain their PTY context. Outside Tako, arguments are
passed unchanged to the original vendor launcher. The vendor-managed launcher
and existing user Fish functions are preserved.

CLI JSON hook updates preserve sibling handlers and matcher metadata. Only exact
current template commands or simple, recognized `tako-hook <agent> <event>`
commands are replaced/removed. Unknown custom shell commands remain untouched;
an intentionally disabled recognized hook makes installation fail rather than
silently enabling it. Malformed existing event containers are rejected.
