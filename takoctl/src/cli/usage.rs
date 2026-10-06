/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

pub const USAGE: &str = "\
usage: takoctl [--json] <command> [options]

commands:
  version                 the running app and its protocol version
  tree                    windows, tabs and panes, with their directories
  send TEXT               type TEXT into the pane and press Enter (--no-enter: don't)
  type TEXT               type TEXT into the pane, no Enter
  key CHORD               press a key: enter, esc, up, f5, ctrl+c, alt+left, ...
  text                    print the pane's text (--lines N, --styled: preserve colors/attributes as ANSI SGR)
  screenshot [PATH]       capture pane as rendered PNG (--out PATH; default: stdout or file)
  tab-new                 a new tab in the pane's window (--cwd DIR, --no-select); prints its pane id
  split [DIRECTION]       split the pane: right, left, down or up (--cwd DIR, --child-of PANE,
                          --label NAME); defaults to right; prints the new pane id
  collapse [TARGET]       collapse a parent pane's subagents in tree and sidebar
  expand [TARGET]         expand a parent pane's subagents in tree and sidebar
  focus                   bring the pane forward and give it the keyboard
  title TEXT              the tab's title (empty restores the program's own)
  close                   close the pane, asking first when closing by hand would
  notify TEXT             a system notification about the pane (--title T); clicking it
                          brings the pane forward
  find TEXT               search every open tab, as Find in All Tabs does (--limit N);
                          each match with its pane and the command that printed it
  dialog                  the questions Tako has up (title, text, buttons); --press LABEL
                          presses a button (needs remote-control = on)
  ask MESSAGE             prompt user for a question, choice, confirmation or text
                          (--choice C, --choices C1,C2, --confirm, --timeout D,
                          --default V, --placeholder P, --title T)
  last                    the pane's last command: its line, directory, exit status, output
                          and ref (ID@EPOCH); in a pane run started, its program
  wait                    wait for the pane's running command (--command REF: that one;
                          --next: the next one) or run program to end; print it as last
                          (--timeout S: give up after S seconds). Not on its own pane's
                          running command, which is the wait itself.
  run -- PROGRAM ARGS...  run PROGRAM, as given -- no shell -- in a new tab (--split
                          right|down|left|up: a split; --cwd DIR); prints the pane id, or
                          with --wait its exit status and output (--timeout S)
  status [get]            print the pane's status (status, text, TTL)
  status set STATUS       set the pane's explicit status (--text T, --ttl D)
  status clear            clear the pane's explicit status
  progress [STATE|0-100]  get or set progress: 0-100, indeterminate, error, pause, clear
  events                  stream terminal events as ndjson (--pane ID, --tab ID,
                          --workspace NAME, --type TYPES, --cursor N)
  history [QUERY]         search command history across sessions (--query Q, --limit N)
  triggers [list]         list active passive regex triggers
  triggers add PATTERN    register a passive trigger (--action highlight|notify|both,
                          --color C, --style background|underline|box|bold, --title T, --all-focus)
  triggers remove ID      remove a trigger by ID
  triggers clear          clear dynamically registered triggers
  workspace [list]        list all workspaces and tab counts
  workspace current       show the active workspace
  workspace switch NAME   switch to workspace NAME (^⌥] / ^⌥[)
  workspace create NAME   create a new workspace (--root DIR, --color C, --icon I)
  workspace delete NAME   delete workspace NAME (tabs move to Default)
  workspace assign [TAB]  assign a tab to a workspace (--workspace NAME)
  layout apply FILE       apply declarative layout from FILE (--approve: trust and run programs)
  layout save FILE        save current window's layout to FILE
  layout approve FILE     trust programs in layout FILE
  layout status FILE      show trust status of layout FILE (trusted, untrusted, changed)
  action [list] [PATH]    list project-local actions for current pane or directory
  action run ID           run project action ID (--approve: trust and run action)
  action approve [PATH]   trust project actions file
  action status [PATH]    show trust status of project actions file
  hooks list              list supported coding-agent hook adapters and their install status
  hooks status [AGENT]    show hook installation status for AGENT or all agents
  hooks install AGENT     install Tako lifecycle hooks into AGENT's configuration
                          (--yes: skip confirmation; --diff-only: only print diff; --config PATH)
  hooks uninstall AGENT   remove Tako lifecycle hooks from AGENT's configuration
                          (--yes: skip confirmation; --diff-only: only print diff; --config PATH)
  skills [list]           list supported coding agents and skill installation status
  skills status [AGENT]   show skill installation status for AGENT or all agents
  skills install AGENT    install Tako skill instructions into AGENT's directory
                          (--yes: skip confirmation; --diff-only: only print diff; --skill-path PATH)
  skills uninstall AGENT  remove Tako skill instructions from AGENT's directory
                          (--yes: skip confirmation; --diff-only: only print diff; --skill-path PATH)
  mcp                     run stdio MCP server for agent integration (--capabilities SCOPES)
  resume set -- ARGS...   record how to resume what runs in a pane (--cwd DIR)
  resume show [TARGET]    show recorded resume session and auto-run approval status
  resume clear [TARGET]   clear recorded resume session
  resume run [TARGET]     manually execute recorded resume command
  resume approve [TARGET] approve command prefix for directory (--prefix P, --cwd DIR)
  input lock              lock the pane against accidental keyboard typing (--owner NAME)
  input unlock            unlock the pane for keyboard typing
  input takeover          take over keyboard input from an agent
  input handback          hand back input control to the agent (--owner NAME)
  input status            show input lock state, owner, and last activity attribution
  input log               show automated input activity log for the pane
  input allow-automation  allow external automation to type into this pane
  input disallow-automation disallow external automation from typing into this pane
  input confirm-automation allow automation to type once into this pane
  activity [TARGET]       show automated activity log for the pane (--export FILE, --clear)
  broadcast [start]       broadcast keyboard input across selected panes (--panes P1,P2... or all in tab)
  broadcast stop          stop broadcasting input
  broadcast status        show current broadcast status and participating panes
  session export FILE     export window or workspace session to FILE (--window ID)
  session import FILE     import session from FILE (untrusted: dropped escapes, no auto-run)
  session info FILE       inspect session FILE format version and summary
  overlay open FILE       open an artifact/document overlay in pane (--split right|down|left|up, --type html|markdown|image|pdf|diff)
  overlay close           close active overlay in target pane
  overlay status          show overlay state for target pane
  overlay reload          reload document in active overlay
  review open [PATH]      open diff review pane for worktree (--base BRANCH, --target-pane ID)
  review close            close active diff review pane
  review status           show review session status and pending comments count
  review files            list changed files in review session
  review diff [FILE]      show unified diff of all files or specific FILE
  review comment [ACTION] manage review comments (add, list, remove, clear; --file FILE, --line N)
  review send             send collected review comments as feedback to target pane
  grant request [NAME]    request an authorization grant from user (--client NAME, --scope SCOPES, --desc DESC)
  grant create            create a scoped authorization grant (--client NAME, --scope SCOPES, --desc DESC)
  grant revoke TOKEN      revoke an authorization grant
  grant list              list active authorization grants
  diagnose [PATH]         export self-contained diagnostics bundle with secrets/paths redacted
                          (--out PATH, --stdout, --include-terminal, --benchmark)

