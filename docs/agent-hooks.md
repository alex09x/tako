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
   - Hooks: `UserPromptSubmit`, `PreToolUse`, `Notification`, `Stop`, `SessionEnd`.
2. **Gemini CLI / Antigravity** (`gemini`, aliases: `antigravity`, `agy`)
   - Configuration file: `~/.gemini/settings.json`
   - Hooks: `on_prompt`, `on_approval`, `on_wait_input`, `on_done`, `on_session_end`.
3. **Codex CLI** (`codex`, alias: `opencode`)
   - Configuration file: `~/.codex/config.json`
   - Hooks: `prompt_submit`, `approval_requested`, `waiting_input`, `turn_done`, `session_end`.
4. **Aider** (`aider`)
   - Configuration file: `~/.aider.conf.yml`
   - Hooks: `notifications-command`.

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
