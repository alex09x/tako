/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use std::time::Duration;

use serde_json::{Map, Value};

use crate::mcp::capabilities::Capabilities;
use crate::socket;

pub fn parse_timeout_seconds(s: &str) -> Result<f64, String> {
    let s = s.trim();
    if let Some(rest) = s.strip_suffix("ms") {
        let ms: f64 = rest.trim().parse().map_err(|_| format!("invalid duration '{s}'"))?;
        return Ok(ms / 1000.0);
    }
    if let Some(rest) = s.strip_suffix('s') {
        let sec: f64 = rest.trim().parse().map_err(|_| format!("invalid duration '{s}'"))?;
        return Ok(sec);
    }
    if let Some(rest) = s.strip_suffix('m') {
        let m: f64 = rest.trim().parse().map_err(|_| format!("invalid duration '{s}'"))?;
        return Ok(m * 60.0);
    }
    if let Some(rest) = s.strip_suffix('h') {
        let h: f64 = rest.trim().parse().map_err(|_| format!("invalid duration '{s}'"))?;
        return Ok(h * 3600.0);
    }
    s.parse::<f64>().map_err(|_| format!("invalid duration '{s}'"))
}

pub fn determine_timeout(name: &str, args: &Value) -> Duration {
    if name == "tako_wait" || name == "tako_ask" || (name == "tako_run" && args.get("wait") == Some(&Value::Bool(true))) {
        if let Some(t_str) = args.get("timeout").and_then(Value::as_str) {
            if let Ok(sec) = parse_timeout_seconds(t_str) {
                return Duration::from_secs_f64(sec) + socket::TIMEOUT;
            }
        }
        return Duration::from_secs(24 * 3600);
    }
    socket::TIMEOUT
}

