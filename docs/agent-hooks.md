# Tako Agent Status (`OSC 7501`) & Legacy Hook Adapters

Tako coordinates coding agents and human developers seamlessly within a rich terminal interface. Instead of scraping scrollback buffers or installing fragile per-agent shell scripts where native support exists, Tako implements **built-in `OSC 7501` Program Status (revision 0.4)** in its Rust/C/Swift terminal engine alongside an explicit `takoctl` CLI contract for custom scripts and older tools.

Modern coding agents (**Claude Code**, **Codex CLI**, **Antigravity**, **Qwen Code**, and **Muse Code**) emit structured status, progress, hierarchy (`id` / `parent/child`), and blocked prompts directly over the PTY stream via `OSC 7501` — requiring **zero status hook scripts** in user configuration files. For those five agents, `takoctl hooks install` (or Setup Wizard **Connect**) and `takoctl hooks uninstall` both idempotently clean up any legacy Tako-owned status hooks and ownership receipts while preserving user, Prod, Rex, and third-party hooks; neither writes a status hook. Only `hooks install` also installs the agent skill (`SKILL.md`), and only into the agent's default location: with `--config` or `--diff-only` it installs no skill. `hooks uninstall` leaves the skill in place. To manage the skill on its own, use `takoctl skills install <agent>` (with `--skill-path` for another location) and `takoctl skills uninstall <agent>`. Legacy hook installation remains supported for **Gemini CLI** (`gemini`) and **Aider** (`aider`).

---

## 1. Environment Provided by Tako

When Tako launches a terminal pane or tab, it injects two environment variables into the process tree:

| Variable | Description |
| :--- | :--- |
| `TAKO_SOCKET` | Path to the active Tako UNIX domain control socket (e.g. `/var/folders/.../tako.sock`). |
| `TAKO_SURFACE_ID` | UUID string identifying the specific pane/surface running the process. |

When `takoctl` runs from inside a pane (e.g. from an agent skill or custom script), it automatically uses `$TAKO_SOCKET` and `$TAKO_SURFACE_ID` to target the calling pane without requiring `--target` or `--socket` arguments.

---

## 2. Native `OSC 7501` Agents vs. Legacy Hook Adapters

### A. Native `OSC 7501` Agents (Zero Status Hooks Installed)

| Agent | Adapter ID | Minimum Native `OSC 7501` Support | Legacy Config Cleaned on Migration | Skill Path |
| :--- | :--- | :--- | :--- | :--- |
| **Claude Code** | `claude` | Native `OSC 7501` releases (capability probe `OSC 7501;?` + `state=working/blocked/done/error/clear`) | `~/.claude/settings.json` | `~/.claude/skills/tako/SKILL.md` |
| **Codex CLI** | `codex` | Native `OSC 7501` releases | `$CODEX_HOME/hooks.json` (`~/.codex/hooks.json`) | `$CODEX_HOME/skills/tako/SKILL.md` |
| **Antigravity** | `antigravity` | Native `OSC 7501` releases | `~/.gemini/config/hooks.json` (`tako-status` section only) | `~/.gemini/antigravity/skills/tako/SKILL.md` |
| **Qwen Code** | `qwen` | Qwen Code `>= 0.26.9` / native `OSC 7501` builds | `~/.qwen/settings.json` + `.tako-qwen-receipt` | `~/.qwen/skills/tako/SKILL.md` |
| **Muse Code** | `muse` | Muse `>= 1.4.14` / native `OSC 7501` builds | `$XDG_CONFIG_HOME/muse/settings.json` (`~/.config/muse/settings.json`), `tako-managed-hooks.json`, `.tako-muse-receipt` | `<Muse config dir>/skills/tako/SKILL.md` |

- **No status hooks written**: Neither `takoctl hooks install <agent>` nor Setup Wizard writes hook entries for these five agents. Clean directories remain untouched (no empty `hooks.json` or `settings.json` is created).
- **Conversation-ID limitation**: Because status hooks are no longer installed for Claude Code and Codex CLI, hook-payload `session_id` capture is not populated automatically for hookless sessions; `File → Agent Conversations` displays only conversation IDs explicitly observed via `takoctl` or prior recorded sessions.

### B. Retained Legacy Hook Adapters (`gemini` & `aider`)

1. **Gemini CLI** (`gemini`)
   - Configuration file: `~/.gemini/settings.json`
   - Hook Schema: Nested matcher groups (`BeforeAgent` → `working`, `AfterAgent` → `idle`).
2. **Aider** (`aider`)
   - Configuration file: `~/.aider.conf.yml` (`notifications-command`).

---

