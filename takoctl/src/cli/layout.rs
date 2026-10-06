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
    match cmd {
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
            Ok(Some(()))
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
            Ok(Some(()))
        }
        _ => Ok(None),
    }
}
