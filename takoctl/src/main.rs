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

mod socket;

use std::process::ExitCode;

use serde_json::{Map, Value, json};

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

options:
  --target ID|PREFIX|self|active   the pane (default: this pane, or the active one)
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
    let mut bundle_id = std::env::var("TAKO_BUNDLE_ID").unwrap_or_else(|_| "com.tako-core.terminal".into());
    let mut positional: Vec<String> = Vec::new();
    let mut it = argv.iter();
    while let Some(arg) = it.next() {
        let mut value = |name: &str| {
            it.next().cloned().ok_or_else(|| format!("{name} needs a value"))
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
                let n: u64 = value("--lines")?.parse().map_err(|_| "--lines needs a number".to_string())?;
                args.insert("lines".into(), Value::from(n));
            }
            "--" => positional.extend(it.by_ref().cloned()),
            "--cwd" => {
                args.insert("cwd".into(), Value::String(value("--cwd")?));
            }
            "--no-select" => {
                args.insert("select".into(), Value::Bool(false));
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
        "version" | "tree" | "text" | "tab-new" | "focus" | "close" => None,
        "split" => Some("direction"),
        "title" => Some("title"),
        "send" | "type" => Some("text"),
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
    Ok(Options { cmd, args, json, socket, bundle_id })
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
                    out += &format!("  tab {}\n", tab["id"].as_str().unwrap_or(""));
                    for pane in tab["panes"].as_array().into_iter().flatten() {
                        let mark = if pane["focused"].as_bool() == Some(true) { "*" } else { " " };
                        out += &format!(
                            "   {mark}{}  {}  {}\n",
                            pane["id"].as_str().unwrap_or(""),
                            pane["cwd"].as_str().unwrap_or("-"),
                            pane["title"].as_str().unwrap_or("")
                        );
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
        "send" | "type" | "key" | "focus" | "title" => String::new(),
        "tab-new" | "split" => format!("{}\n", result["id"].as_str().unwrap_or("")),
        "close" => format!("{}\n", result["state"].as_str().unwrap_or("")),
        _ => format!("{result}\n"),
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
    let answer = match socket::exchange(&path, &req) {
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
    if ok { ExitCode::SUCCESS } else { ExitCode::from(1) }
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
        assert_eq!(req, json!({"cmd": "tree", "args": {"target": "ab12"}, "from": "1111"}));
        // Outside a pane there is no "from".
        assert!(request(&opts, None).get("from").is_none());
        assert!(request(&opts, Some(String::new())).get("from").is_none());
    }

    #[test]
    fn text_commands_take_exactly_one_argument() {
        let opts = parse(&args(&["send", "ls -la", "--target", "ab", "--no-enter"])).unwrap();
        assert_eq!(request(&opts, None),
            json!({"cmd": "send", "args": {"text": "ls -la", "target": "ab", "enter": false}}));
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
    fn usage_errors_are_refused() {
        assert!(parse(&args(&[])).is_err());
        assert!(parse(&args(&["frobnicate"])).is_err());
        assert!(parse(&args(&["tree", "--target"])).is_err());
        assert!(parse(&args(&["tree", "--nope"])).is_err());
        assert!(parse(&args(&["tree", "extra"])).is_err());
    }

    #[test]
    fn a_tree_reads_as_an_outline() {
        let result = json!({"windows": [{"id": "w1", "tabs": [{"id": "t1", "panes": [
            {"id": "p1", "cwd": "/src", "title": "zsh", "focused": true},
            {"id": "p2", "cwd": null, "title": "", "focused": false}]}]}]});
        assert_eq!(render("tree", &result),
            "window w1\n  tab t1\n   *p1  /src  zsh\n    p2  -  \n");
    }
}