## 3. Manual / Custom Script `takoctl` Lifecycle Contract

Custom scripts, CI tasks, and legacy hook adapters (`gemini`, `aider`) can drive Tako explicitly via `takoctl`:

1. **Pane Status** (`takoctl status set <status> [--text <text>] [--ttl <duration>]` / `takoctl status clear`)
2. **Progress Indicator** (`takoctl progress <0-100|indeterminate|pause|error|clear>`)
3. **Notifications** (`takoctl notify <text> [--title <title>]`)

| Lifecycle Event | `takoctl` Invocations | Visual & System Effect |
| :--- | :--- | :--- |
| **`prompt_submitted`** | `takoctl status set working --text "Thinking..."`<br/>`takoctl progress indeterminate` | Pane and tab display `working` status and indeterminate progress animation. |
| **`approval_needed`** | `takoctl status set needs_approval --text "Approval requested"`<br/>`takoctl progress pause` | Attention ring surrounds unfocused pane; dock badge updates; desktop notification posted. |
| **`waiting_for_input`** | `takoctl status set waiting_for_input --text "Waiting for input"`<br/>`takoctl progress clear` | Attention navigation targets pane; tab badge shows unread/waiting state. |
| **`done`** | `takoctl status set done --text "Task complete"`<br/>`takoctl progress clear` | Pane marks task complete; unfocused panes stay unread until viewed. |
| **`session_ended`** | `takoctl status clear`<br/>`takoctl progress clear` | Resets explicit status and clears progress indicators. |

---

## 4. Safe Migration, Closed-Set Ownership, and Confirmation

1. **Closed-Set Ownership**: Migration removes **only** exact historical Tako-generated dispatcher invocations (`tako-hook`, bundled `PATH='.../MacOS':"$PATH" /usr/bin/python3 '.../tako-hook.py'`, exact receipt-recorded commands) and exact literal historical `takoctl` templates. User-edited shell commands, `echo` commands, Prod hooks (`prod-code-guard`, `prod-raw-agent-events`), and Rex hooks are never modified.
2. **Unified Diff & Interactive Confirmation**: `takoctl hooks install <agent>` and `takoctl hooks uninstall <agent>` display a unified diff and require `[y/N]` confirmation unless `--yes` is passed. Declining (`n`) or running `--diff-only` leaves configuration files, sidecar receipts, and `.tako-bak` backups untouched.
3. **Symlink & Corrupt-JSON Refusal**: Both `takoctl` and `SetupAgentService` refuse symlinks and malformed JSON containers without clobbering user files.

```bash
# Inspect status across all agents (shows "native (7501)" vs "legacy hooks" vs "installed")
takoctl hooks list
takoctl hooks status

# Migrate away legacy status hooks for a native OSC 7501 agent and install its skill
takoctl hooks uninstall claude --yes
takoctl skills install claude --yes

# Install legacy hooks for Gemini CLI
takoctl hooks install gemini --yes
```

---

## 5. Engine & SDK `OSC 7501` Host Contract (Rust, C ABI, Swift)

Hosts embedding `tako-core` (`TerminalHeadlessSession`, `TakoTerminalNSView`, `TakoTerminalView`, or C `prod_vt_*` via `include/prod_vt_program_status.h`) share one parser/checkpoint state machine:

- **Capability Probe (`OSC 7501 ; ? ST` → `OSC 7501 ; 1 : v=1 ST`)**: Enabled on the single active PTY owner; disable on passive/read-only followers via `prod_vt_set_program_status_probe_reply_enabled(vt, 0)` / `programStatusProbeReplyEnabled = false` so capability replies are never duplicated while `DA1`/`DSR`/`CPR` and status tracking remain active.
- **Consume-Once Replies & Sticky Overflow Loss**: `prod_vt_drain_classified_replies()` and legacy `prod_vt_drain_responses()` pop consume-once from the same bounded FIFO `ResponseQueue` (`256` replies / `64 KiB`). Legacy `prod_vt_drain_responses()` preserves sticky overflow counts; legacy callers **must** check `prod_vt_take_reply_overflow_count()` (or use `prod_vt_drain_classified_replies()`, which returns `PROD_VT_ERR_REPLY_OVERFLOW` with `overflow_dropped_count`).
- **Ordered Delivery & Checkpoint v7 (`PS75`)**: Status updates carry their point-in-time `ProgramStatusSnapshot` in parser FIFO order across async feeds, synchronous feeds, and lifecycle transitions (`processExited`, `interrupted`, `acknowledged`). Checkpoint v7 persists active records without replaying historical transitions or capability replies on restore, and strictly validates restored `PS75` invariants.
