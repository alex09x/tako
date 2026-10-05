/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

//! `takoctl`: drive a running Tako from a script.
//!
//! One request per run: a JSON line to the app's control socket, one JSON
//! line back. Inside a Tako pane the socket and the pane's own id come from
//! `TAKO_SOCKET` and `TAKO_SURFACE_ID`; outside one the socket is found the
//! way the app names it, from its bundle id.
//!
//! Exit status: 0 when the app answered `ok`, 1 when it refused (the error
//! is printed), 2 for a usage error, 3 when no Tako took the request, 4 when
//! the request was delivered but no answer came: it may have been carried
//! out, and is never retried.

mod hooks;
mod mcp;
mod skills;
mod socket;

use std::process::ExitCode;

use serde_json::{json, Map, Value};

const USAGE: &str = "\
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

options:
  --target ID|PREFIX|self|active   the pane (default: this pane, or the active one)
  --window ID             session export: target specific window ID
  --panes P1,P2,...       broadcast: comma-separated list of target panes
  --client NAME           client name for automated input attribution (send, type, key; default: takoctl)
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
  --text TEXT             status text (truncated to 128 characters)
  --ttl DURATION          status time-to-live (e.g. 10m, 30s, 1h, 500ms)
  --timeout DURATION      ask, wait, run --wait: timeout (e.g. 30s, 1m, 10)
  --yes, -y               skip confirmation prompt for hooks install/uninstall
  --diff-only             print proposed diff without writing files
  --capabilities SCOPES   mcp: comma-separated capability scopes (read,layout,signal,input,overlay; default: read,layout,signal,input)
  --skill-path PATH       skills install/uninstall: override target skill markdown path
  --config PATH           override agent configuration file path
  --json                  print the app's raw JSON answer
  --socket PATH           the control socket (default: $TAKO_SOCKET, or the app's)
  --bundle-id ID          find the socket of this build of Tako (default com.tako-core.terminal)
";

struct Options {
    cmd: String,
    args: Map<String, Value>,
    json: bool,
    socket: Option<String>,
    bundle_id: String,
}

fn parse(argv: &[String]) -> Result<Options, String> {
    let mut cmd = None;
    let mut args = Map::new();
    let mut json = false;
    let mut socket = None;
    let mut bundle_id =
        std::env::var("TAKO_BUNDLE_ID").unwrap_or_else(|_| "com.tako-core.terminal".into());
    let mut positional: Vec<String> = Vec::new();
    let mut dashdash = false;
    let mut it = argv.iter();
    while let Some(arg) = it.next() {
        let mut value = |name: &str| {
            it.next()
                .cloned()
                .ok_or_else(|| format!("{name} needs a value"))
        };
        match arg.as_str() {
            "--json" => json = true,
            "--target" => {
                args.insert("target".into(), Value::String(value("--target")?));
            }
            "--socket" => socket = Some(value("--socket")?),
            "--bundle-id" => bundle_id = value("--bundle-id")?,
            "--no-enter" => {
                args.insert("enter".into(), Value::Bool(false));
            }
            "--lines" => {
                let n: u64 = value("--lines")?
                    .parse()
                    .map_err(|_| "--lines needs a number".to_string())?;
                args.insert("lines".into(), Value::from(n));
            }
            "--" => {
                positional.extend(it.by_ref().cloned());
                dashdash = true;
            }
            "--command" => {
                args.insert("command".into(), Value::String(value("--command")?));
            }
            "--cwd" => {
                args.insert("cwd".into(), Value::String(value("--cwd")?));
            }
            "--no-select" => {
                args.insert("select".into(), Value::Bool(false));
            }
            "--next" => {
                args.insert("next".into(), Value::Bool(true));
            }
            "--wait" => {
                args.insert("wait".into(), Value::Bool(true));
            }
            "--title" => {
                args.insert("title".into(), Value::String(value("--title")?));
            }
            "--limit" => {
                let n: u64 = value("--limit")?
                    .parse()
                    .map_err(|_| "--limit needs a number".to_string())?;
                args.insert("limit".into(), Value::from(n));
            }
            "--press" => {
                args.insert("press".into(), Value::String(value("--press")?));
            }
            "--split" => {
                args.insert("split".into(), Value::String(value("--split")?));
            }
            "--child-of" => {
                args.insert("child_of".into(), Value::String(value("--child-of")?));
            }
            "--label" => {
                args.insert("label".into(), Value::String(value("--label")?));
            }
            "--choice" => {
                let val = value("--choice")?;
                let entry = args
                    .entry("choices")
                    .or_insert_with(|| Value::Array(Vec::new()));
                if let Some(arr) = entry.as_array_mut() {
                    arr.push(Value::String(val));
                }
            }
            "--choices" => {
                let val = value("--choices")?;
                let entry = args
                    .entry("choices")
                    .or_insert_with(|| Value::Array(Vec::new()));
                if let Some(arr) = entry.as_array_mut() {
                    for c in val.split(',').map(|s| s.trim()).filter(|s| !s.is_empty()) {
                        arr.push(Value::String(c.to_string()));
                    }
                }
            }
            "--confirm" => {
                args.insert("confirm".into(), Value::Bool(true));
            }
            "--confirm-text" => {
                args.insert(
                    "confirm_text".into(),
                    Value::String(value("--confirm-text")?),
                );
            }
            "--cancel-text" => {
                args.insert("cancel_text".into(), Value::String(value("--cancel-text")?));
            }
            "--placeholder" => {
                args.insert("placeholder".into(), Value::String(value("--placeholder")?));
            }
            "--default" => {
                args.insert("default".into(), Value::String(value("--default")?));
            }
            "--text" => {
                if let Some(next_tok) = it.clone().next() {
                    if !next_tok.starts_with('-') {
                        let val = it.next().unwrap().clone();
                        args.insert("text".into(), Value::String(val));
                    } else {
                        args.insert("text_mode".into(), Value::Bool(true));
                    }
                } else {
                    args.insert("text_mode".into(), Value::Bool(true));
                }
            }
            "--ttl" => {
                let s = value("--ttl")?;
                let seconds = parse_duration(&s).map_err(|e| format!("--ttl {e}"))?;
                args.insert("ttl".into(), Value::from(seconds));
            }
            "--timeout" => {
                let s = value("--timeout")?;
                let seconds = parse_duration(&s).map_err(|e| format!("--timeout {e}"))?;
                if !(seconds.is_finite() && (0.0..=7.0 * 24.0 * 3600.0).contains(&seconds)) {
                    return Err("--timeout needs seconds, at most a week".into());
                }
                args.insert("timeout".into(), Value::from(seconds));
            }
            "--yes" | "-y" => {
                args.insert("yes".into(), Value::Bool(true));
            }
            "--approve" => {
                args.insert("approve".into(), Value::Bool(true));
            }
            "--diff-only" => {
                args.insert("diff_only".into(), Value::Bool(true));
            }
            "--capabilities" => {
                args.insert("capabilities".into(), Value::String(value("--capabilities")?));
            }
            "--skill-path" => {
                args.insert("skill_path".into(), Value::String(value("--skill-path")?));
            }
            "--config" => {
                args.insert("config".into(), Value::String(value("--config")?));
            }
            "--pane" => {
                args.insert("pane".into(), Value::String(value("--pane")?));
            }
            "--tab" => {
                args.insert("tab".into(), Value::String(value("--tab")?));
            }
            "--workspace" => {
                args.insert("workspace".into(), Value::String(value("--workspace")?));
            }
            "--root" => {
                args.insert("root".into(), Value::String(value("--root")?));
            }
            "--color" => {
                args.insert("color".into(), Value::String(value("--color")?));
            }
            "--icon" => {
                args.insert("icon".into(), Value::String(value("--icon")?));
            }
            "--type" => {
                args.insert("type".into(), Value::String(value("--type")?));
            }
            "--path" => {
                args.insert("path".into(), Value::String(value("--path")?));
            }
            "--branch" => {
                args.insert("branch".into(), Value::String(value("--branch")?));
            }
            "--base" => {
                args.insert("base".into(), Value::String(value("--base")?));
            }
            "--archive" => {
                args.insert("archive".into(), Value::Bool(true));
            }
            "--editor" => {
                args.insert("editor".into(), Value::Bool(true));
            }
            "--force" => {
                args.insert("force".into(), Value::Bool(true));
            }
            "--cursor" => {
                let n: u64 = value("--cursor")?
                    .parse()
                    .map_err(|_| "--cursor needs a number".to_string())?;
                args.insert("cursor".into(), Value::from(n));
            }
            "--prefix" => {
                args.insert("prefix".into(), Value::String(value("--prefix")?));
            }
            "--client" => {
                args.insert("client".into(), Value::String(value("--client")?));
            }
            "--owner" => {
                args.insert("owner".into(), Value::String(value("--owner")?));
            }
            "--panes" => {
                args.insert("panes".into(), Value::String(value("--panes")?));
            }
            "--window" => {
                args.insert("window".into(), Value::String(value("--window")?));
            }
            "--styled" => {
                args.insert("styled".into(), Value::Bool(true));
            }
            "--out" => {
                let out_val = value("--out")?;
                args.insert("out".into(), Value::String(expand_path(&out_val)));
            }
            "-h" | "--help" => return Err(String::new()),
            a if a.starts_with('-') => return Err(format!("unknown option {a}")),
            a if cmd.is_none() => cmd = Some(a.to_string()),
            a => positional.push(a.to_string()),
        }
    }
    let cmd = cmd.ok_or_else(String::new)?;
    // What each command takes besides options: one text argument or none.
    let wants = match cmd.as_str() {
        "version" | "tree" | "text" | "tab-new" | "focus" | "close" | "last" | "wait"
        | "dialog" | "events" | "mcp" => None,
        "screenshot" => {
            if !positional.is_empty() {
                let p = positional.remove(0);
                args.insert("out".into(), Value::String(expand_path(&p)));
            }
            if !positional.is_empty() {
                return Err(format!("unexpected argument {}", positional[0]));
            }
            None
        }
        "status" => {
            let sub = if positional.is_empty() {
                "get".to_string()
            } else {
                positional.remove(0)
            };
            match sub.as_str() {
                "get" => {
                    args.insert("action".into(), Value::String("get".into()));
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                "set" => {
                    args.insert("action".into(), Value::String("set".into()));
                    if positional.is_empty() {
                        return Err("status set needs a status (e.g. idle, running, working, done, error, ...)".into());
                    }
                    args.insert("status".into(), Value::String(positional.remove(0)));
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                "clear" => {
                    args.insert("action".into(), Value::String("clear".into()));
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                other => {
                    return Err(format!(
                        "unknown status action \"{other}\"; use get, set, or clear"
                    ))
                }
            }
            None
        }
        "progress" => {
            if positional.is_empty() {
                args.insert("action".into(), Value::String("get".into()));
            } else {
                let first = positional.remove(0);
                let first_lower = first.to_lowercase();
                if let Ok(num) = first.parse::<u64>() {
                    if num > 100 {
                        return Err("progress value must be between 0 and 100".into());
                    }
                    args.insert("action".into(), Value::String("set".into()));
                    args.insert("value".into(), Value::from(num));
                } else {
                    match first_lower.as_str() {
                        "get" => {
                            args.insert("action".into(), Value::String("get".into()));
                        }
                        "clear" | "none" | "reset" => {
                            args.insert("action".into(), Value::String("clear".into()));
                        }
                        "indeterminate" => {
                            args.insert("action".into(), Value::String("indeterminate".into()));
                        }
                        "error" => {
                            args.insert("action".into(), Value::String("error".into()));
                            if !positional.is_empty() {
                                let val_str = positional.remove(0);
                                if let Ok(num) = val_str.parse::<u64>() {
                                    if num > 100 {
                                        return Err(
                                            "progress value must be between 0 and 100".into()
                                        );
                                    }
                                    args.insert("value".into(), Value::from(num));
                                } else {
                                    return Err(format!("invalid progress value \"{val_str}\""));
                                }
                            }
                        }
                        "pause" | "paused" => {
                            args.insert("action".into(), Value::String("pause".into()));
                            if !positional.is_empty() {
                                let val_str = positional.remove(0);
                                if let Ok(num) = val_str.parse::<u64>() {
                                    if num > 100 {
                                        return Err(
                                            "progress value must be between 0 and 100".into()
                                        );
                                    }
                                    args.insert("value".into(), Value::from(num));
                                } else {
                                    return Err(format!("invalid progress value \"{val_str}\""));
                                }
                            }
                        }
                        "set" | "normal" => {
                            args.insert("action".into(), Value::String("set".into()));
                            if !positional.is_empty() {
                                let val_str = positional.remove(0);
                                if let Ok(num) = val_str.parse::<u64>() {
                                    if num > 100 {
                                        return Err(
                                            "progress value must be between 0 and 100".into()
                                        );
                                    }
                                    args.insert("value".into(), Value::from(num));
                                } else {
                                    return Err(format!("invalid progress value \"{val_str}\""));
                                }
                            }
                        }
                        other => {
                            return Err(format!("unknown progress state \"{other}\"; use 0-100, indeterminate, error, pause, or clear"));
                        }
                    }
                }
            }
            if !positional.is_empty() {
                return Err(format!("unexpected argument {}", positional[0]));
            }
            None
        }
        "run" => {
            // Everything after `--`, as the program's argv; the program found
            // on this shell's PATH, which goes with it.
            if !dashdash || positional.is_empty() {
                return Err("run needs -- PROGRAM [ARGS...]".into());
            }
            let path = std::env::var("PATH").unwrap_or_default();
            let mut argv = std::mem::take(&mut positional);
            argv[0] = resolve(&argv[0], &path)
                .ok_or_else(|| format!("{}: not found on PATH", argv[0]))?;
            args.insert("argv".into(), Value::from(argv));
            args.insert("path".into(), Value::String(path));
            None
        }
        "hooks" => {
            let sub = if positional.is_empty() {
                "list".to_string()
            } else {
                positional.remove(0)
            };
            match sub.as_str() {
                "list" => {
                    args.insert("action".into(), Value::String("list".into()));
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                "status" => {
                    args.insert("action".into(), Value::String("status".into()));
                    if !positional.is_empty() {
                        args.insert("agent".into(), Value::String(positional.remove(0)));
                    }
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                "install" => {
                    args.insert("action".into(), Value::String("install".into()));
                    if positional.is_empty() {
                        return Err(
                            "hooks install needs an agent name (e.g. claude, gemini, codex, aider)"
                                .into(),
                        );
                    }
                    args.insert("agent".into(), Value::String(positional.remove(0)));
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                "uninstall" => {
                    args.insert("action".into(), Value::String("uninstall".into()));
                    if positional.is_empty() {
                        return Err("hooks uninstall needs an agent name (e.g. claude, gemini, codex, aider)".into());
                    }
                    args.insert("agent".into(), Value::String(positional.remove(0)));
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                other => {
                    return Err(format!(
                        "unknown hooks action \"{other}\"; use list, status, install, or uninstall"
                    ))
                }
            }
            None
        }
        "skills" => {
            let sub = if positional.is_empty() {
                "list".to_string()
            } else {
                positional.remove(0)
            };
            match sub.as_str() {
                "list" => {
                    args.insert("action".into(), Value::String("list".into()));
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                "status" => {
                    args.insert("action".into(), Value::String("status".into()));
                    if !positional.is_empty() {
                        let agent = positional.remove(0);
                        args.insert("agent".into(), Value::String(agent));
                    }
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                "install" => {
                    args.insert("action".into(), Value::String("install".into()));
                    if positional.is_empty() {
                        return Err("skills install needs an agent name (e.g. claude, gemini, codex, aider)".into());
                    }
                    args.insert("agent".into(), Value::String(positional.remove(0)));
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                "uninstall" => {
                    args.insert("action".into(), Value::String("uninstall".into()));
                    if positional.is_empty() {
                        return Err("skills uninstall needs an agent name (e.g. claude, gemini, codex, aider)".into());
                    }
                    args.insert("agent".into(), Value::String(positional.remove(0)));
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                other => {
                    return Err(format!(
                        "unknown skills action \"{other}\"; use list, status, install, or uninstall"
                    ))
                }
            }
            None
        }
        "workspace" => {
            let sub = if positional.is_empty() {
                "list".to_string()
            } else {
                positional.remove(0)
            };
            match sub.as_str() {
                "list" => {
                    args.insert("action".into(), Value::String("list".into()));
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                "current" => {
                    args.insert("action".into(), Value::String("current".into()));
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                "switch" => {
                    args.insert("action".into(), Value::String("switch".into()));
                    if positional.is_empty() {
                        return Err("workspace switch needs a workspace name or ID".into());
                    }
                    args.insert("name".into(), Value::String(positional.remove(0)));
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                "create" => {
                    args.insert("action".into(), Value::String("create".into()));
                    if positional.is_empty() {
                        return Err("workspace create needs a name".into());
                    }
                    args.insert("name".into(), Value::String(positional.remove(0)));
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                "delete" => {
                    args.insert("action".into(), Value::String("delete".into()));
                    if positional.is_empty() {
                        return Err("workspace delete needs a workspace name or ID".into());
                    }
                    args.insert("name".into(), Value::String(positional.remove(0)));
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                "assign" => {
                    args.insert("action".into(), Value::String("assign".into()));
                    if !positional.is_empty() {
                        let first = positional.remove(0);
                        if !positional.is_empty() {
                            let second = positional.remove(0);
                            args.insert("tab".into(), Value::String(first));
                            args.insert("workspace".into(), Value::String(second));
                        } else if args.contains_key("workspace") {
                            args.insert("tab".into(), Value::String(first));
                        } else {
                            args.insert("workspace".into(), Value::String(first));
                        }
                    }
                    if !args.contains_key("workspace") {
                        return Err(
                            "workspace assign needs a target workspace (--workspace <name>)".into(),
                        );
                    }
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                other => {
                    args.insert("action".into(), Value::String("switch".into()));
                    args.insert("name".into(), Value::String(other.to_string()));
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
            }
            None
        }
        "layout" => {
            let sub = if positional.is_empty() {
                return Err("layout needs an action: apply, save, approve, or status".into());
            } else {
                positional.remove(0)
            };
            match sub.as_str() {
                "apply" => {
                    args.insert("action".into(), Value::String("apply".into()));
                    if positional.is_empty() {
                        return Err("layout apply needs a layout file path".into());
                    }
                    let file = positional.remove(0);
                    let expanded = expand_path(&file);
                    let content = std::fs::read_to_string(&expanded)
                        .map_err(|e| format!("cannot read layout file '{}': {}", file, e))?;
                    args.insert("path".into(), Value::String(expanded));
                    args.insert("content".into(), Value::String(content));
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                "save" => {
                    args.insert("action".into(), Value::String("save".into()));
                    if positional.is_empty() {
                        return Err("layout save needs a target file path".into());
                    }
                    let file = positional.remove(0);
                    let expanded = expand_path(&file);
                    args.insert("path".into(), Value::String(expanded));
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                "approve" => {
                    args.insert("action".into(), Value::String("approve".into()));
                    if positional.is_empty() {
                        return Err("layout approve needs a layout file path".into());
                    }
                    let file = positional.remove(0);
                    let expanded = expand_path(&file);
                    let content = std::fs::read_to_string(&expanded)
                        .map_err(|e| format!("cannot read layout file '{}': {}", file, e))?;
                    args.insert("path".into(), Value::String(expanded));
                    args.insert("content".into(), Value::String(content));
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                "status" => {
                    args.insert("action".into(), Value::String("status".into()));
                    if positional.is_empty() {
                        return Err("layout status needs a layout file path".into());
                    }
                    let file = positional.remove(0);
                    let expanded = expand_path(&file);
                    let content = std::fs::read_to_string(&expanded)
                        .map_err(|e| format!("cannot read layout file '{}': {}", file, e))?;
                    args.insert("path".into(), Value::String(expanded));
                    args.insert("content".into(), Value::String(content));
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                other => {
                    return Err(format!(
                        "unknown layout action '{}'; expected apply, save, approve, or status",
                        other
                    ));
                }
            }
            None
        }
        "action" => {
            let sub = if positional.is_empty() {
                "list".to_string()
            } else {
                positional.remove(0)
            };
            match sub.as_str() {
                "list" => {
                    args.insert("action".into(), Value::String("list".into()));
                    if !positional.is_empty() {
                        let p = positional.remove(0);
                        args.insert("path".into(), Value::String(expand_path(&p)));
                    }
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                "run" => {
                    args.insert("action".into(), Value::String("run".into()));
                    if positional.is_empty() {
                        return Err("action run needs an action id".into());
                    }
                    let id = positional.remove(0);
                    args.insert("id".into(), Value::String(id));
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                "approve" => {
                    args.insert("action".into(), Value::String("approve".into()));
                    if !positional.is_empty() {
                        let p = positional.remove(0);
                        args.insert("path".into(), Value::String(expand_path(&p)));
                    }
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                "status" => {
                    args.insert("action".into(), Value::String("status".into()));
                    if !positional.is_empty() {
                        let p = positional.remove(0);
                        args.insert("path".into(), Value::String(expand_path(&p)));
                    }
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                other => {
                    return Err(format!(
                        "unknown action subcommand '{}'; expected list, run, approve, or status",
                        other
                    ));
                }
            }
            None
        }
        "task" => {
            let sub = if positional.is_empty() {
                "list".to_string()
            } else {
                positional.remove(0)
            };
            match sub.as_str() {
                "create" => {
                    args.insert("action".into(), Value::String("create".into()));
                    if positional.is_empty() {
                        return Err("task create needs a task name".into());
                    }
                    let name = positional.remove(0);
                    args.insert("name".into(), Value::String(name));
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                "list" => {
                    args.insert("action".into(), Value::String("list".into()));
                    if !positional.is_empty() {
                        let p = positional.remove(0);
                        args.insert("path".into(), Value::String(expand_path(&p)));
                    }
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                "status" => {
                    args.insert("action".into(), Value::String("status".into()));
                    if positional.is_empty() {
                        return Err("task status needs a task name".into());
                    }
                    let name = positional.remove(0);
                    args.insert("name".into(), Value::String(name));
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                "finish" => {
                    args.insert("action".into(), Value::String("finish".into()));
                    if positional.is_empty() {
                        return Err("task finish needs a task name".into());
                    }
                    let name = positional.remove(0);
                    args.insert("name".into(), Value::String(name));
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                other => {
                    return Err(format!(
                        "unknown task subcommand '{}'; expected create, list, status, or finish",
                        other
                    ));
                }
            }
            None
        }
        "split" => {
            if positional.is_empty() {
                args.insert("direction".into(), Value::String("right".into()));
            } else if positional.len() == 1 {
                let dir = positional.remove(0);
                match dir.to_lowercase().as_str() {
                    "right" | "left" | "down" | "up" => {
                        args.insert("direction".into(), Value::String(dir));
                    }
                    other => {
                        return Err(format!(
                            "split direction must be right, left, down, or up (got \"{other}\")"
                        ));
                    }
                }
            } else {
                return Err("split takes at most one direction argument (right, left, down, up)".into());
            }
            None
        }
        "collapse" | "expand" => {
            if !positional.is_empty() {
                args.insert("target".into(), Value::String(positional.remove(0)));
            }
            if !positional.is_empty() {
                return Err(format!("unexpected argument {}", positional[0]));
            }
            None
        }
        "resume" => {
            let sub = if positional.is_empty() {
                "show".to_string()
            } else {
                positional.remove(0)
            };
            match sub.as_str() {
                "set" => {
                    args.insert("action".into(), Value::String("set".into()));
                    if positional.is_empty() {
                        return Err(
                            "resume set needs a command line: takoctl resume set -- <argv...>".into(),
                        );
                    }
                    let argv_vals: Vec<Value> =
                        positional.drain(..).map(Value::String).collect();
                    args.insert("argv".into(), Value::Array(argv_vals));
                    if !args.contains_key("cwd") {
                        if let Ok(dir) = std::env::current_dir() {
                            args.insert(
                                "cwd".into(),
                                Value::String(dir.to_string_lossy().to_string()),
                            );
                        }
                    }
                    let mut env_map = Map::new();
                    for (k, v) in std::env::vars() {
                        env_map.insert(k, Value::String(v));
                    }
                    args.insert("env".into(), Value::Object(env_map));
                }
                "show" => {
                    args.insert("action".into(), Value::String("show".into()));
                    if !positional.is_empty() {
                        let target = positional.remove(0);
                        args.insert("target".into(), Value::String(target));
                    }
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                "clear" => {
                    args.insert("action".into(), Value::String("clear".into()));
                    if !positional.is_empty() {
                        let target = positional.remove(0);
                        args.insert("target".into(), Value::String(target));
                    }
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                "run" => {
                    args.insert("action".into(), Value::String("run".into()));
                    if !positional.is_empty() {
                        let target = positional.remove(0);
                        args.insert("target".into(), Value::String(target));
                    }
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                "approve" => {
                    args.insert("action".into(), Value::String("approve".into()));
                    if !positional.is_empty() {
                        let target = positional.remove(0);
                        args.insert("target".into(), Value::String(target));
                    }
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                other => {
                    return Err(format!(
                        "unknown resume action \"{other}\"; use set, show, clear, run, or approve"
                    ))
                }
            }
            None
        }
        "input" => {
            let sub = if positional.is_empty() {
                "status".to_string()
            } else {
                positional.remove(0)
            };
            match sub.as_str() {
                "lock" | "unlock" | "takeover" | "handback" | "status" | "log" => {
                    args.insert("subcommand".into(), Value::String(sub));
                }
                other => {
                    return Err(format!(
                        "unknown input action \"{other}\"; use lock, unlock, takeover, handback, status, or log"
                    ));
                }
            }
            if !positional.is_empty() {
                return Err(format!("unexpected argument {}", positional[0]));
            }
            None
        }
        "broadcast" => {
            let sub = if positional.is_empty() {
                "status".to_string()
            } else {
                positional.remove(0)
            };
            match sub.as_str() {
                "start" | "stop" | "status" => {
                    args.insert("subcommand".into(), Value::String(sub));
                }
                other => {
                    return Err(format!(
                        "unknown broadcast action \"{other}\"; use start, stop, or status"
                    ));
                }
            }
            if !positional.is_empty() {
                return Err(format!("unexpected argument {}", positional[0]));
            }
            None
        }
        "session" => {
            let sub = if positional.is_empty() {
                return Err("session needs an action: export, import, or info".into());
            } else {
                positional.remove(0)
            };
            match sub.as_str() {
                "export" => {
                    args.insert("action".into(), Value::String("export".into()));
                    if positional.is_empty() {
                        return Err("session export needs a destination file path".into());
                    }
                    let file = positional.remove(0);
                    let expanded = expand_path(&file);
                    args.insert("path".into(), Value::String(expanded));
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                "import" => {
                    args.insert("action".into(), Value::String("import".into()));
                    if positional.is_empty() {
                        return Err("session import needs a session file path".into());
                    }
                    let file = positional.remove(0);
                    let expanded = expand_path(&file);
                    args.insert("path".into(), Value::String(expanded));
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                "info" => {
                    args.insert("action".into(), Value::String("info".into()));
                    if positional.is_empty() {
                        return Err("session info needs a session file path".into());
                    }
                    let file = positional.remove(0);
                    let expanded = expand_path(&file);
                    args.insert("path".into(), Value::String(expanded));
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                other => {
                    return Err(format!(
                        "unknown session action '{}'; expected export, import, or info",
                        other
                    ));
                }
            }
            None
        }
        "overlay" => {
            let sub = if positional.is_empty() {
                "status".to_string()
            } else {
                positional.remove(0)
            };
            match sub.as_str() {
                "open" => {
                    args.insert("subcommand".into(), Value::String("open".into()));
                    if positional.is_empty() {
                        return Err("overlay open needs a file path".into());
                    }
                    let file = positional.remove(0);
                    let expanded = expand_path(&file);
                    args.insert("file".into(), Value::String(expanded));
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                "close" => {
                    args.insert("subcommand".into(), Value::String("close".into()));
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                "status" => {
                    args.insert("subcommand".into(), Value::String("status".into()));
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                "reload" => {
                    args.insert("subcommand".into(), Value::String("reload".into()));
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                other => {
                    return Err(format!(
                        "unknown overlay action '{other}'; expected open, close, status, or reload"
                    ));
                }
            }
            None
        }
        "title" => Some("title"),
        "send" | "type" | "notify" | "find" => Some("text"),
        "ask" => Some("message"),
        "key" => Some("key"),
        _ => return Err(format!("unknown command {cmd}")),
    };
    match (wants, positional.len()) {
        (None, 0) => {}
        (None, _) => return Err(format!("unexpected argument {}", positional[0])),
        (Some(name), 1) => {
            args.insert(name.into(), Value::String(positional.remove(0)));
        }
        (Some(name), 0) => return Err(format!("{cmd} needs a {name}")),
        (Some(_), _) => return Err(format!("{cmd} takes one argument; quote it")),
    }
    Ok(Options {
        cmd,
        args,
        json,
        socket,
        bundle_id,
    })
}

/// The request line: the command, its arguments, and the pane it is sent
/// from when it runs inside one.
fn request(opts: &Options, from: Option<String>) -> Value {
    let mut req = json!({"cmd": opts.cmd, "args": Value::Object(opts.args.clone())});
    if let Some(from) = from.filter(|f| !f.is_empty()) {
        req["from"] = Value::String(from);
    }
    req
}

/// A human reading of an `ok` answer.
fn render(cmd: &str, result: &Value) -> String {
    match cmd {
        "version" => format!(
            "{} {} (build {}), protocol {}",
            result["app"].as_str().unwrap_or("Tako"),
            result["version"].as_str().unwrap_or("?"),
            result["build"].as_str().unwrap_or("?"),
            result["protocol"]
        ),
        "tree" => {
            let mut out = String::new();
            for window in result["windows"].as_array().into_iter().flatten() {
                out += &format!("window {}\n", window["id"].as_str().unwrap_or(""));
                for tab in window["tabs"].as_array().into_iter().flatten() {
                    let mut head = match tab["index"].as_f64() {
                        Some(i) => format!("  tab {}", i as u64),
                        None => format!("  tab {}", tab["id"].as_str().unwrap_or("")),
                    };
                    if let Some(t) = tab["title"].as_str().filter(|t| !t.is_empty()) {
                        head += &format!("  \"{t}\"");
                    }
                    if tab["selected"].as_bool() == Some(true) {
                        head += "  (shown)";
                    }
                    out += &head;
                    out.push('\n');
                    let panes: Vec<&Value> =
                        tab["panes"].as_array().into_iter().flatten().collect();
                    let has_hierarchy = panes
                        .iter()
                        .any(|p| p.get("parent").is_some() || p.get("children").is_some());
                    if has_hierarchy {
                        for pane in panes
                            .iter()
                            .filter(|p| p.get("parent").is_none() || p["parent"].is_null())
                        {
                            out += &pane_line(pane, 2);
                            if pane["collapsed"].as_bool() != Some(true) {
                                if let Some(children_ids) = pane["children"].as_array() {
                                    for cid in children_ids.iter().filter_map(Value::as_str) {
                                        if let Some(child_pane) =
                                            panes.iter().find(|p| p["id"].as_str() == Some(cid))
                                        {
                                            out += &pane_line(child_pane, 3);
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        match tab.get("layout").filter(|l| !l.is_null()) {
                            Some(layout) => outline(&mut out, layout, &panes, 2),
                            None => {
                                for pane in &panes {
                                    out += &pane_line(pane, 2);
                                }
                            }
                        }
                    }
                }
            }
            out
        }
        "text" => {
            let mut out = result["text"].as_str().unwrap_or("").to_string();
            out.push('\n');
            out
        }
        "screenshot" => {
            let width = result["width"].as_f64().unwrap_or(0.0) as u64;
            let height = result["height"].as_f64().unwrap_or(0.0) as u64;
            let id = result["id"].as_str().unwrap_or("");
            format!("screenshot of pane {id} ({width}x{height} png)\n")
        }
        "send" | "type" | "key" | "focus" | "title" | "notify" => String::new(),
        "tab-new" | "split" | "collapse" | "expand" => {
            format!("{}\n", result["id"].as_str().unwrap_or(""))
        }
        "close" => format!("{}\n", result["state"].as_str().unwrap_or("")),
        "run" if result.get("state").is_none() => {
            format!("{}\n", result["id"].as_str().unwrap_or(""))
        }
        "last" | "wait" | "run" => command_report(result),
        "status" => status_report(result),
        "progress" => progress_report(result),
        "find" => find_report(result),
        "dialog" => dialog_report(result),
        "ask" => format!("{}\n", serde_json::to_string(result).unwrap_or_default()),
        "workspace" => workspace_report(result),
        "layout" => layout_report(result),
        "action" => action_report(result),
        "task" => task_report(result),
        "resume" => resume_report(result),
        "input" => input_report(result),
        "broadcast" => broadcast_report(result),
        "session" => session_report(result),
        "overlay" => overlay_report(result),
        _ => format!("{result}\n"),
    }
}

fn overlay_report(result: &Value) -> String {
    if let Some(true) = result.get("closed").and_then(Value::as_bool) {
        let id = result["id"].as_str().unwrap_or("pane");
        return format!("Closed overlay for pane {id}.\n");
    }
    if let Some(false) = result.get("closed").and_then(Value::as_bool) {
        let id = result["id"].as_str().unwrap_or("pane");
        return format!("No active overlay to close on pane {id}.\n");
    }
    if let Some(true) = result.get("reloaded").and_then(Value::as_bool) {
        let id = result["id"].as_str().unwrap_or("pane");
        return format!("Reloaded overlay for pane {id}.\n");
    }
    if let Some(open) = result.get("open").and_then(Value::as_bool) {
        let id = result["id"].as_str().unwrap_or("pane");
        if open {
            let file = result["file"].as_str().unwrap_or("");
            let file_type = result["type"].as_str().unwrap_or("document");
            let title = result["title"].as_str().unwrap_or("");
            let sandboxed = result["sandboxed"].as_str().unwrap_or("");
            let split = result.get("split").and_then(Value::as_str);

            let mut out = String::new();
            if let Some(s) = split {
                out.push_str(&format!("Overlay active on pane {id} (split {s}):\n"));
            } else {
                out.push_str(&format!("Overlay active on pane {id}:\n"));
            }
            out.push_str(&format!("  File: {file}\n"));
            out.push_str(&format!("  Type: {file_type}\n"));
            if !title.is_empty() && title != file {
                out.push_str(&format!("  Title: {title}\n"));
            }
            if !sandboxed.is_empty() {
                out.push_str(&format!("  Sandboxed: {sandboxed}\n"));
            }
            return out;
        } else {
            return format!("No overlay active on pane {id}.\n");
        }
    }
    format!("{result}\n")
}

fn session_report(result: &Value) -> String {
    if result.get("exported") == Some(&Value::Bool(true)) {
        let path = result["path"].as_str().unwrap_or("");
        let windows = result["windows"].as_f64().unwrap_or(0.0) as u64;
        let panes = result["panes"].as_f64().unwrap_or(0.0) as u64;
        let resumes = result["resumes"].as_f64().unwrap_or(0.0) as u64;
        let mut msg = format!(
            "Exported session to {path} ({windows} window{}, {panes} pane{})",
            if windows == 1 { "" } else { "s" },
            if panes == 1 { "" } else { "s" }
        );
        if resumes > 0 {
            msg.push_str(&format!(
                ", {resumes} resume binding{}",
                if resumes == 1 { "" } else { "s" }
            ));
        }
        msg.push('\n');
        return msg;
    }
    if result.get("imported") == Some(&Value::Bool(true)) {
        let path = result["path"].as_str().unwrap_or("");
        let windows = result["windows"].as_f64().unwrap_or(0.0) as u64;
        return format!(
            "Imported session from {path} ({windows} window{} created)\n  (Untrusted session: control sequences dropped, nothing runs automatically)\n",
            if windows == 1 { "" } else { "s" }
        );
    }
    if let Some(ver) = result.get("format_version").and_then(Value::as_f64) {
        let format_ver = ver as u64;
        let tako_ver = result["tako_version"].as_str().unwrap_or("unknown");
        let exported_at = result["exported_at"].as_str().unwrap_or("");
        let windows = result["windows"].as_f64().unwrap_or(0.0) as u64;
        let panes = result["panes"].as_f64().unwrap_or(0.0) as u64;
        let resumes = result["resumes"].as_f64().unwrap_or(0.0) as u64;
        let mut out = format!(
            "Session file (format v{format_ver}, exported by Tako {tako_ver} at {exported_at}):\n  {windows} window{}, {panes} pane{}",
            if windows == 1 { "" } else { "s" },
            if panes == 1 { "" } else { "s" }
        );
        if resumes > 0 {
            out.push_str(&format!(
                ", {resumes} resume record{}",
                if resumes == 1 { "" } else { "s" }
            ));
        }
        out.push('\n');
        return out;
    }
    format!("{result}\n")
}

fn broadcast_report(result: &Value) -> String {
    let active = result["active"].as_bool().unwrap_or(false);
    if !active {
        return "Broadcast input is inactive.\n".to_string();
    }
    let count = result["count"].as_f64().unwrap_or(0.0) as usize;
    let leader = result["leader"].as_str().unwrap_or("none");
    let mut out = format!("Broadcast active across {count} panes (leader: {leader}):\n");
    if let Some(panes) = result["panes"].as_array() {
        for p in panes.iter().filter_map(Value::as_str) {
            let is_leader = p == leader;
            if is_leader {
                out += &format!("  * {p} (leader)\n");
            } else {
                out += &format!("    {p}\n");
            }
        }
    }
    out
}

fn input_report(result: &Value) -> String {
    if let Some(entries) = result["entries"].as_array() {
        if entries.is_empty() {
            return "No automated input activity recorded for this pane.\n".to_string();
        }
        let mut out = String::new();
        out += "Automated input activity:\n";
        for entry in entries {
            let client = entry["client"].as_str().unwrap_or("unknown");
            let action = entry["action"].as_str().unwrap_or("");
            let ts = entry["timestamp"].as_str().unwrap_or("");
            out += &format!("  [{ts}] {client}: {action}\n");
        }
        return out;
    }

    let mut out = String::new();
    let locked = result["locked"].as_bool().unwrap_or(false);
    let owner = result["owner"].as_str().unwrap_or("human");
    let id = result["id"].as_str().unwrap_or("");

    if locked {
        out += &format!("Pane {id}: locked (owner: {owner})\n");
    } else {
        out += &format!("Pane {id}: unlocked (owner: {owner})\n");
    }

    if let (Some(client), Some(action)) = (
        result["last_client"].as_str(),
        result["last_action"].as_str(),
    ) {
        out += &format!("Last activity mark: {client}: {action}\n");
    }
    out
}

fn resume_report(result: &Value) -> String {
    if result["cleared"].as_bool() == Some(true) {
        return format!(
            "Resume session cleared for pane {}\n",
            result["id"].as_str().unwrap_or("")
        );
    }
    if result["executed"].as_bool() == Some(true) {
        return format!(
            "Executed resume command for pane {}\n",
            result["id"].as_str().unwrap_or("")
        );
    }
    if result["approved"].as_bool() == Some(true) && result.get("prefix").is_some() {
        return format!(
            "Approved prefix \"{}\" for directory \"{}\"\n",
            result["prefix"].as_str().unwrap_or(""),
            result["cwd"].as_str().unwrap_or("")
        );
    }
    if result["has_resume"].as_bool() == Some(false) {
        return format!(
            "No resume session recorded for pane {}\n",
            result["id"].as_str().unwrap_or("")
        );
    }
    let mut out = String::new();
    if let Some(id) = result["id"].as_str() {
        out += &format!("Pane: {}\n", id);
    }
    if let Some(argv) = result["argv"].as_array() {
        let cmd = argv
            .iter()
            .filter_map(Value::as_str)
            .collect::<Vec<_>>()
            .join(" ");
        out += &format!("Command: {}\n", cmd);
    }
    if let Some(cwd) = result["cwd"].as_str() {
        out += &format!("Directory: {}\n", cwd);
    }
    if let Some(is_imported) = result["is_imported"].as_bool() {
        if is_imported {
            out += "Imported: yes (untrusted, auto-run disabled)\n";
        }
    }
    if let Some(approved) = result["approved"].as_bool() {
        out += &format!("Auto-run approved: {}\n", if approved { "yes" } else { "no" });
    }
    if let Some(recorded_at) = result["recorded_at"].as_str() {
        out += &format!("Recorded at: {}\n", recorded_at);
    }
    out
}

fn expand_path(file: &str) -> String {
    if let Some(stripped) = file.strip_prefix("~/") {
        if let Ok(home) = std::env::var("HOME") {
            return format!("{home}/{stripped}");
        }
    } else if file == "~" {
        if let Ok(home) = std::env::var("HOME") {
            return home;
        }
    } else if !file.starts_with('/') {
        if let Ok(cwd) = std::env::current_dir() {
            return cwd.join(file).to_string_lossy().to_string();
        }
    }
    file.to_string()
}

fn layout_report(result: &Value) -> String {
    if result.get("saved") == Some(&Value::Bool(true)) {
        let path = result["path"].as_str().unwrap_or("layout.json");
        let tabs = result["tabs"].as_f64().unwrap_or(0.0) as u64;
        let panes = result["panes"].as_f64().unwrap_or(0.0) as u64;
        return format!(
            "Saved layout to {path} ({tabs} tab{}, {panes} pane{})\n",
            if tabs == 1 { "" } else { "s" },
            if panes == 1 { "" } else { "s" }
        );
    }
    if result.get("applied") == Some(&Value::Bool(true)) {
        let path = result["path"].as_str().unwrap_or("");
        let tabs = result["tabs"].as_f64().unwrap_or(0.0) as u64;
        let panes = result["panes"].as_f64().unwrap_or(0.0) as u64;
        let started = result["programs_started"].as_f64().unwrap_or(0.0) as u64;
        let suppressed = result["programs_suppressed"].as_f64().unwrap_or(0.0) as u64;
        let trusted = result["trusted"].as_bool().unwrap_or(true);

        let mut msg = if path.is_empty() {
            format!(
                "Applied layout ({tabs} tab{}, {panes} pane{})",
                if tabs == 1 { "" } else { "s" },
                if panes == 1 { "" } else { "s" }
            )
        } else {
            format!(
                "Applied layout from {path} ({tabs} tab{}, {panes} pane{})",
                if tabs == 1 { "" } else { "s" },
                if panes == 1 { "" } else { "s" }
            )
        };
        if started > 0 {
            msg.push_str(&format!(
                ", {started} program{} started",
                if started == 1 { "" } else { "s" }
            ));
        }
        if suppressed > 0 {
            msg.push_str(&format!(
                ", {suppressed} program{} suppressed (untrusted layout)",
                if suppressed == 1 { "" } else { "s" }
            ));
        } else if !trusted {
            msg.push_str(" (untrusted layout: programs not started)");
        }
        msg.push('\n');
        return msg;
    }
    if result.get("approved") == Some(&Value::Bool(true)) {
        let path = result["path"].as_str().unwrap_or("");
        let sha = result["sha256"].as_str().unwrap_or("");
        let short_sha = if sha.len() >= 12 { &sha[..12] } else { sha };
        return format!("Approved layout {path} (sha256: {short_sha})\n");
    }
    if let Some(status) = result["status"].as_str() {
        let path = result["path"].as_str().unwrap_or("");
        let sha = result["sha256"].as_str().unwrap_or("");
        let short_sha = if sha.len() >= 12 { &sha[..12] } else { sha };
        return format!("Layout {path}: {status} (sha256: {short_sha})\n");
    }
    format!("{result}\n")
}

fn action_report(result: &Value) -> String {
    if let Some(actions) = result.get("actions").and_then(Value::as_array) {
        if actions.is_empty() {
            return "No project actions found\n".into();
        }
        let project = result["project"].as_str().unwrap_or("");
        let status = result["status"].as_str().unwrap_or("untrusted");
        let mut out = if let Some(name) = result["name"].as_str() {
            format!("Project actions for {name} ({project}) [{status}]:\n")
        } else {
            format!("Project actions for {project} [{status}]:\n")
        };
        for act in actions {
            let id = act["id"].as_str().unwrap_or("");
            let title = act["title"].as_str().unwrap_or(id);
            let target = act["target"].as_str().unwrap_or("split");
            let cmd = act["command"]
                .as_array()
                .map(|arr| {
                    arr.iter()
                        .filter_map(Value::as_str)
                        .collect::<Vec<_>>()
                        .join(" ")
                })
                .unwrap_or_default();
            out += &format!("  * {id} ({target}): {title}\n");
            if !cmd.is_empty() {
                out += &format!("      $ {cmd}\n");
            }
        }
        return out;
    }
    if result.get("ran") == Some(&Value::Bool(true)) {
        let id = result["id"].as_str().unwrap_or("");
        let title = result["title"].as_str().unwrap_or(id);
        let target = result["target"].as_str().unwrap_or("");
        let cwd = result["cwd"].as_str().unwrap_or("");
        return format!("Ran action '{title}' ({id}) in {target} (cwd: {cwd})\n");
    }
    if result.get("approved") == Some(&Value::Bool(true)) {
        let path = result["path"].as_str().unwrap_or("");
        let sha = result["sha256"].as_str().unwrap_or("");
        let short_sha = if sha.len() >= 12 { &sha[..12] } else { sha };
        return format!("Approved project actions at {path} (sha256: {short_sha})\n");
    }
    if let Some(status) = result["status"].as_str() {
        let path = result["path"].as_str().unwrap_or("");
        let sha = result["sha256"].as_str().unwrap_or("");
        let count = result["actions_count"].as_f64().unwrap_or(0.0) as u64;
        let short_sha = if sha.len() >= 12 { &sha[..12] } else { sha };
        return format!(
            "Project actions {path}: {status} (sha256: {short_sha}, {count} action{})\n",
            if count == 1 { "" } else { "s" }
        );
    }
    format!("{result}\n")
}

fn task_report(result: &Value) -> String {
    if let Some(tasks) = result.get("tasks").and_then(Value::as_array) {
        if tasks.is_empty() {
            return "No worktree tasks found\n".into();
        }
        let mut out = "Worktree tasks:\n".to_string();
        for t in tasks {
            let name = t["name"].as_str().unwrap_or("");
            let branch = t["branch"].as_str().unwrap_or("");
            let status = t["status"].as_str().unwrap_or("running");
            let worktree = t["worktree"].as_str().unwrap_or("");
            let ahead = t["ahead"].as_f64().unwrap_or(0.0) as u64;
            let behind = t["behind"].as_f64().unwrap_or(0.0) as u64;
            let changed = t["changed_files"].as_f64().unwrap_or(0.0) as u64;
            let changes_str = if changed == 0 {
                "clean".to_string()
            } else {
                format!("{changed} changed file{}", if changed == 1 { "" } else { "s" })
            };
            out += &format!("  * {name} ({branch}): [{status}] (worktree: {worktree})\n");
            out += &format!("      ahead: {ahead}, behind: {behind}, {changes_str}\n");
        }
        return out;
    }
    if result.get("created") == Some(&Value::Bool(true)) {
        let name = result["name"].as_str().unwrap_or("");
        let branch = result["branch"].as_str().unwrap_or("");
        let base = result["base"].as_str().unwrap_or("");
        let target = result["target"].as_str().unwrap_or("tab");
        let worktree = result["worktree"].as_str().unwrap_or("");
        return format!("Created worktree task '{name}' on branch {branch} (base: {base}, target: {target})\n  Worktree: {worktree}\n");
    }
    if result.get("finished") == Some(&Value::Bool(true)) {
        let name = result["name"].as_str().unwrap_or("");
        let archived = result["archived"].as_bool().unwrap_or(false);
        let editor = result["opened_in_editor"].as_bool().unwrap_or(false);
        let worktree = result["worktree"].as_str().unwrap_or("");
        if archived {
            return format!("Archived worktree task '{name}' (removed worktree at {worktree})\n");
        } else if editor {
            return format!("Finished worktree task '{name}' (opened in editor at {worktree})\n");
        } else {
            return format!("Finished worktree task '{name}'\n");
        }
    }
    if let Some(status) = result.get("status").and_then(Value::as_str) {
        let name = result["name"].as_str().unwrap_or("");
        let branch = result["branch"].as_str().unwrap_or("");
        let worktree = result["worktree"].as_str().unwrap_or("");
        let ahead = result["ahead"].as_f64().unwrap_or(0.0) as u64;
        let behind = result["behind"].as_f64().unwrap_or(0.0) as u64;
        let changed = result["changed_files"].as_f64().unwrap_or(0.0) as u64;
        let changes_str = if changed == 0 {
            "clean".to_string()
        } else {
            format!("{changed} changed file{}", if changed == 1 { "" } else { "s" })
        };
        return format!(
            "Worktree task '{name}' ({branch}): [{status}]\n  Worktree: {worktree}\n  ahead: {ahead}, behind: {behind}, {changes_str}\n"
        );
    }
    format!("{result}\n")
}

fn workspace_report(result: &Value) -> String {
    if let Some(workspaces) = result.get("workspaces").and_then(Value::as_array) {
        let mut out = String::new();
        for ws in workspaces {
            let active = if ws["is_active"].as_bool() == Some(true) {
                "* "
            } else {
                "  "
            };
            let name = ws["name"].as_str().unwrap_or("");
            let tabs_count = ws["tabs"].as_array().map_or(0, |a| a.len());
            let attention = ws["attention_count"].as_f64().unwrap_or(0.0) as u64;
            let mut line = format!("{active}{name} ({tabs_count} tabs)");
            if attention > 0 {
                line += &format!(" [{attention} unread]");
            }
            if let Some(root) = ws["root_directory"].as_str() {
                line += &format!("  {root}");
            }
            line.push('\n');
            out += &line;
        }
        return out;
    }
    if let Some(name) = result.get("name").and_then(Value::as_str) {
        if result.get("tabs").is_some() {
            let tabs_count = result["tabs"].as_array().map_or(0, |a| a.len());
            let attention = result["attention_count"].as_f64().unwrap_or(0.0) as u64;
            let mut line = format!("{name} ({tabs_count} tabs)");
            if attention > 0 {
                line += &format!(" [{attention} unread]");
            }
            if let Some(root) = result["root_directory"].as_str() {
                line += &format!("  {root}");
            }
            line.push('\n');
            return line;
        }
        return format!("{name}\n");
    }
    if let Some(deleted) = result.get("deleted").and_then(Value::as_str) {
        return format!("deleted {deleted}\n");
    }
    if let Some(tab) = result.get("tab").and_then(Value::as_str) {
        let ws = result["workspace"].as_str().unwrap_or("");
        return format!("assigned {tab} to {ws}\n");
    }
    format!("{result}\n")
}

fn progress_report(result: &Value) -> String {
    let state = result["state"].as_str().unwrap_or("none");
    let mut out = state.to_string();
    if let Some(prog) = result["progress"].as_f64() {
        out += &format!(" ({}%)", prog as u64);
    }
    out.push('\n');
    out
}

fn status_report(result: &Value) -> String {
    let status = result["status"].as_str().unwrap_or("unknown");
    let mut out = status.to_string();
    if let Some(text) = result["text"].as_str() {
        out += &format!(" ({text})");
    }
    if let Some(ttl) = result["ttl"].as_f64() {
        if ttl < 60.0 {
            out += &format!(" [TTL: {:.1}s]", ttl);
        } else {
            out += &format!(" [TTL: {}m {}s]", (ttl as u64) / 60, (ttl as u64) % 60);
        }
    }
    if result["unread"].as_bool() == Some(true) {
        out += " [unread]";
    }
    out.push('\n');
    out
}

/// A command as `last` reports it: `$ line   (cwd)   exit N`, then its output.
fn command_report(result: &Value) -> String {
    if let Some(process) = result.get("process") {
        return process_report(process, result);
    }
    if result["state"].as_str() == Some("gone") {
        return format!(
            "command {} is no longer kept\n",
            result["command"]["ref"].as_str().unwrap_or("?")
        );
    }
    let command = &result["command"];
    if command.is_null() {
        return "no command marked by the shell in this pane (shell integration off?)\n".into();
    }
    let status = match (
        result["state"].as_str(),
        command["running"].as_bool(),
        command["exitCode"].as_f64(),
    ) {
        (Some("timeout"), _, _) => "still running (timed out waiting)".to_string(),
        (_, Some(true), _) => "running".to_string(),
        _ if command["abandoned"].as_bool() == Some(true) => {
            "abandoned (a new prompt came before it ended)".to_string()
        }
        (_, _, Some(code)) => format!("exit {}", code as i64),
        _ => "ended, no exit status".to_string(),
    };
    let mut out = format!(
        "$ {}",
        command["input"]
            .as_str()
            .unwrap_or("(command line not reported by the shell)")
    );
    if let Some(cwd) = command["cwd"].as_str() {
        out += &format!("   ({cwd})");
    }
    out += &format!("   {status}");
    if let Some(r) = command["ref"].as_str() {
        out += &format!("   [{r}]");
    }
    out.push('\n');
    if result["more"].as_bool() == Some(true) {
        out += "...\n";
    }
    if result["incomplete"].as_bool() == Some(true) {
        out += "(some of its output was written over or is no longer kept)\n";
    }
    let output = result["output"].as_str().unwrap_or("");
    if !output.is_empty() {
        out += output;
        out.push('\n');
    }
    out
}

/// Matches grouped as the panel groups them: by pane, then by the command
/// that printed them.
fn find_report(result: &Value) -> String {
    let mut out = String::new();
    let mut pane = None;
    let mut command = None;
    for m in result["matches"].as_array().into_iter().flatten() {
        let id = m["id"].as_str().unwrap_or("");
        if pane != Some(id) {
            pane = Some(id);
            command = None;
            let label = match m["pane"].as_str() {
                Some(p) => format!("{} -- {p}", m["place"].as_str().unwrap_or("")),
                None => m["place"].as_str().unwrap_or("").to_string(),
            };
            out += &format!("{}  {label}\n", &id[..id.len().min(8)]);
        }
        let heading = m.get("command").map(|c| {
            let mut h = format!(
                "$ {}",
                c["input"].as_str().unwrap_or("(command line not reported)")
            );
            h += &format!("   {}", c["status"].as_str().unwrap_or(""));
            if let Some(cwd) = c["cwd"].as_str() {
                h += &format!("   {cwd}");
            }
            h
        });
        if heading != command {
            if let Some(h) = &heading {
                out += &format!("  {h}\n");
            }
            command = heading;
        }
        out += &format!("    {}\n", m["line"].as_str().unwrap_or("").trim_end());
    }
    if out.is_empty() {
        out = "no matches\n".into();
    } else if result["more"].as_bool() == Some(true) {
        out += "... more matches (--limit N)\n";
    }
    out
}

/// The questions up, each as its frame, text and buttons; or what was pressed.
fn dialog_report(result: &Value) -> String {
    if let Some(label) = result["pressed"].as_str() {
        return format!(
            "pressed {label} in \"{}\"\n",
            result["title"].as_str().unwrap_or("")
        );
    }
    let mut out = String::new();
    for d in result["dialogs"].as_array().into_iter().flatten() {
        out += &format!(
            "{}  {}\n",
            d["window"].as_str().unwrap_or(""),
            d["title"].as_str().unwrap_or("")
        );
        for line in d["text"].as_str().unwrap_or("").lines() {
            out += &format!("  {line}\n");
        }
        let selected = d["selected"].as_str();
        let buttons: Vec<String> = d["buttons"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .map(|b| {
                if Some(b) == selected {
                    format!("[{b}]")
                } else {
                    b.to_string()
                }
            })
            .collect();
        out += &format!("  buttons: {}\n", buttons.join("  "));
    }
    if out.is_empty() {
        "no question is up\n".into()
    } else {
        out
    }
}

/// A program run started: its argv, how it ended, what the pane shows.
fn process_report(process: &Value, result: &Value) -> String {
    let argv: Vec<&str> = process["argv"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .collect();
    let status = match (
        result["state"].as_str(),
        process["running"].as_bool(),
        process["exitCode"].as_f64(),
    ) {
        _ if process["startError"].is_string() => {
            format!(
                "could not start: {}",
                process["startError"].as_str().unwrap_or("")
            )
        }
        (Some("timeout"), _, _) => "still running (timed out waiting)".to_string(),
        (_, Some(true), _) => "running".to_string(),
        (_, _, Some(code)) => format!("exit {}", code as i64),
        _ => "exited, status unknown".to_string(),
    };
    let mut out = format!("{}   {status}\n", argv.join(" "));
    let output = result["output"].as_str().unwrap_or("");
    if !output.is_empty() {
        out += output;
        out.push('\n');
    }
    out
}

/// How long to wait for the app's answer: a wait for as long as asked plus
/// a margin, an unbounded one for a day; anything else the usual limit.
fn answer_limit(opts: &Options) -> std::time::Duration {
    let waits = opts.cmd == "wait"
        || opts.cmd == "ask"
        || (opts.cmd == "run" && opts.args.get("wait") == Some(&Value::Bool(true)));
    if !waits {
        return socket::TIMEOUT;
    }
    match opts.args.get("timeout").and_then(Value::as_f64) {
        Some(s) => std::time::Duration::from_secs_f64(s) + socket::TIMEOUT,
        None => std::time::Duration::from_secs(24 * 3600),
    }
}

/// One pane: `*` when it has the keyboard, its id, directory and title, and status if set.
fn pane_line(pane: &Value, depth: usize) -> String {
    let mark = if pane["focused"].as_bool() == Some(true) {
        "*"
    } else {
        " "
    };
    let mut line = format!(
        "{}{mark}{}  {}  {}",
        "  ".repeat(depth),
        pane["id"].as_str().unwrap_or(""),
        pane["cwd"].as_str().unwrap_or("-"),
        pane["title"].as_str().unwrap_or("")
    );
    if let Some(label) = pane["label"].as_str() {
        line += &format!("  [{label}]");
    }
    if let Some(status) = pane["status"].as_str() {
        if status != "unknown" {
            line += &format!("  [{status}");
            if let Some(text) = pane["statusText"].as_str() {
                line += &format!(": {text}");
            }
            line.push(']');
        }
    }
    if let Some(summary) = pane["childrenStatus"].as_str() {
        line += &format!("  ({summary})");
    }
    if pane["collapsed"].as_bool() == Some(true) {
        line += "  [collapsed]";
    }
    line.push('\n');
    line
}

fn parse_duration(s: &str) -> Result<f64, String> {
    let s = s.trim();
    if s.is_empty() {
        return Err("cannot be empty".into());
    }
    if let Some(rest) = s.strip_suffix("ms") {
        let ms: f64 = rest
            .trim()
            .parse()
            .map_err(|_| format!("invalid milliseconds in \"{s}\""))?;
        if ms < 0.0 || !ms.is_finite() {
            return Err("must be positive".into());
        }
        return Ok(ms / 1000.0);
    }
    if let Some(rest) = s.strip_suffix('s') {
        let sec: f64 = rest
            .trim()
            .parse()
            .map_err(|_| format!("invalid seconds in \"{s}\""))?;
        if sec < 0.0 || !sec.is_finite() {
            return Err("must be positive".into());
        }
        return Ok(sec);
    }
    if let Some(rest) = s.strip_suffix('m') {
        let min: f64 = rest
            .trim()
            .parse()
            .map_err(|_| format!("invalid minutes in \"{s}\""))?;
        if min < 0.0 || !min.is_finite() {
            return Err("must be positive".into());
        }
        return Ok(min * 60.0);
    }
    if let Some(rest) = s.strip_suffix('h') {
        let hr: f64 = rest
            .trim()
            .parse()
            .map_err(|_| format!("invalid hours in \"{s}\""))?;
        if hr < 0.0 || !hr.is_finite() {
            return Err("must be positive".into());
        }
        return Ok(hr * 3600.0);
    }
    if let Some(rest) = s.strip_suffix('d') {
        let days: f64 = rest
            .trim()
            .parse()
            .map_err(|_| format!("invalid days in \"{s}\""))?;
        if days < 0.0 || !days.is_finite() {
            return Err("must be positive".into());
        }
        return Ok(days * 86400.0);
    }
    let sec: f64 = s
        .parse()
        .map_err(|_| format!("invalid duration \"{s}\" (expected e.g. 10m, 30s, 1h, 500ms)"))?;
    if sec < 0.0 || !sec.is_finite() {
        return Err("must be positive".into());
    }
    Ok(sec)
}

/// A tab's splits as an indented outline, panes at their leaves.
fn outline(out: &mut String, node: &Value, panes: &[&Value], depth: usize) {
    if let Some(id) = node["pane"].as_str() {
        match panes.iter().find(|p| p["id"].as_str() == Some(id)) {
            Some(pane) => *out += &pane_line(pane, depth),
            None => *out += &format!("{} {id}\n", "  ".repeat(depth)),
        }
        return;
    }
    let ratio = node["ratio"]
        .as_f64()
        .map(|r| format!(" {:.0}%", r * 100.0))
        .unwrap_or_default();
    *out += &format!(
        "{}split {}{ratio}\n",
        "  ".repeat(depth),
        node["split"].as_str().unwrap_or("?")
    );
    for child in node["children"].as_array().into_iter().flatten() {
        outline(out, child, panes, depth + 1);
    }
}

/// `program` as execve needs it: a path. A name with a slash is taken as
/// it is; a bare name is looked up on `path`, as a shell does.
fn resolve(program: &str, path: &str) -> Option<String> {
    use std::os::unix::fs::PermissionsExt;
    if program.contains('/') {
        return Some(program.to_string());
    }
    path.split(':').filter(|d| !d.is_empty()).find_map(|dir| {
        let candidate = std::path::Path::new(dir).join(program);
        let meta = std::fs::metadata(&candidate).ok()?;
        (meta.is_file() && meta.permissions().mode() & 0o111 != 0)
            .then(|| candidate.to_string_lossy().into_owned())
    })
}

fn run_hooks(opts: &Options) -> Result<(), String> {
    let action = opts
        .args
        .get("action")
        .and_then(Value::as_str)
        .unwrap_or("list");
    let yes = opts
        .args
        .get("yes")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let diff_only = opts
        .args
        .get("diff_only")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let config_override = opts.args.get("config").and_then(Value::as_str);

    match action {
        "list" => hooks::list(opts.json),
        "status" => {
            let agent = opts.args.get("agent").and_then(Value::as_str);
            hooks::status(agent, opts.json)
        }
        "install" => {
            let agent = opts
                .args
                .get("agent")
                .and_then(Value::as_str)
                .ok_or("hooks install needs an agent name")?;
            hooks::install(agent, config_override, yes, diff_only, opts.json)
        }
        "uninstall" => {
            let agent = opts
                .args
                .get("agent")
                .and_then(Value::as_str)
                .ok_or("hooks uninstall needs an agent name")?;
            hooks::uninstall(agent, config_override, yes, diff_only, opts.json)
        }
        other => Err(format!("unknown hooks action '{other}'")),
    }
}

fn run_skills(opts: &Options) -> Result<(), String> {
    let action = opts
        .args
        .get("action")
        .and_then(Value::as_str)
        .unwrap_or("list");
    let yes = opts
        .args
        .get("yes")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let diff_only = opts
        .args
        .get("diff_only")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let skill_override = opts.args.get("skill_path").and_then(Value::as_str);

    match action {
        "list" => skills::list(opts.json),
        "status" => {
            let agent = opts.args.get("agent").and_then(Value::as_str);
            skills::status(agent, opts.json)
        }
        "install" => {
            let agent = opts
                .args
                .get("agent")
                .and_then(Value::as_str)
                .ok_or("skills install needs an agent name")?;
            skills::install(agent, skill_override, yes, diff_only, opts.json)
        }
        "uninstall" => {
            let agent = opts
                .args
                .get("agent")
                .and_then(Value::as_str)
                .ok_or("skills uninstall needs an agent name")?;
            skills::uninstall(agent, skill_override, yes, diff_only, opts.json)
        }
        other => Err(format!("unknown skills action '{other}'")),
    }
}

fn run_mcp(opts: &Options) -> Result<(), String> {
    let capabilities = match opts.args.get("capabilities").and_then(Value::as_str) {
        Some(s) => mcp::Capabilities::parse(s)?,
        None => mcp::Capabilities::all(),
    };

    let inherited = std::env::var("TAKO_SOCKET").ok();
    if opts.socket.is_none() && inherited.as_deref() == Some("") {
        return Err("remote control is unavailable in this Tako (remote-control = off, or another copy of Tako owns the socket)".into());
    }
    let socket_path = match opts.socket.clone().or(inherited) {
        Some(p) => p,
        None => socket::default_path(&opts.bundle_id)?,
    };

    let surface_id = opts
        .args
        .get("target")
        .and_then(Value::as_str)
        .map(String::from)
        .or_else(|| std::env::var("TAKO_SURFACE_ID").ok());

    let server = mcp::McpServer::new(socket_path, capabilities, surface_id);
    server.run_stdio().map_err(|e| format!("MCP stdio server error: {e}"))
}

fn decode_base64(s: &str) -> Result<Vec<u8>, String> {
    let mut out = Vec::with_capacity((s.len() * 3) / 4);
    let mut buf: u32 = 0;
    let mut bits: u32 = 0;
    for &b in s.as_bytes() {
        let val = match b {
            b'A'..=b'Z' => (b - b'A') as u32,
            b'a'..=b'z' => (b - b'a' + 26) as u32,
            b'0'..=b'9' => (b - b'0' + 52) as u32,
            b'+' => 62,
            b'/' => 63,
            b'=' | b'\r' | b'\n' | b' ' => continue,
            _ => return Err(format!("invalid base64 character: {}", b as char)),
        };
        buf = (buf << 6) | val;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((buf >> bits) as u8);
            buf &= (1 << bits) - 1;
        }
    }
    Ok(out)
}

fn handle_screenshot_output(opts: &Options, result: &Value) -> Result<String, String> {
    let b64 = result["data"]
        .as_str()
        .ok_or_else(|| "missing screenshot data in response".to_string())?;
    let bytes = decode_base64(b64)?;
    let id = result["id"].as_str().unwrap_or("pane");
    let width = result["width"].as_f64().unwrap_or(0.0) as u64;
    let height = result["height"].as_f64().unwrap_or(0.0) as u64;

    if let Some(out_path) = opts.args.get("out").and_then(Value::as_str) {
        let path = std::path::Path::new(out_path);
        if let Some(parent) = path.parent() {
            if !parent.as_os_str().is_empty() {
                let _ = std::fs::create_dir_all(parent);
            }
        }
        std::fs::write(path, &bytes)
            .map_err(|e| format!("failed to write screenshot to {}: {e}", path.display()))?;
        return Ok(format!(
            "saved screenshot of pane {id} to {} ({width}x{height} png)\n",
            path.display()
        ));
    }

    use std::io::IsTerminal;
    if !std::io::stdout().is_terminal() {
        use std::io::Write;
        let mut stdout = std::io::stdout().lock();
        stdout
            .write_all(&bytes)
            .map_err(|e| format!("failed to write screenshot to stdout: {e}"))?;
        let _ = stdout.flush();
        Ok(String::new())
    } else {
        let default_path = format!("/tmp/tako-screenshot-{id}.png");
        std::fs::write(&default_path, &bytes)
            .map_err(|e| format!("failed to write screenshot to {default_path}: {e}"))?;
        Ok(format!(
            "saved screenshot of pane {id} to {default_path} ({width}x{height} png)\n"
        ))
    }
}

fn main() -> ExitCode {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let opts = match parse(&argv) {
        Ok(o) => o,
        Err(e) => {
            // Asked for help, or nothing at all: the usage. A mistake: just
            // the mistake.
            if e.is_empty() {
                eprint!("{USAGE}");
            } else {
                eprintln!("takoctl: {e} (takoctl --help)");
            }
            return ExitCode::from(2);
        }
    };
    if opts.cmd == "hooks" {
        return match run_hooks(&opts) {
            Ok(()) => ExitCode::SUCCESS,
            Err(e) => {
                eprintln!("takoctl: {e}");
                ExitCode::from(1)
            }
        };
    }
    if opts.cmd == "skills" {
        return match run_skills(&opts) {
            Ok(()) => ExitCode::SUCCESS,
            Err(e) => {
                eprintln!("takoctl: {e}");
                ExitCode::from(1)
            }
        };
    }
    if opts.cmd == "mcp" {
        return match run_mcp(&opts) {
            Ok(()) => ExitCode::SUCCESS,
            Err(e) => {
                eprintln!("takoctl: {e}");
                ExitCode::from(1)
            }
        };
    }
    // Inside a Tako pane, TAKO_SOCKET is that copy's answer: its socket, or
    // empty when it serves none. Empty means stop -- never go looking for
    // another copy's socket instead.
    let inherited = std::env::var("TAKO_SOCKET").ok();
    if opts.socket.is_none() && inherited.as_deref() == Some("") {
        eprintln!("takoctl: remote control is unavailable in this Tako (remote-control = off, or another copy of Tako owns the socket)");
        return ExitCode::from(3);
    }
    let path = match opts.socket.clone().or(inherited) {
        Some(p) => p,
        None => match socket::default_path(&opts.bundle_id) {
            Ok(p) => p,
            Err(e) => {
                eprintln!("takoctl: {e}");
                return ExitCode::from(3);
            }
        },
    };
    let req = request(&opts, std::env::var("TAKO_SURFACE_ID").ok());
    if opts.cmd == "events" {
        let res = socket::stream_events(&path, &req, |line| {
            if let Ok(val) = serde_json::from_str::<Value>(line) {
                if val.get("ok") == Some(&Value::Bool(false)) {
                    if opts.json {
                        println!("{line}");
                    } else {
                        let error = &val["error"];
                        eprintln!(
                            "takoctl: {}: {}",
                            error["code"].as_str().unwrap_or("error"),
                            error["message"].as_str().unwrap_or("")
                        );
                    }
                    return Err("aborted".to_string());
                }
            }
            use std::io::Write;
            println!("{line}");
            let _ = std::io::stdout().flush();
            Ok(())
        });
        return match res {
            Ok(()) => ExitCode::SUCCESS,
            Err(e) if !e.sent => {
                eprintln!("takoctl: no Tako answers on {path}: {}", e.message);
                ExitCode::from(3)
            }
            Err(e) => {
                if e.message == "aborted" {
                    ExitCode::from(1)
                } else {
                    eprintln!("takoctl: event stream error: {}", e.message);
                    ExitCode::from(1)
                }
            }
        };
    }
    let answer = match socket::exchange_within(
        &path,
        &req,
        answer_limit(&opts),
        socket::MAX_ANSWER_BYTES,
    ) {
        Ok(a) => a,
        Err(e) if !e.sent => {
            eprintln!("takoctl: no Tako answers on {path}: {}", e.message);
            return ExitCode::from(3);
        }
        Err(e) => {
            // The request went out: it may or may not have been carried out.
            // Never sent again from here -- a second tab-new is a second tab.
            eprintln!("takoctl: unknown outcome: {} (the request was delivered and may have been carried out; not retried)", e.message);
            return ExitCode::from(4);
        }
    };
    let ok = answer["ok"].as_bool() == Some(true);
    if opts.json {
        println!("{answer}");
    } else if ok {
        if opts.cmd == "screenshot" {
            match handle_screenshot_output(&opts, &answer["result"]) {
                Ok(msg) => {
                    if !msg.is_empty() {
                        print!("{msg}");
                    }
                }
                Err(e) => {
                    eprintln!("takoctl: {e}");
                    return ExitCode::from(1);
                }
            }
        } else {
            print!("{}", render(&opts.cmd, &answer["result"]));
        }
    } else {
        let error = &answer["error"];
        eprintln!(
            "takoctl: {}: {}",
            error["code"].as_str().unwrap_or("error"),
            error["message"].as_str().unwrap_or("")
        );
        for c in error["candidates"].as_array().into_iter().flatten() {
            eprintln!("  {}", c.as_str().unwrap_or(""));
        }
    }
    if ok {
        if opts.cmd == "layout" && opts.args.get("action").and_then(Value::as_str) == Some("save") {
            if let Some(content) = answer["result"]["content"].as_str() {
                if let Some(path) = opts.args.get("path").and_then(Value::as_str) {
                    let _ = std::fs::write(path, content);
                }
            }
        }
        ExitCode::SUCCESS
    } else if opts.cmd == "ask" {
        let code = answer["error"]["code"].as_str().unwrap_or("");
        let msg = answer["error"]["message"].as_str().unwrap_or("");
        if code == "timeout" {
            ExitCode::from(2)
        } else if code == "notFound" || code == "pane_closed" || msg.contains("pane closed") {
            ExitCode::from(3)
        } else {
            ExitCode::from(1)
        }
    } else {
        ExitCode::from(1)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(s: &[&str]) -> Vec<String> {
        s.iter().map(|a| a.to_string()).collect()
    }

    #[test]
    fn options_and_target_reach_the_request() {
        let opts = parse(&args(&["tree", "--target", "ab12", "--json"])).unwrap();
        assert!(opts.json);
        let req = request(&opts, Some("1111".into()));
        assert_eq!(
            req,
            json!({"cmd": "tree", "args": {"target": "ab12"}, "from": "1111"})
        );
        // Outside a pane there is no "from".
        assert!(request(&opts, None).get("from").is_none());
        assert!(request(&opts, Some(String::new())).get("from").is_none());
    }

    #[test]
    fn text_commands_take_exactly_one_argument() {
        let opts = parse(&args(&["send", "ls -la", "--target", "ab", "--no-enter"])).unwrap();
        assert_eq!(
            request(&opts, None),
            json!({"cmd": "send", "args": {"text": "ls -la", "target": "ab", "enter": false}})
        );
        let opts = parse(&args(&["key", "ctrl+c"])).unwrap();
        assert_eq!(opts.args["key"], "ctrl+c");
        let opts = parse(&args(&["type", "--", "--not-an-option"])).unwrap();
        assert_eq!(opts.args["text"], "--not-an-option");
        let opts = parse(&args(&["text", "--lines", "3"])).unwrap();
        assert_eq!(opts.args["lines"], 3);
        assert!(parse(&args(&["send"])).is_err());
        assert!(parse(&args(&["send", "a", "b"])).is_err());
        assert!(parse(&args(&["text", "x"])).is_err());
        assert!(parse(&args(&["text", "--lines", "many"])).is_err());
    }

    #[test]
    fn run_and_wait_take_their_options() {
        let opts = parse(&args(&[
            "run",
            "--split",
            "down",
            "--wait",
            "--timeout",
            "90",
            "--lines",
            "5",
            "--",
            "/bin/echo",
            "a b",
            "--not-ours",
        ]))
        .unwrap();
        let req = request(&opts, None);
        assert_eq!(
            req["args"]["argv"],
            json!(["/bin/echo", "a b", "--not-ours"])
        );
        assert_eq!(req["args"]["split"], "down");
        assert_eq!(req["args"]["wait"], true);
        assert!(req["args"]["path"].is_string());
        assert_eq!(
            answer_limit(&opts),
            std::time::Duration::from_secs(90) + socket::TIMEOUT
        );
        // A bare name is found on PATH; an unknown one is a usage error.
        assert_eq!(resolve("sh", "/nope:/bin"), Some("/bin/sh".into()));
        assert_eq!(resolve("./x", "/bin"), Some("./x".into()));
        assert!(resolve("definitely-not-a-program-xyz", "/bin:/usr/bin").is_none());
        assert!(parse(&args(&["run", "ls"])).is_err());
        let opts = parse(&args(&["wait", "--command", "12@3"])).unwrap();
        assert_eq!(opts.args["command"], "12@3");
        let opts = parse(&args(&["wait", "--next"])).unwrap();
        assert_eq!(opts.args["next"], true);
        assert_eq!(
            answer_limit(&opts),
            std::time::Duration::from_secs(24 * 3600)
        );
        assert_eq!(
            answer_limit(&parse(&args(&["run", "--", "/bin/ls"])).unwrap()),
            socket::TIMEOUT
        );
        assert!(parse(&args(&["run"])).is_err());
        assert!(parse(&args(&["wait", "--timeout", "-1"])).is_err());
        assert!(parse(&args(&["wait", "--timeout", "1e300"])).is_err());
        assert!(parse(&args(&["last", "x"])).is_err());
    }

    #[test]
    fn a_command_reads_as_its_line_status_and_output() {
        let result = json!({"command": {"input": "make", "cwd": "/src", "running": false,
            "finished": true, "exitCode": 2}, "output": "error: x", "more": true, "state": "finished"});
        assert_eq!(
            command_report(&result),
            "$ make   (/src)   exit 2\n...\nerror: x\n"
        );
        let result = json!({"command": {"ref": "7@1", "input": "make", "running": false, "finished": true,
            "abandoned": false, "exitCode": 0}, "output": "", "incomplete": true});
        assert_eq!(
            command_report(&result),
            "$ make   exit 0   [7@1]\n(some of its output was written over or is no longer kept)\n"
        );
        let result = json!({"process": {"argv": ["/bin/ls", "/nope"], "running": false, "exitCode": 1},
            "output": "ls: /nope: No such file", "state": "finished"});
        assert_eq!(
            command_report(&result),
            "/bin/ls /nope   exit 1\nls: /nope: No such file\n"
        );
        let result = json!({"command": {"input": "sleep 9", "running": true}, "output": "", "state": "timeout"});
        assert_eq!(
            command_report(&result),
            "$ sleep 9   still running (timed out waiting)\n"
        );
        assert!(command_report(&json!({"command": null})).starts_with("no command"));
    }

    #[test]
    fn notify_takes_its_text_and_a_title() {
        let opts = parse(&args(&["notify", "build done", "--title", "CI"])).unwrap();
        assert_eq!(
            request(&opts, None),
            json!({"cmd": "notify", "args": {"text": "build done", "title": "CI"}})
        );
        assert!(parse(&args(&["notify"])).is_err());
    }

    #[test]
    fn find_groups_matches_by_pane_and_command() {
        let result = json!({"matches": [
            {"id": "aaaaaaaa-1", "place": "tako -- tab 1 of 2", "pane": null, "line": "error: one",
             "command": {"input": "make", "status": "✗ exit 2", "cwd": "/src"}},
            {"id": "aaaaaaaa-1", "place": "tako -- tab 1 of 2", "pane": null, "line": "error: two",
             "command": {"input": "make", "status": "✗ exit 2", "cwd": "/src"}},
            {"id": "bbbbbbbb-2", "place": "logs", "pane": "pane 2 of 2", "line": "kernel error"}],
            "more": true});
        assert_eq!(
            find_report(&result),
            "\
aaaaaaaa  tako -- tab 1 of 2
  $ make   ✗ exit 2   /src
    error: one
    error: two
bbbbbbbb  logs -- pane 2 of 2
    kernel error
... more matches (--limit N)
"
        );
        assert_eq!(
            find_report(&json!({"matches": [], "more": false})),
            "no matches\n"
        );
        let opts = parse(&args(&["find", "panic", "--limit", "5"])).unwrap();
        assert_eq!(
            request(&opts, None),
            json!({"cmd": "find", "args": {"text": "panic", "limit": 5}})
        );
    }

    #[test]
    fn a_dialog_reads_with_its_buttons_and_the_chosen_one() {
        let result = json!({"dialogs": [{"window": "window-1", "title": "Close Terminal?",
            "text": "A process is running.", "buttons": ["Cancel", "Close"], "selected": "Close"}]});
        assert_eq!(
            dialog_report(&result),
            "window-1  Close Terminal?\n  A process is running.\n  buttons: Cancel  [Close]\n"
        );
        assert_eq!(
            dialog_report(&json!({"dialogs": []})),
            "no question is up\n"
        );
        let opts = parse(&args(&["dialog", "--press", "Later"])).unwrap();
        assert_eq!(
            request(&opts, None),
            json!({"cmd": "dialog", "args": {"press": "Later"}})
        );
    }

    #[test]
    fn usage_errors_are_refused() {
        assert!(parse(&args(&[])).is_err());
        assert!(parse(&args(&["frobnicate"])).is_err());
        assert!(parse(&args(&["tree", "--target"])).is_err());
        assert!(parse(&args(&["tree", "--nope"])).is_err());
        assert!(parse(&args(&["tree", "extra"])).is_err());
    }

    #[test]
    fn a_tree_with_splits_reads_as_nested_splits() {
        let result = json!({"windows": [{"id": "w1", "tabs": [{"id": "t1", "index": 1, "title": "build",
            "selected": true,
            "layout": {"split": "right", "ratio": 0.5, "children": [
                {"pane": "p1"},
                {"split": "down", "ratio": 0.3, "children": [{"pane": "p2"}, {"pane": "p3"}]}]},
            "panes": [
                {"id": "p1", "cwd": "/src", "title": "zsh", "focused": true},
                {"id": "p2", "cwd": "/tmp", "title": "", "focused": false},
                {"id": "p3", "cwd": null, "title": "top", "focused": false}]}]}]});
        let want = [
            "window w1",
            "  tab 1  \"build\"  (shown)",
            "    split right 50%",
            "      *p1  /src  zsh",
            "      split down 30%",
            "         p2  /tmp  ",
            "         p3  -  top",
            "",
        ]
        .join("\n");
        assert_eq!(render("tree", &result), want);
    }

    #[test]
    fn a_tree_reads_as_an_outline() {
        let result = json!({"windows": [{"id": "w1", "tabs": [{"id": "t1", "panes": [
            {"id": "p1", "cwd": "/src", "title": "zsh", "focused": true},
            {"id": "p2", "cwd": null, "title": "", "focused": false}]}]}]});
        assert_eq!(
            render("tree", &result),
            "window w1\n  tab t1\n    *p1  /src  zsh\n     p2  -  \n"
        );
    }

    #[test]
    fn status_command_parses_get_set_clear_and_options() {
        // get (default)
        let opts = parse(&args(&["status"])).unwrap();
        assert_eq!(
            request(&opts, None),
            json!({"cmd": "status", "args": {"action": "get"}})
        );

        // get (explicit)
        let opts = parse(&args(&["status", "get"])).unwrap();
        assert_eq!(
            request(&opts, None),
            json!({"cmd": "status", "args": {"action": "get"}})
        );

        // set
        let opts = parse(&args(&[
            "status",
            "set",
            "working",
            "--text",
            "compiling",
            "--ttl",
            "10m",
        ]))
        .unwrap();
        assert_eq!(
            request(&opts, None),
            json!({
                "cmd": "status",
                "args": {
                    "action": "set",
                    "status": "working",
                    "text": "compiling",
                    "ttl": 600.0,
                }
            })
        );

        // clear
        let opts = parse(&args(&["status", "clear"])).unwrap();
        assert_eq!(
            request(&opts, None),
            json!({"cmd": "status", "args": {"action": "clear"}})
        );

        // errors
        assert!(parse(&args(&["status", "set"])).is_err());
        assert!(parse(&args(&["status", "unknown_action"])).is_err());
        assert!(parse(&args(&["status", "--ttl", "invalid"])).is_err());
    }

    #[test]
    fn status_report_renders_human_output() {
        let result = json!({
            "status": "working",
            "text": "compiling",
            "ttl": 298.5,
            "unread": true,
        });
        assert_eq!(
            status_report(&result),
            "working (compiling) [TTL: 4m 58s] [unread]\n"
        );

        let simple = json!({
            "status": "idle",
            "unread": false,
        });
        assert_eq!(status_report(&simple), "idle\n");
    }

    #[test]
    fn progress_command_parses_get_set_error_pause_indeterminate_clear() {
        // get (default)
        let opts = parse(&args(&["progress"])).unwrap();
        assert_eq!(
            request(&opts, None),
            json!({"cmd": "progress", "args": {"action": "get"}})
        );

        // get (explicit)
        let opts = parse(&args(&["progress", "get"])).unwrap();
        assert_eq!(
            request(&opts, None),
            json!({"cmd": "progress", "args": {"action": "get"}})
        );

        // number directly (e.g. 45)
        let opts = parse(&args(&["progress", "45"])).unwrap();
        assert_eq!(
            request(&opts, None),
            json!({"cmd": "progress", "args": {"action": "set", "value": 45}})
        );

        // set / normal with value
        let opts = parse(&args(&["progress", "set", "60"])).unwrap();
        assert_eq!(
            request(&opts, None),
            json!({"cmd": "progress", "args": {"action": "set", "value": 60}})
        );

        // indeterminate
        let opts = parse(&args(&["progress", "indeterminate"])).unwrap();
        assert_eq!(
            request(&opts, None),
            json!({"cmd": "progress", "args": {"action": "indeterminate"}})
        );

        // error with and without value
        let opts = parse(&args(&["progress", "error"])).unwrap();
        assert_eq!(
            request(&opts, None),
            json!({"cmd": "progress", "args": {"action": "error"}})
        );

        let opts = parse(&args(&["progress", "error", "100"])).unwrap();
        assert_eq!(
            request(&opts, None),
            json!({"cmd": "progress", "args": {"action": "error", "value": 100}})
        );

        // pause with and without value
        let opts = parse(&args(&["progress", "pause"])).unwrap();
        assert_eq!(
            request(&opts, None),
            json!({"cmd": "progress", "args": {"action": "pause"}})
        );

        let opts = parse(&args(&["progress", "pause", "75"])).unwrap();
        assert_eq!(
            request(&opts, None),
            json!({"cmd": "progress", "args": {"action": "pause", "value": 75}})
        );

        // clear
        let opts = parse(&args(&["progress", "clear"])).unwrap();
        assert_eq!(
            request(&opts, None),
            json!({"cmd": "progress", "args": {"action": "clear"}})
        );

        // errors
        assert!(parse(&args(&["progress", "101"])).is_err());
        assert!(parse(&args(&["progress", "error", "150"])).is_err());
        assert!(parse(&args(&["progress", "unknown_state"])).is_err());
    }

    #[test]
    fn progress_report_renders_human_output() {
        let normal = json!({
            "state": "normal",
            "progress": 42.0,
        });
        assert_eq!(progress_report(&normal), "normal (42%)\n");

        let err = json!({
            "state": "error",
            "progress": 99.0,
        });
        assert_eq!(progress_report(&err), "error (99%)\n");

        let indet = json!({
            "state": "indeterminate",
        });
        assert_eq!(progress_report(&indet), "indeterminate\n");

        let clear = json!({
            "state": "none",
        });
        assert_eq!(progress_report(&clear), "none\n");
    }

    #[test]
    fn hooks_command_parses_list_status_install_uninstall_and_flags() {
        // list (default)
        let opts = parse(&args(&["hooks"])).unwrap();
        assert_eq!(opts.cmd, "hooks");
        assert_eq!(opts.args["action"], "list");

        // list (explicit)
        let opts = parse(&args(&["hooks", "list"])).unwrap();
        assert_eq!(opts.cmd, "hooks");
        assert_eq!(opts.args["action"], "list");

        // status all
        let opts = parse(&args(&["hooks", "status"])).unwrap();
        assert_eq!(opts.args["action"], "status");
        assert!(opts.args.get("agent").is_none());

        // status specific agent
        let opts = parse(&args(&["hooks", "status", "claude"])).unwrap();
        assert_eq!(opts.args["action"], "status");
        assert_eq!(opts.args["agent"], "claude");

        // install with flags
        let opts = parse(&args(&[
            "hooks",
            "install",
            "gemini",
            "--yes",
            "--diff-only",
            "--config",
            "/tmp/test.json",
        ]))
        .unwrap();
        assert_eq!(opts.args["action"], "install");
        assert_eq!(opts.args["agent"], "gemini");
        assert_eq!(opts.args["yes"], true);
        assert_eq!(opts.args["diff_only"], true);
        assert_eq!(opts.args["config"], "/tmp/test.json");

        // uninstall with -y
        let opts = parse(&args(&["hooks", "uninstall", "codex", "-y"])).unwrap();
        assert_eq!(opts.args["action"], "uninstall");
        assert_eq!(opts.args["agent"], "codex");
        assert_eq!(opts.args["yes"], true);

        // errors
        assert!(parse(&args(&["hooks", "install"])).is_err());
        assert!(parse(&args(&["hooks", "uninstall"])).is_err());
        assert!(parse(&args(&["hooks", "invalid_action"])).is_err());
    }

    #[test]
    fn events_command_parses_filters_and_cursor() {
        let opts = parse(&args(&["events"])).unwrap();
        assert_eq!(opts.cmd, "events");
        assert!(opts.args.is_empty());

        let opts = parse(&args(&[
            "events",
            "--pane",
            "1234",
            "--tab",
            "5678",
            "--workspace",
            "my-ws",
            "--type",
            "command_start,command_end",
            "--cursor",
            "42",
            "--json",
        ]))
        .unwrap();
        assert_eq!(opts.cmd, "events");
        assert_eq!(opts.args["pane"], "1234");
        assert_eq!(opts.args["tab"], "5678");
        assert_eq!(opts.args["workspace"], "my-ws");
        assert_eq!(opts.args["type"], "command_start,command_end");
        assert_eq!(opts.args["cursor"], 42);
        assert!(opts.json);

        // Disallows positional arguments
        assert!(parse(&args(&["events", "unexpected"])).is_err());
        assert!(parse(&args(&["events", "--cursor", "not_a_number"])).is_err());
    }

    #[test]
    fn ask_command_parses_options_and_renders_json() {
        // Confirmation prompt
        let opts = parse(&args(&[
            "ask",
            "Deploy to production?",
            "--confirm",
            "--confirm-text",
            "Ship it",
            "--cancel-text",
            "Abort",
            "--title",
            "Deploy Prompt",
            "--target",
            "pane-1",
        ]))
        .unwrap();
        assert_eq!(opts.cmd, "ask");
        assert_eq!(opts.args["message"], "Deploy to production?");
        assert_eq!(opts.args["confirm"], true);
        assert_eq!(opts.args["confirm_text"], "Ship it");
        assert_eq!(opts.args["cancel_text"], "Abort");
        assert_eq!(opts.args["title"], "Deploy Prompt");
        assert_eq!(opts.args["target"], "pane-1");

        // Choice prompt with multiple flags
        let opts = parse(&args(&[
            "ask",
            "Select environment",
            "--choice",
            "dev",
            "--choice",
            "staging",
            "--choices",
            "prod,canary",
            "--timeout",
            "30s",
            "--default",
            "dev",
        ]))
        .unwrap();
        assert_eq!(opts.cmd, "ask");
        assert_eq!(opts.args["message"], "Select environment");
        assert_eq!(
            opts.args["choices"],
            json!(["dev", "staging", "prod", "canary"])
        );
        assert_eq!(opts.args["timeout"], 30.0);
        assert_eq!(opts.args["default"], "dev");
        assert_eq!(
            answer_limit(&opts),
            std::time::Duration::from_secs(30) + socket::TIMEOUT
        );

        // Text prompt
        let opts = parse(&args(&[
            "ask",
            "Enter commit message",
            "--text",
            "--placeholder",
            "feat: ...",
            "--timeout",
            "1m",
        ]))
        .unwrap();
        assert_eq!(opts.cmd, "ask");
        assert_eq!(opts.args["message"], "Enter commit message");
        assert_eq!(opts.args["placeholder"], "feat: ...");
        assert_eq!(opts.args["timeout"], 60.0);

        // Rendering prints JSON
        let result = json!({
            "answer": "Ship it",
            "confirmed": true,
            "type": "confirm",
            "id": "prompt-123"
        });
        let rendered = render("ask", &result);
        let parsed_rendered: Value = serde_json::from_str(&rendered).unwrap();
        assert_eq!(parsed_rendered["answer"], "Ship it");
        assert_eq!(parsed_rendered["type"], "confirm");
        assert!(rendered.ends_with('\n'));

        // Errors
        assert!(parse(&args(&["ask"])).is_err());
        assert!(parse(&args(&["ask", "one", "two"])).is_err());
    }

    #[test]
    fn workspace_subcommands_and_options_parsed_and_rendered() {
        // Defaults to list
        let opts = parse(&args(&["workspace"])).unwrap();
        assert_eq!(opts.cmd, "workspace");
        assert_eq!(opts.args["action"], "list");

        let opts = parse(&args(&["workspace", "list"])).unwrap();
        assert_eq!(opts.args["action"], "list");

        // Current
        let opts = parse(&args(&["workspace", "current"])).unwrap();
        assert_eq!(opts.args["action"], "current");

        // Switch
        let opts = parse(&args(&["workspace", "switch", "tako"])).unwrap();
        assert_eq!(opts.args["action"], "switch");
        assert_eq!(opts.args["name"], "tako");

        // Direct switch shorthand
        let opts = parse(&args(&["workspace", "tako"])).unwrap();
        assert_eq!(opts.args["action"], "switch");
        assert_eq!(opts.args["name"], "tako");

        // Create
        let opts = parse(&args(&[
            "workspace",
            "create",
            "frontend",
            "--root",
            "/src/frontend",
            "--color",
            "orange",
            "--icon",
            "globe",
        ]))
        .unwrap();
        assert_eq!(opts.args["action"], "create");
        assert_eq!(opts.args["name"], "frontend");
        assert_eq!(opts.args["root"], "/src/frontend");
        assert_eq!(opts.args["color"], "orange");
        assert_eq!(opts.args["icon"], "globe");

        // Delete
        let opts = parse(&args(&["workspace", "delete", "old-ws"])).unwrap();
        assert_eq!(opts.args["action"], "delete");
        assert_eq!(opts.args["name"], "old-ws");

        // Assign
        let opts = parse(&args(&[
            "workspace",
            "assign",
            "tab-xyz",
            "--workspace",
            "backend",
        ]))
        .unwrap();
        assert_eq!(opts.args["action"], "assign");
        assert_eq!(opts.args["tab"], "tab-xyz");
        assert_eq!(opts.args["workspace"], "backend");

        let opts = parse(&args(&["workspace", "assign", "--workspace", "backend"])).unwrap();
        assert_eq!(opts.args["action"], "assign");
        assert_eq!(opts.args["workspace"], "backend");
        assert!(opts.args.get("tab").is_none());

        // Render list
        let list_json = json!({
            "workspaces": [
                {
                    "name": "Default",
                    "is_active": true,
                    "tabs": ["t1", "t2"],
                    "attention_count": 0
                },
                {
                    "name": "Backend",
                    "is_active": false,
                    "tabs": ["t3"],
                    "attention_count": 2,
                    "root_directory": "/Users/test/backend"
                }
            ]
        });
        let rendered = render("workspace", &list_json);
        assert!(rendered.contains("* Default (2 tabs)"));
        assert!(rendered.contains("Backend (1 tabs) [2 unread]  /Users/test/backend"));

        // Render current
        let cur_json = json!({
            "name": "Tako",
            "tabs": ["t1"],
            "attention_count": 0,
            "root_directory": "/Users/test/tako"
        });
        let rendered_cur = render("workspace", &cur_json);
        assert!(rendered_cur.contains("Tako (1 tabs)"));
        assert!(rendered_cur.contains("/Users/test/tako"));

        // Render deleted
        let del_json = json!({"deleted": "OldWs"});
        assert_eq!(render("workspace", &del_json), "deleted OldWs\n");

        // Render assign
        let assign_json = json!({"tab": "tab-1", "workspace": "Backend"});
        assert_eq!(
            render("workspace", &assign_json),
            "assigned tab-1 to Backend\n"
        );

        // Errors
        assert!(parse(&args(&["workspace", "create"])).is_err());
        assert!(parse(&args(&["workspace", "delete"])).is_err());
        assert!(parse(&args(&["workspace", "assign"])).is_err());
    }

    #[test]
    fn layout_subcommands_and_options_parsed_and_rendered() {
        // Layout save
        let opts = parse(&args(&["layout", "save", "my-layout.json"])).unwrap();
        assert_eq!(opts.cmd, "layout");
        assert_eq!(opts.args["action"], "save");
        assert!(opts.args["path"].as_str().unwrap().ends_with("my-layout.json"));

        // Create temporary layout file for apply/approve/status tests
        let temp_dir = std::env::temp_dir();
        let temp_file = temp_dir.join(format!("tako_test_layout_{}.json", std::process::id()));
        let dummy_json = r#"{"version":1,"windows":[{"tabs":[{"root":{"cwd":"/tmp","command":["ls"]}}]}]}"#;
        std::fs::write(&temp_file, dummy_json).unwrap();
        let temp_path = temp_file.to_str().unwrap();

        // Layout apply
        let opts = parse(&args(&["layout", "apply", temp_path])).unwrap();
        assert_eq!(opts.cmd, "layout");
        assert_eq!(opts.args["action"], "apply");
        assert_eq!(opts.args["path"], temp_path);
        assert_eq!(opts.args["content"], dummy_json);
        assert_eq!(opts.args.get("approve"), None);

        // Layout apply with --approve
        let opts = parse(&args(&["layout", "apply", "--approve", temp_path])).unwrap();
        assert_eq!(opts.args["approve"], true);

        // Layout approve
        let opts = parse(&args(&["layout", "approve", temp_path])).unwrap();
        assert_eq!(opts.args["action"], "approve");
        assert_eq!(opts.args["path"], temp_path);
        assert_eq!(opts.args["content"], dummy_json);

        // Layout status
        let opts = parse(&args(&["layout", "status", temp_path])).unwrap();
        assert_eq!(opts.args["action"], "status");
        assert_eq!(opts.args["path"], temp_path);

        // Render save
        let save_json = json!({
            "saved": true,
            "path": "my-layout.json",
            "tabs": 2.0,
            "panes": 4.0
        });
        assert_eq!(
            render("layout", &save_json),
            "Saved layout to my-layout.json (2 tabs, 4 panes)\n"
        );

        // Render apply (trusted / programs started)
        let apply_trusted_json = json!({
            "applied": true,
            "path": "my-layout.json",
            "tabs": 1.0,
            "panes": 2.0,
            "programs_started": 2.0,
            "programs_suppressed": 0.0,
            "trusted": true
        });
        assert_eq!(
            render("layout", &apply_trusted_json),
            "Applied layout from my-layout.json (1 tab, 2 panes), 2 programs started\n"
        );

        // Render apply (untrusted / programs suppressed)
        let apply_untrusted_json = json!({
            "applied": true,
            "path": "my-layout.json",
            "tabs": 1.0,
            "panes": 2.0,
            "programs_started": 0.0,
            "programs_suppressed": 2.0,
            "trusted": false
        });
        assert_eq!(
            render("layout", &apply_untrusted_json),
            "Applied layout from my-layout.json (1 tab, 2 panes), 2 programs suppressed (untrusted layout)\n"
        );

        // Render approve
        let approve_json = json!({
            "approved": true,
            "path": "/path/to/layout.json",
            "sha256": "abcdef1234567890abcdef"
        });
        assert_eq!(
            render("layout", &approve_json),
            "Approved layout /path/to/layout.json (sha256: abcdef123456)\n"
        );

        // Render status
        let status_json = json!({
            "path": "/path/to/layout.json",
            "status": "trusted",
            "sha256": "abcdef1234567890abcdef"
        });
        assert_eq!(
            render("layout", &status_json),
            "Layout /path/to/layout.json: trusted (sha256: abcdef123456)\n"
        );

        // Clean up temp file
        let _ = std::fs::remove_file(temp_file);

        // Errors
        assert!(parse(&args(&["layout"])).is_err());
        assert!(parse(&args(&["layout", "save"])).is_err());
        assert!(parse(&args(&["layout", "apply"])).is_err());
        assert!(parse(&args(&["layout", "apply", "/nonexistent/file/path.json"])).is_err());
        assert!(parse(&args(&["layout", "approve"])).is_err());
        assert!(parse(&args(&["layout", "status"])).is_err());
    }

    #[test]
    fn action_subcommands_and_options_parsed_and_rendered() {
        // Action list
        let opts = parse(&args(&["action", "list"])).unwrap();
        assert_eq!(opts.cmd, "action");
        assert_eq!(opts.args["action"], "list");

        // Action list with path
        let opts = parse(&args(&["action", "list", "/path/to/project"])).unwrap();
        assert_eq!(opts.cmd, "action");
        assert_eq!(opts.args["action"], "list");
        assert_eq!(opts.args["path"], "/path/to/project");

        // Action run
        let opts = parse(&args(&["action", "run", "build"])).unwrap();
        assert_eq!(opts.cmd, "action");
        assert_eq!(opts.args["action"], "run");
        assert_eq!(opts.args["id"], "build");
        assert_eq!(opts.args.get("approve"), None);

        // Action run with --approve and --path
        let opts = parse(&args(&["action", "run", "--approve", "--path", "/my/proj", "test"])).unwrap();
        assert_eq!(opts.cmd, "action");
        assert_eq!(opts.args["action"], "run");
        assert_eq!(opts.args["id"], "test");
        assert_eq!(opts.args["approve"], true);
        assert_eq!(opts.args["path"], "/my/proj");

        // Action approve
        let opts = parse(&args(&["action", "approve", "/path/to/project"])).unwrap();
        assert_eq!(opts.cmd, "action");
        assert_eq!(opts.args["action"], "approve");
        assert_eq!(opts.args["path"], "/path/to/project");

        // Action status
        let opts = parse(&args(&["action", "status", "/path/to/project"])).unwrap();
        assert_eq!(opts.cmd, "action");
        assert_eq!(opts.args["action"], "status");
        assert_eq!(opts.args["path"], "/path/to/project");

        // Render list
        let list_json = json!({
            "project": "/Users/user/project",
            "status": "trusted",
            "actions": [
                {
                    "id": "build",
                    "title": "Build Project",
                    "target": "split",
                    "command": ["cargo", "build"]
                },
                {
                    "id": "test",
                    "title": "Run Tests",
                    "target": "new-tab",
                    "command": ["cargo", "test"]
                }
            ]
        });
        assert_eq!(
            render("action", &list_json),
            "Project actions for /Users/user/project [trusted]:\n  * build (split): Build Project\n      $ cargo build\n  * test (new-tab): Run Tests\n      $ cargo test\n"
        );

        // Render run
        let run_json = json!({
            "ran": true,
            "id": "build",
            "title": "Build Project",
            "target": "split",
            "cwd": "/Users/user/project"
        });
        assert_eq!(
            render("action", &run_json),
            "Ran action 'Build Project' (build) in split (cwd: /Users/user/project)\n"
        );

        // Render approve
        let approve_json = json!({
            "approved": true,
            "path": "/path/to/.tako/actions.json",
            "sha256": "1234567890abcdef"
        });
        assert_eq!(
            render("action", &approve_json),
            "Approved project actions at /path/to/.tako/actions.json (sha256: 1234567890ab)\n"
        );

        // Render status
        let status_json = json!({
            "path": "/path/to/.tako/actions.json",
            "status": "trusted",
            "sha256": "1234567890abcdef",
            "actions_count": 2.0
        });
        assert_eq!(
            render("action", &status_json),
            "Project actions /path/to/.tako/actions.json: trusted (sha256: 1234567890ab, 2 actions)\n"
        );

        // Errors
        assert!(parse(&args(&["action", "run"])).is_err());
        assert!(parse(&args(&["action", "unknown_sub"])).is_err());
    }

    #[test]
    fn task_subcommands_and_options_parsed_and_rendered() {
        // Task list
        let opts = parse(&args(&["task", "list"])).unwrap();
        assert_eq!(opts.cmd, "task");
        assert_eq!(opts.args["action"], "list");

        // Task list with path
        let opts = parse(&args(&["task", "list", "/my/repo"])).unwrap();
        assert_eq!(opts.cmd, "task");
        assert_eq!(opts.args["action"], "list");
        assert_eq!(opts.args["path"], "/my/repo");

        // Task create
        let opts = parse(&args(&[
            "task", "create", "agent-feature",
            "--branch", "feat/agent-ui",
            "--base", "main",
            "--target", "workspace",
            "--command", "cargo test",
            "--path", "/my/repo",
        ]))
        .unwrap();
        assert_eq!(opts.cmd, "task");
        assert_eq!(opts.args["action"], "create");
        assert_eq!(opts.args["name"], "agent-feature");
        assert_eq!(opts.args["branch"], "feat/agent-ui");
        assert_eq!(opts.args["base"], "main");
        assert_eq!(opts.args["target"], "workspace");
        assert_eq!(opts.args["command"], "cargo test");
        assert_eq!(opts.args["path"], "/my/repo");

        // Task status
        let opts = parse(&args(&["task", "status", "agent-feature", "--path", "/my/repo"])).unwrap();
        assert_eq!(opts.cmd, "task");
        assert_eq!(opts.args["action"], "status");
        assert_eq!(opts.args["name"], "agent-feature");
        assert_eq!(opts.args["path"], "/my/repo");

        // Task finish with --archive and --editor
        let opts = parse(&args(&["task", "finish", "agent-feature", "--archive", "--editor"])).unwrap();
        assert_eq!(opts.cmd, "task");
        assert_eq!(opts.args["action"], "finish");
        assert_eq!(opts.args["name"], "agent-feature");
        assert_eq!(opts.args["archive"], true);
        assert_eq!(opts.args["editor"], true);

        // Render list
        let list_json = json!({
            "tasks": [
                {
                    "name": "feat-1",
                    "branch": "task/feat-1",
                    "status": "running",
                    "worktree": "/path/to/worktree",
                    "ahead": 1.0,
                    "behind": 0.0,
                    "changed_files": 2.0
                }
            ]
        });
        assert_eq!(
            render("task", &list_json),
            "Worktree tasks:\n  * feat-1 (task/feat-1): [running] (worktree: /path/to/worktree)\n      ahead: 1, behind: 0, 2 changed files\n"
        );

        // Render create
        let create_json = json!({
            "created": true,
            "name": "feat-1",
            "branch": "task/feat-1",
            "base": "main",
            "target": "tab",
            "worktree": "/path/to/worktree"
        });
        assert_eq!(
            render("task", &create_json),
            "Created worktree task 'feat-1' on branch task/feat-1 (base: main, target: tab)\n  Worktree: /path/to/worktree\n"
        );

        // Render finish (archived)
        let finish_json = json!({
            "finished": true,
            "name": "feat-1",
            "archived": true,
            "opened_in_editor": false,
            "worktree": "/path/to/worktree"
        });
        assert_eq!(
            render("task", &finish_json),
            "Archived worktree task 'feat-1' (removed worktree at /path/to/worktree)\n"
        );

        // Render finish (editor)
        let finish_editor_json = json!({
            "finished": true,
            "name": "feat-1",
            "archived": false,
            "opened_in_editor": true,
            "worktree": "/path/to/worktree"
        });
        assert_eq!(
            render("task", &finish_editor_json),
            "Finished worktree task 'feat-1' (opened in editor at /path/to/worktree)\n"
        );

        // Render status
        let status_json = json!({
            "name": "feat-1",
            "branch": "task/feat-1",
            "status": "running",
            "worktree": "/path/to/worktree",
            "ahead": 0.0,
            "behind": 0.0,
            "changed_files": 0.0
        });
        assert_eq!(
            render("task", &status_json),
            "Worktree task 'feat-1' (task/feat-1): [running]\n  Worktree: /path/to/worktree\n  ahead: 0, behind: 0, clean\n"
        );

        // Errors
        assert!(parse(&args(&["task", "create"])).is_err());
        assert!(parse(&args(&["task", "status"])).is_err());
        assert!(parse(&args(&["task", "finish"])).is_err());
        assert!(parse(&args(&["task", "unknown_sub"])).is_err());
    }

    #[test]
    fn subagent_panes_and_hierarchy_options_and_rendering() {
        // Split with defaults and subagent flags
        let opts = parse(&args(&["split", "--child-of", "self", "--label", "worker"])).unwrap();
        assert_eq!(opts.cmd, "split");
        assert_eq!(opts.args["direction"], "right");
        assert_eq!(opts.args["child_of"], "self");
        assert_eq!(opts.args["label"], "worker");

        // Split with explicit direction and parent pane
        let opts = parse(&args(&["split", "down", "--child-of", "pane-abc"])).unwrap();
        assert_eq!(opts.cmd, "split");
        assert_eq!(opts.args["direction"], "down");
        assert_eq!(opts.args["child_of"], "pane-abc");

        // Collapse and expand parsing
        let opts = parse(&args(&["collapse"])).unwrap();
        assert_eq!(opts.cmd, "collapse");
        assert!(opts.args.get("target").is_none());

        let opts = parse(&args(&["collapse", "parent-pane"])).unwrap();
        assert_eq!(opts.cmd, "collapse");
        assert_eq!(opts.args["target"], "parent-pane");

        let opts = parse(&args(&["expand"])).unwrap();
        assert_eq!(opts.cmd, "expand");
        assert!(opts.args.get("target").is_none());

        let opts = parse(&args(&["expand", "parent-pane"])).unwrap();
        assert_eq!(opts.cmd, "expand");
        assert_eq!(opts.args["target"], "parent-pane");

        // Hierarchy tree rendering
        let tree_json = json!({
            "windows": [
                {
                    "id": "w1",
                    "tabs": [
                        {
                            "index": 1.0,
                            "title": "Agent Workspace",
                            "selected": true,
                            "panes": [
                                {
                                    "id": "p-parent",
                                    "cwd": "/src",
                                    "title": "main",
                                    "focused": true,
                                    "children": ["p-child1", "p-child2"],
                                    "childrenStatus": "2 subagents running"
                                },
                                {
                                    "id": "p-child1",
                                    "cwd": "/src",
                                    "title": "bash",
                                    "parent": "p-parent",
                                    "label": "worker"
                                },
                                {
                                    "id": "p-child2",
                                    "cwd": "/src",
                                    "title": "bash",
                                    "parent": "p-parent",
                                    "label": "researcher"
                                }
                            ]
                        }
                    ]
                }
            ]
        });

        let rendered = render("tree", &tree_json);
        assert_eq!(
            rendered,
            "window w1\n  tab 1  \"Agent Workspace\"  (shown)\n    *p-parent  /src  main  (2 subagents running)\n       p-child1  /src  bash  [worker]\n       p-child2  /src  bash  [researcher]\n"
        );

        // Collapsed parent hides children in tree
        let collapsed_tree_json = json!({
            "windows": [
                {
                    "id": "w1",
                    "tabs": [
                        {
                            "index": 1.0,
                            "title": "Agent Workspace",
                            "panes": [
                                {
                                    "id": "p-parent",
                                    "cwd": "/src",
                                    "title": "main",
                                    "children": ["p-child1"],
                                    "childrenStatus": "1 subagent running",
                                    "collapsed": true
                                },
                                {
                                    "id": "p-child1",
                                    "cwd": "/src",
                                    "title": "bash",
                                    "parent": "p-parent",
                                    "label": "worker"
                                }
                            ]
                        }
                    ]
                }
            ]
        });

        let rendered_collapsed = render("tree", &collapsed_tree_json);
        assert_eq!(
            rendered_collapsed,
            "window w1\n  tab 1  \"Agent Workspace\"\n     p-parent  /src  main  (1 subagent running)  [collapsed]\n"
        );
    }

    #[test]
    fn test_resume_cli_parsing() {
        let opts = parse(&[
            "resume".into(),
            "set".into(),
            "--cwd".into(),
            "/Users/alex/project".into(),
            "--".into(),
            "claude".into(),
            "--resume".into(),
            "session-123".into(),
        ])
        .unwrap();
        assert_eq!(opts.cmd, "resume");
        assert_eq!(opts.args["action"], "set");
        assert_eq!(opts.args["cwd"], "/Users/alex/project");
        assert_eq!(
            opts.args["argv"],
            json!(["claude", "--resume", "session-123"])
        );

        let opts_show = parse(&["resume".into(), "show".into(), "pane-1".into()]).unwrap();
        assert_eq!(opts_show.cmd, "resume");
        assert_eq!(opts_show.args["action"], "show");
        assert_eq!(opts_show.args["target"], "pane-1");

        let opts_clear = parse(&["resume".into(), "clear".into()]).unwrap();
        assert_eq!(opts_clear.args["action"], "clear");

        let opts_approve = parse(&[
            "resume".into(),
            "approve".into(),
            "--prefix".into(),
            "claude".into(),
            "pane-1".into(),
        ])
        .unwrap();
        assert_eq!(opts_approve.args["action"], "approve");
        assert_eq!(opts_approve.args["prefix"], "claude");
        assert_eq!(opts_approve.args["target"], "pane-1");
    }

    #[test]
    fn test_resume_report_rendering() {
        let show_json = json!({
            "id": "p-123",
            "has_resume": true,
            "argv": ["claude", "--resume", "abc"],
            "cwd": "/src/project",
            "is_imported": false,
            "approved": true,
            "recorded_at": "2026-10-05T02:00:00Z"
        });
        let rep = render("resume", &show_json);
        assert!(rep.contains("Pane: p-123"));
        assert!(rep.contains("Command: claude --resume abc"));
        assert!(rep.contains("Directory: /src/project"));
        assert!(rep.contains("Auto-run approved: yes"));

        let show_imported = json!({
            "id": "p-123",
            "has_resume": true,
            "argv": ["claude", "--resume", "abc"],
            "cwd": "/src/project",
            "is_imported": true,
            "approved": false,
            "recorded_at": "2026-10-05T02:00:00Z"
        });
        let rep_imported = render("resume", &show_imported);
        assert!(rep_imported.contains("Imported: yes (untrusted, auto-run disabled)"));

        let cleared_json = json!({
            "id": "p-123",
            "cleared": true
        });
        let rep_cleared = render("resume", &cleared_json);
        assert_eq!(rep_cleared, "Resume session cleared for pane p-123\n");
    }

    #[test]
    fn test_input_subcommands_and_options_parsed_and_rendered() {
        let opts_lock = parse(&[
            "input".into(),
            "lock".into(),
            "--owner".into(),
            "agent-1".into(),
            "--target".into(),
            "pane-a".into(),
        ])
        .unwrap();
        assert_eq!(opts_lock.cmd, "input");
        assert_eq!(opts_lock.args["subcommand"], "lock");
        assert_eq!(opts_lock.args["owner"], "agent-1");
        assert_eq!(opts_lock.args["target"], "pane-a");

        let opts_to = parse(&["input".into(), "takeover".into()]).unwrap();
        assert_eq!(opts_to.args["subcommand"], "takeover");

        let opts_hb = parse(&["input".into(), "handback".into()]).unwrap();
        assert_eq!(opts_hb.args["subcommand"], "handback");

        let opts_st = parse(&["input".into()]).unwrap();
        assert_eq!(opts_st.args["subcommand"], "status");

        let opts_send = parse(&[
            "send".into(),
            "echo hi".into(),
            "--client".into(),
            "claude-worker".into(),
        ])
        .unwrap();
        assert_eq!(opts_send.cmd, "send");
        assert_eq!(opts_send.args["text"], "echo hi");
        assert_eq!(opts_send.args["client"], "claude-worker");

        let locked_val = json!({
            "id": "p-1",
            "locked": true,
            "owner": "agent-1",
            "last_client": "takoctl",
            "last_action": "send"
        });
        let rep_locked = render("input", &locked_val);
        assert!(rep_locked.contains("Pane p-1: locked (owner: agent-1)"));
        assert!(rep_locked.contains("Last activity mark: takoctl: send"));

        let log_val = json!({
            "id": "p-1",
            "entries": [
                {
                    "client": "claude",
                    "action": "type",
                    "timestamp": "2026-10-05T02:00:00Z"
                }
            ]
        });
        let rep_log = render("input", &log_val);
        assert!(rep_log.contains("Automated input activity:"));
        assert!(rep_log.contains("[2026-10-05T02:00:00Z] claude: type"));
    }

    #[test]
    fn test_broadcast_subcommands_and_options_parsed_and_rendered() {
        let opts_start = parse(&[
            "broadcast".into(),
            "start".into(),
            "--panes".into(),
            "p1,p2,p3".into(),
        ])
        .unwrap();
        assert_eq!(opts_start.cmd, "broadcast");
        assert_eq!(opts_start.args["subcommand"], "start");
        assert_eq!(opts_start.args["panes"], "p1,p2,p3");

        let opts_stop = parse(&["broadcast".into(), "stop".into()]).unwrap();
        assert_eq!(opts_stop.cmd, "broadcast");
        assert_eq!(opts_stop.args["subcommand"], "stop");

        let opts_st = parse(&["broadcast".into()]).unwrap();
        assert_eq!(opts_st.cmd, "broadcast");
        assert_eq!(opts_st.args["subcommand"], "status");

        let active_val = json!({
            "active": true,
            "leader": "p1",
            "count": 3,
            "panes": ["p1", "p2", "p3"]
        });
        let rep_active = render("broadcast", &active_val);
        assert!(rep_active.contains("Broadcast active across 3 panes (leader: p1):"));
        assert!(rep_active.contains("* p1 (leader)"));
        assert!(rep_active.contains("p2"));
        assert!(rep_active.contains("p3"));

        let inactive_val = json!({
            "active": false
        });
        let rep_inactive = render("broadcast", &inactive_val);
        assert_eq!(rep_inactive, "Broadcast input is inactive.\n");
    }

    #[test]
    fn test_session_subcommands_and_options_parsed_and_rendered() {
        // 1. Export
        let opts_exp = parse(&[
            "session".into(),
            "export".into(),
            "/tmp/test_session.json".into(),
            "--window".into(),
            "win-1".into(),
        ])
        .unwrap();
        assert_eq!(opts_exp.cmd, "session");
        assert_eq!(opts_exp.args["action"], "export");
        assert_eq!(opts_exp.args["path"], "/tmp/test_session.json");
        assert_eq!(opts_exp.args["window"], "win-1");

        let exp_val = json!({
            "exported": true,
            "path": "/tmp/test_session.json",
            "windows": 2,
            "panes": 4,
            "resumes": 1,
            "format_version": 1
        });
        let rep_exp = render("session", &exp_val);
        assert!(rep_exp.contains("Exported session to /tmp/test_session.json (2 windows, 4 panes), 1 resume binding"));

        // 2. Import
        let opts_imp = parse(&[
            "session".into(),
            "import".into(),
            "/tmp/test_session.json".into(),
        ])
        .unwrap();
        assert_eq!(opts_imp.cmd, "session");
        assert_eq!(opts_imp.args["action"], "import");
        assert_eq!(opts_imp.args["path"], "/tmp/test_session.json");

        let imp_val = json!({
            "imported": true,
            "path": "/tmp/test_session.json",
            "windows": 2
        });
        let rep_imp = render("session", &imp_val);
        assert!(rep_imp.contains("Imported session from /tmp/test_session.json (2 windows created)"));
        assert!(rep_imp.contains("Untrusted session: control sequences dropped, nothing runs automatically"));

        // 3. Info
        let opts_info = parse(&[
            "session".into(),
            "info".into(),
            "/tmp/test_session.json".into(),
        ])
        .unwrap();
        assert_eq!(opts_info.cmd, "session");
        assert_eq!(opts_info.args["action"], "info");
        assert_eq!(opts_info.args["path"], "/tmp/test_session.json");

        let info_val = json!({
            "format_version": 1,
            "tako_version": "0.1.7",
            "exported_at": "2026-10-05T03:00:00Z",
            "windows": 2,
            "panes": 3,
            "resumes": 1
        });
        let rep_info = render("session", &info_val);
        assert!(rep_info.contains("Session file (format v1, exported by Tako 0.1.7 at 2026-10-05T03:00:00Z):"));
        assert!(rep_info.contains("2 windows, 3 panes, 1 resume record"));
    }

    #[test]
    fn test_skills_subcommands_and_options() {
        let opts_default = parse(&["skills".into()]).unwrap();
        assert_eq!(opts_default.cmd, "skills");
        assert_eq!(opts_default.args["action"], "list");

        let opts_list = parse(&["skills".into(), "list".into()]).unwrap();
        assert_eq!(opts_list.cmd, "skills");
        assert_eq!(opts_list.args["action"], "list");

        let opts_status = parse(&["skills".into(), "status".into(), "claude".into()]).unwrap();
        assert_eq!(opts_status.cmd, "skills");
        assert_eq!(opts_status.args["action"], "status");
        assert_eq!(opts_status.args["agent"], "claude");

        let opts_install = parse(&[
            "skills".into(),
            "install".into(),
            "gemini".into(),
            "--yes".into(),
            "--diff-only".into(),
            "--skill-path".into(),
            "/tmp/custom/SKILL.md".into(),
        ])
        .unwrap();
        assert_eq!(opts_install.cmd, "skills");
        assert_eq!(opts_install.args["action"], "install");
        assert_eq!(opts_install.args["agent"], "gemini");
        assert_eq!(opts_install.args["yes"], true);
        assert_eq!(opts_install.args["diff_only"], true);
        assert_eq!(opts_install.args["skill_path"], "/tmp/custom/SKILL.md");

        let opts_uninstall = parse(&["skills".into(), "uninstall".into(), "aider".into()]).unwrap();
        assert_eq!(opts_uninstall.cmd, "skills");
        assert_eq!(opts_uninstall.args["action"], "uninstall");
        assert_eq!(opts_uninstall.args["agent"], "aider");
    }

    #[test]
    fn test_mcp_command_and_capabilities_option() {
        let opts_mcp = parse(&["mcp".into()]).unwrap();
        assert_eq!(opts_mcp.cmd, "mcp");
        assert!(!opts_mcp.args.contains_key("capabilities"));

        let opts_scoped = parse(&[
            "mcp".into(),
            "--capabilities".into(),
            "read,signal".into(),
        ])
        .unwrap();
        assert_eq!(opts_scoped.cmd, "mcp");
        assert_eq!(opts_scoped.args["capabilities"], "read,signal");
    }

    #[test]
    fn test_overlay_subcommands_and_options_parsed_and_rendered() {
        // 1. Open
        let opts_open = parse(&[
            "overlay".into(),
            "open".into(),
            "/tmp/artifact.md".into(),
            "--split".into(),
            "right".into(),
            "--type".into(),
            "markdown".into(),
        ])
        .unwrap();
        assert_eq!(opts_open.cmd, "overlay");
        assert_eq!(opts_open.args["subcommand"], "open");
        assert_eq!(opts_open.args["file"], "/tmp/artifact.md");
        assert_eq!(opts_open.args["split"], "right");
        assert_eq!(opts_open.args["type"], "markdown");

        let open_val = json!({
            "id": "pane-1",
            "target": "pane-0",
            "open": true,
            "file": "/tmp/artifact.md",
            "title": "artifact.md",
            "type": "markdown",
            "sandboxed": "/tmp",
            "split": "right"
        });
        let rep_open = render("overlay", &open_val);
        assert!(rep_open.contains("Overlay active on pane pane-1 (split right):"));
        assert!(rep_open.contains("File: /tmp/artifact.md"));
        assert!(rep_open.contains("Type: markdown"));
        assert!(rep_open.contains("Sandboxed: /tmp"));

        // 2. Close
        let opts_close = parse(&["overlay".into(), "close".into()]).unwrap();
        assert_eq!(opts_close.cmd, "overlay");
        assert_eq!(opts_close.args["subcommand"], "close");

        let rep_closed = render("overlay", &json!({"id": "pane-1", "closed": true}));
        assert_eq!(rep_closed, "Closed overlay for pane pane-1.\n");

        let rep_not_closed = render("overlay", &json!({"id": "pane-1", "closed": false}));
        assert_eq!(rep_not_closed, "No active overlay to close on pane pane-1.\n");

        // 3. Status
        let opts_st = parse(&["overlay".into()]).unwrap();
        assert_eq!(opts_st.cmd, "overlay");
        assert_eq!(opts_st.args["subcommand"], "status");

        let rep_st_inactive = render("overlay", &json!({"id": "pane-1", "open": false}));
        assert_eq!(rep_st_inactive, "No overlay active on pane pane-1.\n");

        // 4. Reload
        let opts_reload = parse(&["overlay".into(), "reload".into()]).unwrap();
        assert_eq!(opts_reload.cmd, "overlay");
        assert_eq!(opts_reload.args["subcommand"], "reload");

        let rep_reload = render("overlay", &json!({"id": "pane-1", "reloaded": true}));
        assert_eq!(rep_reload, "Reloaded overlay for pane pane-1.\n");
    }

    #[test]
    fn test_text_styled_and_screenshot_options() {
        // 1. Text with --styled and --lines
        let opts_text = parse(&["text".into(), "--lines".into(), "50".into(), "--styled".into()]).unwrap();
        assert_eq!(opts_text.cmd, "text");
        assert_eq!(opts_text.args["lines"], 50);
        assert_eq!(opts_text.args["styled"], true);

        // 2. Screenshot with positional path
        let opts_ss1 = parse(&["screenshot".into(), "/tmp/screen.png".into()]).unwrap();
        assert_eq!(opts_ss1.cmd, "screenshot");
        assert_eq!(opts_ss1.args["out"], "/tmp/screen.png");

        // 3. Screenshot with --out flag
        let opts_ss2 = parse(&["screenshot".into(), "--out".into(), "/tmp/out.png".into()]).unwrap();
        assert_eq!(opts_ss2.cmd, "screenshot");
        assert_eq!(opts_ss2.args["out"], "/tmp/out.png");

        // 4. Render screenshot
        let ss_val = json!({
            "id": "pane-1",
            "width": 800,
            "height": 600,
            "format": "png",
            "data": "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVR4nGNiAAAABgADNjd8qAAAAABJRU5ErkJggg=="
        });
        let rep_ss = render("screenshot", &ss_val);
        assert_eq!(rep_ss, "screenshot of pane pane-1 (800x600 png)\n");

        // 5. Base64 decode verification
        let bytes = decode_base64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVR4nGNiAAAABgADNjd8qAAAAABJRU5ErkJggg==").unwrap();
        assert_eq!(&bytes[0..8], &[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
    }
}

