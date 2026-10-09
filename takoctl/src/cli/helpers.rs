/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use serde_json::{Value, json};

use super::Options;
use crate::socket;

/// The request line: the command, its arguments, and the pane it is sent
/// from when it runs inside one.
pub fn request(opts: &Options, from: Option<String>) -> Value {
    let mut req = json!({"cmd": opts.cmd, "args": Value::Object(opts.args.clone())});
    if let Some(from) = from.filter(|f| !f.is_empty()) {
        req["from"] = Value::String(from);
    }
    if let Some(token) = &opts.token {
        req["token"] = Value::String(token.clone());
    }
    if let Some(client) = &opts.client {
        req["client"] = Value::String(client.clone());
    }
    if let Some(scopes) = &opts.scopes {
        req["scopes"] = Value::Array(scopes.iter().map(|s| Value::String(s.clone())).collect());
    }
    req
}

/// Resolves an authentication token for the target control socket: explicit CLI token,
/// target token file ({path}.token), or ambient environment variables.
pub fn resolve_token(opts: &Options, path: &str) -> Option<String> {
    if let Some(tok) = &opts.token {
        return Some(tok.clone());
    }
    let token_from_file = std::fs::read_to_string(format!("{path}.token"))
        .ok()
        .map(|t| t.trim().to_string())
        .filter(|t| !t.is_empty());
    let token_from_env = std::env::var("TAKO_CONTROL_TOKEN")
        .or_else(|_| std::env::var("TAKO_AUTH_TOKEN"))
        .ok()
        .map(|t| t.trim().to_string())
        .filter(|t| !t.is_empty());
    if opts.bundle_id_explicit || opts.socket.is_some() {
        token_from_file.or(token_from_env)
    } else {
        token_from_env.or(token_from_file)
    }
}

pub fn answer_limit(opts: &Options) -> std::time::Duration {
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
pub fn parse_duration(s: &str) -> Result<f64, String> {
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

pub fn dispatch_and_validate(
    cmd: &str,
    args: &mut serde_json::Map<String, Value>,
    positional: &mut Vec<String>,
    dashdash: bool,
    client: Option<&str>,
    scopes: Option<&[String]>,
    description: Option<&str>,
    token: Option<&str>,
) -> Result<(), String> {
    let handled = super::control::parse(
        cmd,
        args,
        positional,
        client,
        scopes,
        description,
        token,
    )?
    .or(super::session::parse(cmd, args, positional)?)
    .or(super::layout::parse(cmd, args, positional)?)
    .or(super::inspect::parse(cmd, args, positional, dashdash)?)
    .or(super::review::parse(cmd, args, positional)?)
    .or(super::diagnose::parse(cmd, args, positional)?);

    let wants = if handled.is_some() {
        None
    } else {
        match cmd {
            "version" | "tree" | "text" | "tab-new" | "focus" | "close" | "last" | "wait"
            | "dialog" | "events" | "mcp" | "diagnose" => None,
            "title" => Some("title"),
            "send" | "type" | "notify" | "find" => Some("text"),
            "ask" => Some("message"),
            "key" => Some("key"),
            _ => return Err(format!("unknown command {cmd}")),
        }
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
    Ok(())
}

