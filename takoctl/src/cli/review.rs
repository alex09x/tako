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

use crate::reports::expand_path;

pub fn parse(
    cmd: &str,
    args: &mut Map<String, Value>,
    positional: &mut Vec<String>,
) -> Result<Option<()>, String> {
    if cmd != "review" {
        return Ok(None);
    }
    let sub = if positional.is_empty() {
        "status".to_string()
    } else {
        positional.remove(0)
    };
    match sub.as_str() {
        "open" => {
            args.insert("subcommand".into(), Value::String("open".into()));
            if !positional.is_empty() {
                let path = positional.remove(0);
                args.insert("worktree".into(), Value::String(expand_path(&path)));
            }
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
        "files" => {
            args.insert("subcommand".into(), Value::String("files".into()));
            if !positional.is_empty() {
                return Err(format!("unexpected argument {}", positional[0]));
            }
        }
        "diff" => {
            args.insert("subcommand".into(), Value::String("diff".into()));
            if !positional.is_empty() {
                let f = positional.remove(0);
                args.insert("file".into(), Value::String(f));
            }
            if !positional.is_empty() {
                return Err(format!("unexpected argument {}", positional[0]));
            }
        }
        "comment" => {
            args.insert("subcommand".into(), Value::String("comment".into()));
            let action = if positional.is_empty() {
                "list".to_string()
            } else {
                positional.remove(0)
            };
            args.insert("action".into(), Value::String(action.clone()));
            match action.as_str() {
                "add" => {
                    if !positional.is_empty() && !args.contains_key("file") {
                        args.insert("file".into(), Value::String(positional.remove(0)));
                    }
                    if !positional.is_empty() && !args.contains_key("line") {
                        if let Ok(line_num) = positional[0].parse::<u64>() {
                            positional.remove(0);
                            args.insert("line".into(), Value::from(line_num));
                        }
                    }
                    if !positional.is_empty() {
                        let comment_text =
                            positional.drain(..).collect::<Vec<_>>().join(" ");
                        args.insert("text".into(), Value::String(comment_text));
                    }
                    if !args.contains_key("file") {
                        return Err(
                            "review comment add requires a file (--file or positional)"
                                .into(),
                        );
                    }
                    if !args.contains_key("text") {
                        return Err("review comment add requires comment text".into());
                    }
                }
                "list" => {
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                "remove" => {
                    if !positional.is_empty() {
                        args.insert(
                            "comment_id".into(),
                            Value::String(positional.remove(0)),
                        );
                    }
                    if !args.contains_key("comment_id") {
                        return Err("review comment remove requires a comment ID".into());
                    }
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                "clear" => {
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                other => {
                    return Err(format!(
                        "unknown review comment action '{other}'; expected add, list, remove, or clear"
                    ));
                }
            }
        }
        "send" => {
            args.insert("subcommand".into(), Value::String("send".into()));
            if !positional.is_empty() {
                return Err(format!("unexpected argument {}", positional[0]));
            }
        }
        other => {
            return Err(format!(
                "unknown review action '{other}'; expected open, close, status, files, diff, comment, or send"
            ));
        }
    }
    Ok(Some(()))
}
