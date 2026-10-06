/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use serde_json::{Map, Value};

use crate::cli::helpers::{dispatch_and_validate, parse_duration};
use crate::cli::types::Options;
use crate::reports::expand_path;

pub fn parse(argv: &[String]) -> Result<Options, String> {
    let mut cmd = None;
    let mut args = Map::new();
    let mut json = false;
    let mut socket = None;
    let mut bundle_id =
        std::env::var("TAKO_BUNDLE_ID").unwrap_or_else(|_| "com.tako-core.terminal".into());
    let mut client = std::env::var("TAKO_CLIENT_ID")
        .or_else(|_| std::env::var("TAKO_CLIENT"))
        .ok();
    let mut token = std::env::var("TAKO_CONTROL_TOKEN")
        .or_else(|_| std::env::var("TAKO_AUTH_TOKEN"))
        .ok();
    let mut scopes = std::env::var("TAKO_CONTROL_SCOPES")
        .or_else(|_| std::env::var("TAKO_SCOPES"))
        .ok()
        .map(|s| {
            s.split(',')
                .map(|p| p.trim().to_lowercase())
                .filter(|p| !p.is_empty())
                .collect::<Vec<_>>()
        });
    let mut description: Option<String> = None;
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
                    .map_err(|_| "--limit needs a non-negative number".to_string())?;
                if n > 5000 {
                    return Err("--limit cannot exceed 5000".into());
                }
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
                    return Err(
                        "--timeout out of range: must be between 0s and 7d (finite)".to_string()
                    );
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
                args.insert(
                    "capabilities".into(),
                    Value::String(value("--capabilities")?),
                );
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
            "--file" => {
                args.insert("file".into(), Value::String(value("--file")?));
            }
            "--line" => {
                let n: u64 = value("--line")?
                    .parse()
                    .map_err(|_| "--line needs a number".to_string())?;
                args.insert("line".into(), Value::from(n));
            }
            "--target-pane" => {
                args.insert("target_pane".into(), Value::String(value("--target-pane")?));
            }
            "--archive" => {
                args.insert("archive".into(), Value::Bool(true));
            }
            "--key" => {
                args.insert("key".into(), Value::String(value("--key")?));
            }
            "--value" => {
                args.insert("value".into(), Value::String(value("--value")?));
            }
            "--filter" => {
                args.insert("filter".into(), Value::String(value("--filter")?));
            }
            "--editor" => {
                args.insert("editor".into(), Value::Bool(true));
            }
            "--stdout" => {
                args.insert("stdout".into(), Value::Bool(true));
            }
            "--include-terminal" => {
                args.insert("include_terminal".into(), Value::Bool(true));
            }
            "--benchmark" => {
                args.insert("benchmark".into(), Value::Bool(true));
            }
            "--force" => {
                args.insert("force".into(), Value::Bool(true));
            }
            "--export" => {
                let path = value("--export")?;
                args.insert("export".into(), Value::String(expand_path(&path)));
            }
            "--clear" => {
                args.insert("clear".into(), Value::Bool(true));
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
            "--token" | "--auth-token" => {
                let val = value(arg.as_str())?;
                token = Some(val.clone());
                args.insert("token".into(), Value::String(val));
            }
            "--client" => {
                let name = value("--client")?;
                client = Some(name.clone());
                args.insert("client".into(), Value::String(name));
            }
            "--scope" | "--scopes" => {
                let val = value(arg.as_str())?;
                let list: Vec<String> = val
                    .split(',')
                    .map(|p| p.trim().to_lowercase())
                    .filter(|p| !p.is_empty())
                    .collect();
                if list.is_empty() {
                    return Err(format!("{arg} cannot be empty"));
                }
                for s in &list {
                    if !["read", "input", "layout", "signal", "overlay", "approval"]
                        .contains(&s.as_str())
                    {
                        return Err(format!(
                            "unknown capability scope '{s}'; valid scopes are read, input, layout, signal, overlay, approval"
                        ));
                    }
                }
                scopes = Some(list);
            }
            "--desc" | "--description" => {
                let d = value(arg.as_str())?;
                description = Some(d.clone());
                args.insert("description".into(), Value::String(d));
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
            "--query" => {
                args.insert("query".into(), Value::String(value("--query")?));
            }
            "--action" => {
                args.insert("action".into(), Value::String(value("--action")?));
            }
            "--style" => {
                args.insert("style".into(), Value::String(value("--style")?));
            }
            "--all-focus" => {
                args.insert("only_unfocused".into(), Value::Bool(false));
            }
            "--only-unfocused" => {
                args.insert("only_unfocused".into(), Value::Bool(true));
            }
            "-h" | "--help" => return Err(String::new()),
            a if a.starts_with('-') => return Err(format!("unknown option {a}")),
            a if cmd.is_none() => cmd = Some(a.to_string()),
            a => positional.push(a.to_string()),
        }
    }
    let cmd = cmd.ok_or_else(String::new)?;

    dispatch_and_validate(
        &cmd,
        &mut args,
        &mut positional,
        dashdash,
        client.as_deref(),
        scopes.as_deref(),
        description.as_deref(),
        token.as_deref(),
    )?;
    if client.is_none() {
        client = args.get("client").and_then(Value::as_str).map(String::from);
    }
    if token.is_none() {
        token = args.get("token").and_then(Value::as_str).map(String::from);
    }
    if token.is_none() {
        let sock_path = socket.clone().or_else(|| crate::socket::default_path(&bundle_id).ok());
        if let Some(sp) = sock_path {
            let token_path = format!("{sp}.token");
            if let Ok(content) = std::fs::read_to_string(&token_path) {
                let trimmed = content.trim().to_string();
                if !trimmed.is_empty() {
                    token = Some(trimmed);
                }
            }
        }
    }
    Ok(Options {
        cmd,
        args,
        json,
        socket,
        bundle_id,
        client,
        token,
        scopes,
    })
}
