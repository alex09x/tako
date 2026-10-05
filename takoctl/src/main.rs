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
  text                    print the pane's text (--lines N: the last N lines)
  tab-new                 a new tab in the pane's window (--cwd DIR, --no-select); prints its pane id
  split DIRECTION         split the pane: right, left, down or up (--cwd DIR); prints the new pane id
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
  hooks list              list supported coding-agent hook adapters and their install status
  hooks status [AGENT]    show hook installation status for AGENT or all agents
  hooks install AGENT     install Tako lifecycle hooks into AGENT's configuration
                          (--yes: skip confirmation; --diff-only: only print diff; --config PATH)
  hooks uninstall AGENT   remove Tako lifecycle hooks from AGENT's configuration
                          (--yes: skip confirmation; --diff-only: only print diff; --config PATH)

options:
  --target ID|PREFIX|self|active   the pane (default: this pane, or the active one)
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
  --lines N               last, wait, run --wait: at most the last N lines of output
  --text TEXT             status text (truncated to 128 characters)
  --ttl DURATION          status time-to-live (e.g. 10m, 30s, 1h, 500ms)
  --timeout DURATION      ask, wait, run --wait: timeout (e.g. 30s, 1m, 10)
  --yes, -y               skip confirmation prompt for hooks install/uninstall
  --diff-only             print proposed diff without writing files
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
            "--diff-only" => {
                args.insert("diff_only".into(), Value::Bool(true));
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
            "--cursor" => {
                let n: u64 = value("--cursor")?
                    .parse()
                    .map_err(|_| "--cursor needs a number".to_string())?;
                args.insert("cursor".into(), Value::from(n));
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
        | "dialog" | "events" => None,
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
        "split" => Some("direction"),
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
            out
        }
        "text" => {
            let mut out = result["text"].as_str().unwrap_or("").to_string();
            out.push('\n');
            out
        }
        "send" | "type" | "key" | "focus" | "title" | "notify" => String::new(),
        "tab-new" | "split" => format!("{}\n", result["id"].as_str().unwrap_or("")),
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
        _ => format!("{result}\n"),
    }
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
    if let Some(status) = pane["status"].as_str() {
        if status != "unknown" {
            line += &format!("  [{status}");
            if let Some(text) = pane["statusText"].as_str() {
                line += &format!(": {text}");
            }
            line.push(']');
        }
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
        print!("{}", render(&opts.cmd, &answer["result"]));
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
}
