/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

mod input;

use super::Options;
use serde_json::{Map, Value, json};
use std::io::Read;

pub fn parse(argv: &[String], command_index: usize) -> Result<Options, String> {
    parse_with_reader(argv, command_index, &mut std::io::stdin().lock())
}

pub(crate) fn parse_with_reader(
    argv: &[String],
    command_index: usize,
    stdin: &mut impl Read,
) -> Result<Options, String> {
    // Reuse the ordinary parser for connection options and inherited identity.
    let mut common = vec!["version".to_string()];
    let mut flags = Map::new();
    let mut positional = Vec::new();
    let mut it = argv.iter().enumerate();
    let mut literal = false;
    while let Some((index, token)) = it.next() {
        if index == command_index {
            continue;
        }
        if literal {
            positional.push(token.clone());
            continue;
        }
        let mut value = || -> Result<String, String> {
            let (index, value) = it.next().ok_or_else(|| format!("{token} needs a value"))?;
            if index == command_index || value.starts_with("--") || value.trim().is_empty() {
                return Err(format!("{token} needs a value"));
            }
            Ok(value.clone())
        };
        let (key, val) = match token.as_str() {
            "--" => {
                literal = true;
                continue;
            }
            "--help" | "-h" => return Err(String::new()),
            "--json" => {
                common.push(token.clone());
                continue;
            }
            "--socket" | "--bundle-id" | "--client" => {
                common.push(token.clone());
                common.push(value()?);
                continue;
            }
            "--from" => ("from_theme", Value::String(value()?)),
            "--file" => ("file", Value::String(value()?)),
            "--stdin" => ("stdin", Value::Bool(true)),
            "--global" => ("global", Value::Bool(true)),
            "--workspace" => ("workspace", Value::String(value()?)),
            "--target" | "--pane" | "--session" => ("target", Value::String(value()?)),
            other if other.starts_with('-') => return Err(format!("unknown option {other}")),
            _ => {
                positional.push(token.clone());
                continue;
            }
        };
        if flags.insert(key.into(), val).is_some() {
            return Err(format!("{token} conflicts with an earlier option"));
        }
    }
    let mut opts = super::parser::parse(&common)?;
    opts.cmd = "theme".into();
    opts.args.clear();
    let action = if positional.is_empty() {
        "list".into()
    } else {
        positional.remove(0)
    };
    let args = &mut opts.args;
    args.insert("action".into(), json!(action));
    let scoped = matches!(action.as_str(), "apply" | "reset" | "current");
    let sources = ["from_theme", "file", "stdin"]
        .iter()
        .filter(|k| flags.contains_key(**k))
        .count();
    if sources > 1 {
        return Err("give only one of --from, --file, or --stdin".into());
    }
    if sources > 0 && !matches!(action.as_str(), "create" | "set") {
        return Err(format!("theme {action} does not accept a config source"));
    }
    if flags.contains_key("from_theme") && action != "create" {
        return Err("--from is only supported by theme create".into());
    }
    let scopes = ["global", "workspace", "target"]
        .iter()
        .filter(|k| flags.contains_key(**k))
        .count();
    if scopes > 1 {
        return Err("give exactly one scope: --global, --workspace, or --target".into());
    }
    if !scoped && scopes > 0 {
        return Err(format!("theme {action} does not accept a scope"));
    }
    if scoped {
        if scopes == 0 && action != "current" {
            return Err(format!(
                "theme {action} requires --global, --workspace, or --target"
            ));
        }
        let scope = if flags.contains_key("global") {
            "global"
        } else if flags.contains_key("workspace") {
            "workspace"
        } else {
            "pane"
        };
        args.insert("scope".into(), json!(scope));
        for key in ["workspace", "target"] {
            if let Some(value) = flags.remove(key) {
                args.insert(key.into(), value);
            }
        }
    }
    match action.as_str() {
        "list" | "fonts" | "keys" | "reset" | "current" => {}
        "show" | "delete" | "apply" | "create" => {
            args.insert("name".into(), json!(take(&mut positional, "name")?));
        }
        "rename" => {
            args.insert("name".into(), json!(take(&mut positional, "old name")?));
            args.insert("new_name".into(), json!(take(&mut positional, "new name")?));
        }
        "copy" => {
            args.insert("action".into(), json!("create"));
            args.insert(
                "from_theme".into(),
                json!(take(&mut positional, "source name")?),
            );
            args.insert(
                "name".into(),
                json!(take(&mut positional, "destination name")?),
            );
        }
        "set" | "unset" => {
            args.insert("action".into(), json!("set"));
            args.insert("name".into(), json!(take(&mut positional, "name")?));
            if sources == 0 {
                if positional.is_empty() {
                    return Err(format!("theme {action} needs settings"));
                }
                let mut settings = Vec::new();
                for setting in positional.drain(..) {
                    let (key, value) = if action == "unset" {
                        if setting.contains('=') {
                            return Err("theme unset expects keys without '='".into());
                        }
                        (setting.as_str(), Value::Null)
                    } else {
                        let (key, value) = setting
                            .split_once('=')
                            .ok_or_else(|| format!("expected KEY=VALUE: {setting}"))?;
                        (key, json!(value))
                    };
                    if key.trim().is_empty() {
                        return Err("theme setting key cannot be empty".into());
                    }
                    settings.push(json!({"key": key, "value": value}));
                }
                args.insert("settings".into(), json!(settings));
            }
        }
        _ => return Err(format!("unknown theme action {action}")),
    }
    if !positional.is_empty() {
        return Err(format!("unexpected argument {}", positional[0]));
    }
    // Validate everything before opening a file or waiting for stdin.
    if let Some(from) = flags.remove("from_theme") {
        args.insert("from_theme".into(), from);
    }
    if let Some(file) = flags.remove("file") {
        args.insert(
            "config".into(),
            json!(input::load_config(file.as_str().unwrap())?),
        );
    } else if flags.contains_key("stdin") {
        args.insert("config".into(), json!(input::read_config(stdin)?));
    }
    let request = super::request(&opts, std::env::var("TAKO_SURFACE_ID").ok());
    if request.to_string().len() + 1 > input::MAX_REQUEST_BYTES {
        return Err("theme request exceeds the 1 MiB request limit".into());
    }
    Ok(opts)
}

fn take(positional: &mut Vec<String>, what: &str) -> Result<String, String> {
    if positional.is_empty() || positional[0].trim().is_empty() {
        return Err(format!("theme needs a {what}"));
    }
    Ok(positional.remove(0))
}