options:
  --target ID|PREFIX|self|active   the pane (default: this pane, or the active one)
  --window ID             session export: target specific window ID
  --panes P1,P2,...       broadcast: comma-separated list of target panes
  --client NAME           client name for identity and attribution (send, type, key; default: takoctl)
  --owner NAME            agent name for input lock / handback (default: agent)
  --child-of TARGET       split: child pane linked to parent (e.g. self or ID)
  --label NAME            split: label for child pane (e.g. subagent name)
  --approve               layout apply: trust layout file and allow running its programs
  --prefix PREFIX         resume approve: command prefix to approve for auto-run
  --choice CHOICE         ask: add a choice (can be repeated)
  --choices C1,C2,...     ask: comma-separated list of choices
  --confirm               ask: prompt for confirmation (Yes/No)
  --confirm-text TEXT     ask: custom confirmation button text
  --cancel-text TEXT      ask: custom cancel button text
  --placeholder TEXT      ask: placeholder text for text prompt
  --default VALUE         ask: default value on timeout
  --pane ID               events: filter by pane ID
  --tab ID                events: filter by tab ID
  --workspace NAME        events, workspace assign: filter or target workspace name
  --root DIR              workspace create: root directory for new tabs
  --color COLOR           workspace create: workspace color tag
  --icon ICON             workspace create: workspace icon name
  --type TYPES            events: filter by comma-separated event types
  --cursor N              events: resume streaming from cursor N
  --lines N               text, last, wait, run --wait: at most the last N lines of output
  --styled                text: include ANSI SGR color/styling escape codes
  --out PATH              screenshot: output PNG file path
  --export FILE           activity: export activity log to FILE
  --clear                 activity: clear activity log for target pane
  --file FILE             review: target file for diff or comment
  --line N                review: line number for inline comment
  --target-pane ID        review: destination pane for batched feedback
  --text TEXT             status text (truncated to 128 characters)
  --ttl DURATION          status time-to-live (e.g. 10m, 30s, 1h, 500ms)
  --timeout DURATION      ask, wait, run --wait: timeout (e.g. 30s, 1m, 10)
  --yes, -y               skip confirmation prompt for hooks install/uninstall
  --diff-only             print proposed diff without writing files
  --token, --auth-token TOKEN authorization grant token (default: $TAKO_CONTROL_TOKEN or $TAKO_AUTH_TOKEN)
  --scope, --scopes SCOPES comma-separated capability scopes (read,input,layout,signal,overlay,approval)
  --description, --desc DESC description of grant or client purpose
  --capabilities SCOPES   mcp: comma-separated capability scopes (read,layout,signal,input,overlay,approval; default: read,layout,signal,input)
  --skill-path PATH       skills install/uninstall: override target skill markdown path
  --config PATH           override agent configuration file path
  --json                  print the app's raw JSON answer
  --socket PATH           the control socket (default: $TAKO_SOCKET, or the app's)
  --bundle-id ID          find the socket of this build of Tako (default com.tako-core.terminal)
";
