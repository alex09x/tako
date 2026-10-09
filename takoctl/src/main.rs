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

mod cli;
mod hooks;
mod mcp;
mod reports;
mod screenshot;
mod skills;
mod socket;

#[cfg(test)]
mod tests;

pub use cli::*;
pub use reports::*;
pub use screenshot::*;

use std::process::ExitCode;

use serde_json::Value;

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
    if opts.socket.is_none() && !opts.bundle_id_explicit && inherited.as_deref() == Some("") {
        return Err("remote control is unavailable in this Tako (remote-control = off, or another copy of Tako owns the socket)".into());
    }
    let socket_path = if let Some(s) = opts.socket.clone() {
        s
    } else if opts.bundle_id_explicit {
        socket::default_path(&opts.bundle_id)?
    } else if let Some(p) = inherited {
        p
    } else {
        socket::default_path(&opts.bundle_id)?
    };

    let surface_id = opts
        .args
        .get("target")
        .and_then(Value::as_str)
        .map(String::from)
        .or_else(|| std::env::var("TAKO_SURFACE_ID").ok());

    let token = resolve_token(opts, &socket_path);
    let server =
        mcp::McpServer::new(socket_path, capabilities, surface_id).with_token(token);
    server
        .run_stdio()
        .map_err(|e| format!("MCP stdio server error: {e}"))
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
    if opts.cmd == "diagnose" {
        let app_result = (|| {
            let inherited = std::env::var("TAKO_SOCKET").ok();
            if opts.socket.is_none() && !opts.bundle_id_explicit && inherited.as_deref() == Some("") {
                return None;
            }
            let path = if let Some(s) = opts.socket.clone() {
                Some(s)
            } else if opts.bundle_id_explicit {
                socket::default_path(&opts.bundle_id).ok()
            } else if let Some(p) = inherited {
                Some(p)
            } else {
                socket::default_path(&opts.bundle_id).ok()
            }?;
            let mut opts = opts.clone();
            opts.token = resolve_token(&opts, &path);
            let req = request(&opts, std::env::var("TAKO_SURFACE_ID").ok());
            let ans = socket::exchange_within(
                &path,
                &req,
                std::time::Duration::from_millis(500),
                socket::MAX_ANSWER_BYTES,
            )
            .ok()?;
            if ans["ok"].as_bool() == Some(true) {
                Some(ans["result"].clone())
            } else {
                None
            }
        })();

        return match handle_diagnose(&opts, app_result.as_ref()) {
            Ok(msg) => {
                if !msg.is_empty() {
                    print!("{msg}");
                }
                ExitCode::SUCCESS
            }
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
    if opts.socket.is_none() && !opts.bundle_id_explicit && inherited.as_deref() == Some("") {
        eprintln!(
            "takoctl: remote control is unavailable in this Tako (remote-control = off, or another copy of Tako owns the socket)"
        );
        return ExitCode::from(3);
    }
    let path = if let Some(s) = opts.socket.clone() {
        s
    } else if opts.bundle_id_explicit {
        match socket::default_path(&opts.bundle_id) {
            Ok(p) => p,
            Err(e) => {
                eprintln!("takoctl: {e}");
                return ExitCode::from(3);
            }
        }
    } else if let Some(p) = inherited {
        p
    } else {
        match socket::default_path(&opts.bundle_id) {
            Ok(p) => p,
            Err(e) => {
                eprintln!("takoctl: {e}");
                return ExitCode::from(3);
            }
        }
    };
    let mut opts = opts;
    opts.token = resolve_token(&opts, &path);
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
            eprintln!(
                "takoctl: unknown outcome: {} (the request was delivered and may have been carried out; not retried)",
                e.message
            );
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
