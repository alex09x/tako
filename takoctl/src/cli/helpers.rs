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