pub fn build_socket_request(
    capabilities: &Capabilities,
    surface_id: Option<&str>,
    token: Option<&str>,
    name: &str,
    args: &Value,
) -> Result<Value, String> {
    let mut req_args = Map::new();

    // Default target to surface_id if present
    let target = args
        .get("target")
        .and_then(Value::as_str)
        .map(String::from)
        .or_else(|| surface_id.map(String::from));

    if let Some(t) = target {
        req_args.insert("target".into(), Value::String(t));
    }

    let cmd = match name {
        "tako_tree" => "tree",
        "tako_split" => {
            let dir = args.get("direction").and_then(Value::as_str).unwrap_or("right");
            req_args.insert("direction".into(), Value::String(dir.into()));
            if let Some(child_of) = args.get("child_of").and_then(Value::as_str) {
                req_args.insert("child_of".into(), Value::String(child_of.into()));
            }
            if let Some(label) = args.get("label").and_then(Value::as_str) {
                req_args.insert("label".into(), Value::String(label.into()));
            }
            if let Some(cwd) = args.get("cwd").and_then(Value::as_str) {
                req_args.insert("cwd".into(), Value::String(cwd.into()));
            }
            "split"
        }
        "tako_run" => {
            let program = args
                .get("program")
                .and_then(Value::as_str)
                .ok_or_else(|| "missing required field 'program'".to_string())?;

            let mut argv = vec![Value::String(program.into())];
            if let Some(items) = args.get("args").and_then(Value::as_array) {
                argv.extend(items.clone());
            }
            req_args.insert("argv".into(), Value::Array(argv));

            if let Some(split) = args.get("split").and_then(Value::as_str) {
                req_args.insert("split".into(), Value::String(split.into()));
            }
            if let Some(cwd) = args.get("cwd").and_then(Value::as_str) {
                req_args.insert("cwd".into(), Value::String(cwd.into()));
            }
            if let Some(wait) = args.get("wait").and_then(Value::as_bool) {
                req_args.insert("wait".into(), Value::Bool(wait));
            }
            if let Some(timeout) = args.get("timeout").and_then(Value::as_str) {
                let sec = parse_timeout_seconds(timeout)?;
                req_args.insert("timeout".into(), Value::from(sec));
            }
            "run"
        }
        "tako_wait" => {
            if let Some(command) = args.get("command").and_then(Value::as_str) {
                req_args.insert("command".into(), Value::String(command.into()));
            }
            if let Some(next) = args.get("next").and_then(Value::as_bool) {
                req_args.insert("next".into(), Value::Bool(next));
            }
            if let Some(timeout) = args.get("timeout").and_then(Value::as_str) {
                let sec = parse_timeout_seconds(timeout)?;
                req_args.insert("timeout".into(), Value::from(sec));
            }
            if let Some(lines) = args.get("lines").and_then(Value::as_i64) {
                req_args.insert("lines".into(), Value::from(lines));
            }
            "wait"
        }
        "tako_last" => {
            if let Some(lines) = args.get("lines").and_then(Value::as_i64) {
                req_args.insert("lines".into(), Value::from(lines));
            }
            "last"
        }
        "tako_find" => {
            let query = args
                .get("query")
                .and_then(Value::as_str)
                .ok_or_else(|| "missing required field 'query'".to_string())?;
            req_args.insert("query".into(), Value::String(query.into()));
            if let Some(limit) = args.get("limit").and_then(Value::as_i64) {
                req_args.insert("limit".into(), Value::from(limit));
            }
            "find"
        }
        "tako_notify" => {
            let text = args
                .get("text")
                .and_then(Value::as_str)
                .ok_or_else(|| "missing required field 'text'".to_string())?;
            req_args.insert("text".into(), Value::String(text.into()));
            if let Some(title) = args.get("title").and_then(Value::as_str) {
                req_args.insert("title".into(), Value::String(title.into()));
            }
            "notify"
        }
        "tako_status" => {
            let status = args.get("status").and_then(Value::as_str).unwrap_or("get");
            if status == "clear" {
                req_args.insert("action".into(), Value::String("clear".into()));
            } else if status == "get" {
                req_args.insert("action".into(), Value::String("get".into()));
            } else {
                req_args.insert("action".into(), Value::String("set".into()));
                req_args.insert("status".into(), Value::String(status.into()));
                if let Some(text) = args.get("text").and_then(Value::as_str) {
                    req_args.insert("text".into(), Value::String(text.into()));
                }
                if let Some(ttl) = args.get("ttl").and_then(Value::as_str) {
                    let sec = parse_timeout_seconds(ttl)?;
                    req_args.insert("ttl".into(), Value::from(sec));
                }
            }
            "status"
        }
        "tako_progress" => {
            let state = args.get("state").and_then(Value::as_str).unwrap_or("get");
            let state_lower = state.to_lowercase();
            if let Ok(num) = state.parse::<u64>() {
                req_args.insert("action".into(), Value::String("set".into()));
                req_args.insert("value".into(), Value::from(num));
            } else {
                match state_lower.as_str() {
                    "get" => {
                        req_args.insert("action".into(), Value::String("get".into()));
                    }
                    "clear" | "none" | "reset" => {
                        req_args.insert("action".into(), Value::String("clear".into()));
                    }
                    "indeterminate" | "error" | "pause" | "set" => {
                        req_args.insert("action".into(), Value::String(state_lower));
                    }
                    other => {
                        return Err(format!("unknown progress state '{other}'"));
                    }
                }
            }
            "progress"
        }
        "tako_ask" => {
            let message = args
                .get("message")
                .and_then(Value::as_str)
                .ok_or_else(|| "missing required field 'message'".to_string())?;
            req_args.insert("message".into(), Value::String(message.into()));

            if let Some(choices) = args.get("choices").and_then(Value::as_array) {
                req_args.insert("choices".into(), Value::Array(choices.clone()));
            }
            if let Some(confirm) = args.get("confirm").and_then(Value::as_bool) {
                req_args.insert("confirm".into(), Value::Bool(confirm));
            }
            if let Some(placeholder) = args.get("placeholder").and_then(Value::as_str) {
                req_args.insert("placeholder".into(), Value::String(placeholder.into()));
            }
            if let Some(default_val) = args.get("default").and_then(Value::as_str) {
                req_args.insert("default".into(), Value::String(default_val.into()));
            }
            if let Some(title) = args.get("title").and_then(Value::as_str) {
                req_args.insert("title".into(), Value::String(title.into()));
            }
            if let Some(timeout) = args.get("timeout").and_then(Value::as_str) {
                let sec = parse_timeout_seconds(timeout)?;
                req_args.insert("timeout".into(), Value::from(sec));
            }
            "ask"
        }
        "tako_overlay_open" => {
            let file = args
                .get("file")
                .and_then(Value::as_str)
                .ok_or_else(|| "missing required field 'file'".to_string())?;
            req_args.insert("subcommand".into(), Value::String("open".into()));
            req_args.insert("file".into(), Value::String(file.into()));
            if let Some(split) = args.get("split").and_then(Value::as_str) {
                req_args.insert("split".into(), Value::String(split.into()));
            }
            if let Some(type_str) = args.get("type").and_then(Value::as_str) {
                req_args.insert("type".into(), Value::String(type_str.into()));
            }
            "overlay"
        }
        "tako_overlay_close" => {
            req_args.insert("subcommand".into(), Value::String("close".into()));
            "overlay"
        }
        "tako_overlay_status" => {
            req_args.insert("subcommand".into(), Value::String("status".into()));
            "overlay"
        }
        "tako_text" => {
            if let Some(lines) = args.get("lines").and_then(Value::as_i64) {
                req_args.insert("lines".into(), Value::from(lines));
            }
            if let Some(styled) = args.get("styled").and_then(Value::as_bool) {
                req_args.insert("styled".into(), Value::Bool(styled));
            }
            "text"
        }
        "tako_screenshot" => "screenshot",
        "tako_review_open" => {
            let task = args
                .get("task")
                .or_else(|| args.get("worktree"))
                .and_then(Value::as_str)
                .ok_or_else(|| "missing required field 'task'".to_string())?;
            req_args.insert("subcommand".into(), Value::String("open".into()));
            req_args.insert("task".into(), Value::String(task.into()));
            if let Some(base) = args.get("base").and_then(Value::as_str) {
                req_args.insert("base".into(), Value::String(base.into()));
            }
            if let Some(target_pane) = args.get("target_pane").and_then(Value::as_str) {
                req_args.insert("target_pane".into(), Value::String(target_pane.into()));
            }
            "review"
        }
        "tako_review_close" => {
            req_args.insert("subcommand".into(), Value::String("close".into()));
            "review"
        }
        "tako_review_status" => {
            req_args.insert("subcommand".into(), Value::String("status".into()));
            "review"
        }
        "tako_review_diff" => {
            if let Some(true) = args.get("files_only").and_then(Value::as_bool) {
                req_args.insert("subcommand".into(), Value::String("files".into()));
            } else {
                req_args.insert("subcommand".into(), Value::String("diff".into()));
                if let Some(file) = args.get("file").and_then(Value::as_str) {
                    req_args.insert("file".into(), Value::String(file.into()));
                }
            }
            "review"
        }
        "tako_review_comment" => {
            req_args.insert("subcommand".into(), Value::String("comment".into()));
            let action = args.get("action").and_then(Value::as_str).unwrap_or("list");
            req_args.insert("action".into(), Value::String(action.into()));
            match action {
                "add" => {
                    let file = args
                        .get("file")
                        .and_then(Value::as_str)
                        .ok_or_else(|| "missing required field 'file'".to_string())?;
                    let text = args
                        .get("text")
                        .and_then(Value::as_str)
                        .ok_or_else(|| "missing required field 'text'".to_string())?;
                    req_args.insert("file".into(), Value::String(file.into()));
                    req_args.insert("text".into(), Value::String(text.into()));
                    if let Some(line) = args.get("line").and_then(Value::as_i64) {
                        req_args.insert("line".into(), Value::from(line));
                    }
                }
                "remove" => {
                    let comment_id = args
                        .get("comment_id")
                        .or_else(|| args.get("id"))
                        .and_then(Value::as_str)
                        .ok_or_else(|| "missing required field 'comment_id'".to_string())?;
                    req_args.insert("comment_id".into(), Value::String(comment_id.into()));
                }
                "list" | "clear" => {}
                other => return Err(format!("unknown review comment action '{other}'")),
            }
            "review"
        }
        "tako_review_send" => {
            req_args.insert("subcommand".into(), Value::String("send".into()));
            if let Some(target_pane) = args.get("target_pane").and_then(Value::as_str) {
                req_args.insert("target_pane".into(), Value::String(target_pane.into()));
            }
            "review"
        }
        other => return Err(format!("unrecognized tool '{other}'")),
    };

    let mut req = Map::new();
    req.insert("cmd".into(), Value::String(cmd.into()));
    req.insert("args".into(), Value::Object(req_args));
    req.insert("client".into(), Value::String("mcp".into()));
    let mut scopes_list: Vec<&'static str> = capabilities
        .scopes()
        .iter()
        .map(|s| s.as_str())
        .collect();
    scopes_list.sort();
    req.insert(
        "scopes".into(),
        Value::Array(scopes_list.into_iter().map(|s| Value::String(s.into())).collect()),
    );
    if let Some(s) = surface_id {
        req.insert("from".into(), Value::String(s.to_string()));
    }
    let resolved_token = token.map(String::from).or_else(|| {
        std::env::var("TAKO_CONTROL_TOKEN")
            .or_else(|_| std::env::var("TAKO_AUTH_TOKEN"))
            .ok()
    });
    if let Some(tok) = resolved_token {
        req.insert("token".into(), Value::String(tok));
    }

    Ok(Value::Object(req))
}

