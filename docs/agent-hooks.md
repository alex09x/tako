# Tako Agent Hook Adapters & Vendor-Neutral Contract

Tako coordinates coding agents and human developers seamlessly within a rich terminal interface. Unlike legacy multiplexers or terminals that attempt to guess what an agent is doing by scraping scrollback buffers or parsing ANSI strings, Tako uses **built-in `OSC 7501` Program Status** (revision 0.4) alongside an explicit `takoctl` CLI contract for custom scripts and older tools.

Modern coding agents (**Claude Code**, **Codex CLI**, **Antigravity**, **Qwen Code**, and **Muse Code**) emit structured status, progress, and blocked prompts directly over the terminal stream via `OSC 7501` — requiring **zero status hook scripts** in user configuration files. Running `takoctl hooks install` or `takoctl hooks uninstall` for those five agents idempotently cleans up any legacy Tako-owned status hooks while preserving user, Prod, and third-party hooks. Legacy hook installation remains supported for **Gemini CLI** (`gemini`) and **Aider** (`aider`).

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

6. **Qwen Code** (`qwen`, verified with 0.26.9)
   - Configuration: `~/.qwen/settings.json`; skill: `~/.qwen/skills/tako/SKILL.md`.
   - Native command hooks report session, prompt, permission/question, tool completion and turn completion/failure events.
   - Events with a subagent `agent_id` do not overwrite the root terminal's status.

7. **Muse** (`muse`, verified with 1.4.14-R7309.1)
   - Configuration: `$XDG_CONFIG_HOME/muse/settings.json`, defaulting to `~/.config/muse/settings.json`.
   - Uses `managed_hooks_path` and a managed hook file, preserving existing user hooks and paths. Native plugins cannot inherit the pane binding.
   - Adds only `TAKO_SURFACE_ID` and `TAKO_SOCKET` to `managed_hooks_env_vars`; existing entries remain intact. Credentials are not added.
   - Hooks with different `MUSE_SESSION_ID` and `MUSE_THREAD_ID` belong to internal subagents and cannot change the root pane's status.
   - Skill: `<Muse config directory>/skills/tako/SKILL.md`.

The app seals `tako-hook.py` in its Resources; hooks installed by its CLI invoke that dispatcher with `/usr/bin/python3` and the matching bundled CLI even if the provider replaces PATH. For a standalone CLI installation, install/update `tako-hook` first using `python3 scripts/install-tako-hook.py`. The dispatcher validates the pane UUID and socket; these adapters deliberately have no direct CLI fallback. Restart the agent session to load changed hooks; installing them does not restart an existing agent or interrupt its work.

```sh
takoctl hooks install qwen --yes
takoctl skills install qwen --yes
takoctl hooks install muse --yes
takoctl skills install muse --yes
takoctl hooks status muse --json
```

Recognition of the foreground command supplies its name and interactive/batch classification. Working, approval and completion badges come from lifecycle hooks, independently of terminal output.

---

## 4. Safe Installation and Byte-Identical Uninstallation

Tako adheres to strict safety guarantees for managing third-party tool configurations:

1. **Unified Diff Inspection**: Running `takoctl hooks install <agent>` displays a full unified diff of proposed changes before touching any files.
2. **Interactive Confirmation**: Changes are only written after the user confirms (`[y/N]`), unless `--yes` is explicitly passed.
3. **Reversibility**: Existing adapters restore their byte-identical backup when possible. Qwen and Muse remove owned hooks while preserving current user settings and hook siblings; JSON formatting may change. Muse tracks additions in a private receipt so uninstall removes only the environment entries and pointers that Tako added. Original backups remain available.
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

The dispatcher requires an inherited absolute `TAKO_SOCKET` and a UUID
`TAKO_SURFACE_ID`. It preserves those values when invoking `takoctl`. There is no
grant, token or scope: Tako is local and anything running as the user may drive it.
All notifications and status/progress commands identify the same recipient; process
names, shared directories and the active tab are never recipient identities.

For Claude and Codex events that include a valid `session_id`, the dispatcher
also records the observed ID against that explicit pane. File → Agent
Conversations shows the candidates and can copy a resume command. It does not
run the command: multiple agents may have used the same pane, and an observed
conversation may still be running. Only events received after both Tako and
the installed dispatcher have been updated can be recorded; missing historical
IDs cannot be inferred reliably. Conversation IDs are stored privately, without
prompts or transcript contents, and are not recorded during Secure Input.

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
