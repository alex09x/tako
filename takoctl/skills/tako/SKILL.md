---
name: tako
description: Interact with the Tako terminal emulator via MCP tools or takoctl CLI to split panes, run long commands, set status badges, monitor progress, and wait for completion without scraping screen text.
---

# Tako Terminal Integration

Tako is a calmer terminal emulator built for developers and autonomous coding agents.
When running inside a Tako pane, the environment automatically provides:
- `TAKO_SURFACE_ID`: The unique ID of the pane in which the current process is running.
- `TAKO_SOCKET`: The filesystem path to Tako's Unix domain control socket.

All Tako tools and commands automatically use these variables to target the current pane or create child splits linked to it.

---

## Capabilities & Toolset

Tako exposes its capabilities through both a stdio **MCP server** (`takoctl mcp`) and the **`takoctl` CLI**:

| Action | MCP Tool | `takoctl` CLI | G1 Capability Scope |
| :--- | :--- | :--- | :--- |
| **Inspect layout** | `tako_tree` | `takoctl tree` | `read` |
| **Split pane** | `tako_split` | `takoctl split [dir] --child-of self --label <name>` | `layout` |
| **Run command** | `tako_run` | `takoctl run [--split dir] [--wait] -- PROGRAM ARGS...` | `layout`, `input` |
| **Wait for command** | `tako_wait` | `takoctl wait [--target ID] [--timeout S]` | `read` |
| **Last command info** | `tako_last` | `takoctl last [--target ID]` | `read` |
| **Search open tabs** | `tako_find` | `takoctl find <query>` | `read` |
| **Send notification** | `tako_notify` | `takoctl notify <text> [--title <title>]` | `signal` |
| **Set status badge** | `tako_status` | `takoctl status set <status> [--text <text>]` | `signal` |
| **Update progress** | `tako_progress` | `takoctl progress <0-100\|indeterminate\|error\|pause\|clear>` | `signal` |
| **Ask question** | `tako_ask` | `takoctl ask <question> [--choices C1,C2] [--confirm]` | `signal` |

---

## Core Agent Workflows

### 1. Run Long-Running Work in a Split Pane (Recommended)

Instead of running slow tasks (builds, test suites, linters, dev servers) in your main conversational terminal and scraping screen text:

1. **Set status on your own pane**:
   ```bash
   takoctl status set working --text "Running test suite in split..."
   takoctl progress indeterminate
   ```
   Or via MCP:
   - Call `tako_status(status="working", text="Running test suite in split...")`
   - Call `tako_progress(state="indeterminate")`

2. **Run the program in a child split**:
   ```bash
   takoctl run --split right --wait --timeout 300 -- cargo test
   ```
   Or via MCP:
   - Call `tako_run(program="cargo", args=["test"], split="right", wait=true, timeout="300s")`

3. **Or split explicitly and wait**:
   ```bash
   # Split right and link as child of self
   CHILD_PANE=$(takoctl split right --child-of self --label "unit-tests")

   # Send command into child pane
   takoctl send --target "$CHILD_PANE" "cargo test"

   # Wait for command completion through Tako's OSC 133 integration
   takoctl wait --target "$CHILD_PANE" --timeout 300
   ```
   Or via MCP:
   - `pane = tako_split(direction="right", child_of="self", label="unit-tests")`
   - `result = tako_wait(target=pane.id, timeout="300s")`

4. **Inspect the structured result**:
   Tako records command start, exit code, execution duration, and output cleanly without ANSI noise.
   If not using `--wait`, query the result at any time:
   ```bash
   takoctl last --target "$CHILD_PANE"
   ```
   Or via MCP:
   - `tako_last(target=pane.id)`

5. **Clear status and report**:
   ```bash
   takoctl status set done --text "Tests completed successfully"
   takoctl progress clear
   ```

---

### 2. Status Badges & Progress Indicators

Keep the developer informed of your internal lifecycle without polluting the chat log:

- **Thinking / Planning**:
  `takoctl status set working --text "Analyzing codebase"`
- **Waiting for external response**:
  `takoctl status set waiting_for_input --text "Waiting for test runner"`
- **Approval needed**:
  `takoctl status set needs_approval --text "Confirm destructive migration"`
- **Finished turn**:
  `takoctl status set done --text "Task complete"`
- **Clear status**:
  `takoctl status clear`

Progress bars appear directly in the tab and pane header:
- `takoctl progress 25` (25% complete)
- `takoctl progress indeterminate` (running with unknown duration)
- `takoctl progress pause` (paused)
- `takoctl progress error` (operation failed)
- `takoctl progress clear` (remove progress bar)

---

### 3. Interactive Prompts (`takoctl ask`)

When you need immediate user input, choice, or confirmation without relying on chat turn switches:
```bash
# Yes/No confirmation
takoctl ask "Deploy migration to staging?" --confirm

# Multiple choice
takoctl ask "Select test environment" --choices "local,staging,production"

# Free text with placeholder
takoctl ask "Enter API endpoint" --placeholder "https://api.example.com"
```
Or via MCP:
`tako_ask(message="Deploy migration to staging?", confirm=true)`

The prompt appears natively in the pane header and notification center, returning the typed response or choice to stdout.

---

### 4. Hierarchical Subagent Panes

When delegating tasks to subagents:
```bash
# Create a child pane grouped under the current agent
CHILD_ID=$(takoctl split right --child-of self --label "Researcher")

# Focus child pane if needed
takoctl focus --target "$CHILD_ID"
```
The child pane is linked in the session tree and sidebar. The parent pane's status indicator automatically summarizes the health of its child panes.
