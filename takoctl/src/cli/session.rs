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
            Ok(Some(()))
        }
        "task" => {
            let sub = if positional.is_empty() {
                "list".to_string()
            } else {
                positional.remove(0)
            };
            match sub.as_str() {
                "create" => {
                    args.insert("action".into(), Value::String("create".into()));
                    if positional.is_empty() {
                        return Err("task create needs a task name".into());
                    }
                    let name = positional.remove(0);
                    args.insert("name".into(), Value::String(name));
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
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
                "status" => {
                    args.insert("action".into(), Value::String("status".into()));
                    if positional.is_empty() {
                        return Err("task status needs a task name".into());
                    }
                    let name = positional.remove(0);
                    args.insert("name".into(), Value::String(name));
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                "finish" => {
                    args.insert("action".into(), Value::String("finish".into()));
                    if positional.is_empty() {
                        return Err("task finish needs a task name".into());
                    }
                    let name = positional.remove(0);
                    args.insert("name".into(), Value::String(name));
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                other => {
                    return Err(format!(
                        "unknown task subcommand '{}'; expected create, list, status, or finish",
                        other
                    ));
                }
            }
            Ok(Some(()))
        }
        "resume" => {
            let sub = if positional.is_empty() {
                "show".to_string()
            } else {
                positional.remove(0)
            };
            match sub.as_str() {
                "set" => {
                    args.insert("action".into(), Value::String("set".into()));
                    if positional.is_empty() {
                        return Err(
                            "resume set needs a command line: takoctl resume set -- <argv...>"
                                .into(),
                        );
                    }
                    let argv_vals: Vec<Value> = positional.drain(..).map(Value::String).collect();
                    args.insert("argv".into(), Value::Array(argv_vals));
                    if !args.contains_key("cwd") {
                        if let Ok(dir) = std::env::current_dir() {
                            args.insert(
                                "cwd".into(),
                                Value::String(dir.to_string_lossy().to_string()),
                            );
                        }
                    }
                    let mut env_map = Map::new();
                    for (k, v) in std::env::vars() {
                        env_map.insert(k, Value::String(v));
                    }
                    args.insert("env".into(), Value::Object(env_map));
                }
                "show" => {
                    args.insert("action".into(), Value::String("show".into()));
                    if !positional.is_empty() {
                        let target = positional.remove(0);
                        args.insert("target".into(), Value::String(target));
                    }
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                "clear" => {
                    args.insert("action".into(), Value::String("clear".into()));
                    if !positional.is_empty() {
                        let target = positional.remove(0);
                        args.insert("target".into(), Value::String(target));
                    }
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                "run" => {
                    args.insert("action".into(), Value::String("run".into()));
                    if !positional.is_empty() {
                        let target = positional.remove(0);
                        args.insert("target".into(), Value::String(target));
                    }
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                "approve" => {
                    args.insert("action".into(), Value::String("approve".into()));
                    if !positional.is_empty() {
                        let target = positional.remove(0);
                        args.insert("target".into(), Value::String(target));
                    }
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                other => {
                    return Err(format!(
                        "unknown resume action \"{other}\"; use set, show, clear, run, or approve"
                    ));
                }
            }
            Ok(Some(()))
        }
        "session" => {
            let sub = if positional.is_empty() {
                return Err("session needs an action: export, import, or info".into());
            } else {
                positional.remove(0)
            };
            match sub.as_str() {
                "export" => {
                    args.insert("action".into(), Value::String("export".into()));
                    if positional.is_empty() {
                        return Err("session export needs a destination file path".into());
                    }
                    let file = positional.remove(0);
                    let expanded = expand_path(&file);
                    args.insert("path".into(), Value::String(expanded));
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                "import" => {
                    args.insert("action".into(), Value::String("import".into()));
                    if positional.is_empty() {
                        return Err("session import needs a session file path".into());
                    }
                    let file = positional.remove(0);
                    let expanded = expand_path(&file);
                    args.insert("path".into(), Value::String(expanded));
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                "info" => {
                    args.insert("action".into(), Value::String("info".into()));
                    if positional.is_empty() {
                        return Err("session info needs a session file path".into());
                    }
                    let file = positional.remove(0);
                    let expanded = expand_path(&file);
                    args.insert("path".into(), Value::String(expanded));
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                other => {
                    return Err(format!(
                        "unknown session action '{}'; expected export, import, or info",
                        other
                    ));
                }
            }
            Ok(Some(()))
        }
        "overlay" => {
            let sub = if positional.is_empty() {
                "status".to_string()
            } else {
                positional.remove(0)
            };
            match sub.as_str() {
                "open" => {
                    args.insert("subcommand".into(), Value::String("open".into()));
                    if positional.is_empty() {
                        return Err("overlay open needs a file path".into());
                    }
                    let file = positional.remove(0);
                    let expanded = expand_path(&file);
                    args.insert("file".into(), Value::String(expanded));
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
                "reload" => {
                    args.insert("subcommand".into(), Value::String("reload".into()));
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                other => {
                    return Err(format!(
                        "unknown overlay action '{other}'; expected open, close, status, or reload"
                    ));
                }
            }
            Ok(Some(()))
        }
        _ => Ok(None),
    }
}
