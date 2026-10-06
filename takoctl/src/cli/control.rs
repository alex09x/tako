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
    client: Option<&str>,
    scopes: Option<&[String]>,
    description: Option<&str>,
    token: Option<&str>,
) -> Result<Option<()>, String> {
    match cmd {
        "triggers" => {
            let sub = if positional.is_empty() {
                "list".to_string()
            } else {
                positional.remove(0)
            };
            match sub.as_str() {
                "list" => {
                    args.insert("subcommand".into(), Value::String("list".into()));
                }
                "add" => {
                    if positional.is_empty() {
                        return Err("triggers add needs a PATTERN".into());
                    }
                    let pattern = positional.remove(0);
                    args.insert("subcommand".into(), Value::String("add".into()));
                    args.insert("pattern".into(), Value::String(pattern));
                }
                "remove" | "rm" | "delete" => {
                    if positional.is_empty() {
                        return Err("triggers remove needs a trigger ID".into());
                    }
                    let id = positional.remove(0);
                    args.insert("subcommand".into(), Value::String("remove".into()));
                    args.insert("id".into(), Value::String(id));
                }
                "clear" | "reset" => {
                    args.insert("subcommand".into(), Value::String("clear".into()));
                }
                other => {
                    return Err(format!(
                        "unknown triggers subcommand \"{other}\"; use list, add, remove, or clear"
                    ));
                }
            }
            if !positional.is_empty() {
                return Err(format!("unexpected argument {}", positional[0]));
            }
            Ok(Some(()))
        }
        "status" => {
            let sub = if positional.is_empty() {
                "get".to_string()
            } else {
                positional.remove(0)
            };
            match sub.as_str() {
                "get" => {
                    args.insert("action".into(), Value::String("get".into()));
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                "set" => {
                    args.insert("action".into(), Value::String("set".into()));
                    if positional.is_empty() {
                        return Err("status set needs a status (e.g. idle, running, working, done, error, ...)".into());
                    }
                    args.insert("status".into(), Value::String(positional.remove(0)));
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                "clear" => {
                    args.insert("action".into(), Value::String("clear".into()));
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                other => {
                    return Err(format!(
                        "unknown status action \"{other}\"; use get, set, or clear"
                    ));
                }
            }
            Ok(Some(()))
        }
        "progress" => {
            if positional.is_empty() {
                args.insert("action".into(), Value::String("get".into()));
            } else {
                let first = positional.remove(0);
                let first_lower = first.to_lowercase();
                if let Ok(num) = first.parse::<u64>() {
                    if num > 100 {
                        return Err("progress value must be between 0 and 100".into());
                    }
                    args.insert("action".into(), Value::String("set".into()));
                    args.insert("value".into(), Value::from(num));
                } else {
                    match first_lower.as_str() {
                        "get" => {
                            args.insert("action".into(), Value::String("get".into()));
                        }
                        "clear" | "none" | "reset" => {
                            args.insert("action".into(), Value::String("clear".into()));
                        }
                        "indeterminate" => {
                            args.insert("action".into(), Value::String("indeterminate".into()));
                        }
                        "error" => {
                            args.insert("action".into(), Value::String("error".into()));
                            if !positional.is_empty() {
                                let val_str = positional.remove(0);
                                if let Ok(num) = val_str.parse::<u64>() {
                                    if num > 100 {
                                        return Err(
                                            "progress value must be between 0 and 100".into()
                                        );
                                    }
                                    args.insert("value".into(), Value::from(num));
                                } else {
                                    return Err(format!("invalid progress value \"{val_str}\""));
                                }
                            }
                        }
                        "pause" | "paused" => {
                            args.insert("action".into(), Value::String("pause".into()));
                            if !positional.is_empty() {
                                let val_str = positional.remove(0);
                                if let Ok(num) = val_str.parse::<u64>() {
                                    if num > 100 {
                                        return Err(
                                            "progress value must be between 0 and 100".into()
                                        );
                                    }
                                    args.insert("value".into(), Value::from(num));
                                } else {
                                    return Err(format!("invalid progress value \"{val_str}\""));
                                }
                            }
                        }
                        "set" | "normal" => {
                            args.insert("action".into(), Value::String("set".into()));
                            if !positional.is_empty() {
                                let val_str = positional.remove(0);
                                if let Ok(num) = val_str.parse::<u64>() {
                                    if num > 100 {
                                        return Err(
                                            "progress value must be between 0 and 100".into()
                                        );
                                    }
                                    args.insert("value".into(), Value::from(num));
                                } else {
                                    return Err(format!("invalid progress value \"{val_str}\""));
                                }
                            }
                        }
                        other => {
                            return Err(format!(
                                "unknown progress state \"{other}\"; use 0-100, indeterminate, error, pause, or clear"
                            ));
                        }
                    }
                }
            }
            if !positional.is_empty() {
                return Err(format!("unexpected argument {}", positional[0]));
            }
            Ok(Some(()))
        }
        "input" => {
            let sub = if positional.is_empty() {
                "status".to_string()
            } else {
                positional.remove(0)
            };
            match sub.as_str() {
                "lock" | "unlock" | "takeover" | "handback" | "status" | "log"
                | "allow-automation" | "disallow-automation" | "confirm-automation" => {
                    args.insert("subcommand".into(), Value::String(sub));
                }
                other => {
                    return Err(format!(
                        "unknown input action \"{other}\"; use lock, unlock, takeover, handback, status, log, allow-automation, disallow-automation, or confirm-automation"
                    ));
                }
            }
            if !positional.is_empty() {
                return Err(format!("unexpected argument {}", positional[0]));
            }
            Ok(Some(()))
        }
        "activity" => {
            if let Some(true) = args.get("clear").and_then(Value::as_bool) {
                args.insert("action".into(), Value::String("clear".into()));
                if !positional.is_empty() {
                    let target_candidate = positional.remove(0);
                    args.insert("target".into(), Value::String(target_candidate));
                }
            } else if args.get("export").is_some() {
                args.insert("action".into(), Value::String("export".into()));
                if !positional.is_empty() {
                    let target_candidate = positional.remove(0);
                    args.insert("target".into(), Value::String(target_candidate));
                }
            } else if positional.is_empty() {
                args.insert("action".into(), Value::String("get".into()));
            } else {
                let first = positional.remove(0);
                match first.as_str() {
                    "get" | "list" => {
                        args.insert("action".into(), Value::String("get".into()));
                        if !positional.is_empty() {
                            let target_candidate = positional.remove(0);
                            args.insert("target".into(), Value::String(target_candidate));
                        }
                    }
                    "clear" => {
                        args.insert("action".into(), Value::String("clear".into()));
                        if !positional.is_empty() {
                            let target_candidate = positional.remove(0);
                            args.insert("target".into(), Value::String(target_candidate));
                        }
                    }
                    "export" => {
                        args.insert("action".into(), Value::String("export".into()));
                        if !positional.is_empty() {
                            let file = positional.remove(0);
                            args.insert("export".into(), Value::String(expand_path(&file)));
                        }
                        if !positional.is_empty() {
                            let target_candidate = positional.remove(0);
                            args.insert("target".into(), Value::String(target_candidate));
                        }
                    }
                    target_candidate => {
                        args.insert("action".into(), Value::String("get".into()));
                        args.insert("target".into(), Value::String(target_candidate.to_string()));
                    }
                }
            }
            if !positional.is_empty() {
                return Err(format!("unexpected argument {}", positional[0]));
            }
            Ok(Some(()))
        }
        "grant" => {
            let sub = if positional.is_empty() {
                "list".to_string()
            } else {
                positional.remove(0)
            };
            match sub.as_str() {
                "request" => {
                    args.insert("subcommand".into(), Value::String(sub));
                    if let Some(c) = client {
                        args.insert("client".into(), Value::String(c.to_string()));
                    } else if !positional.is_empty() {
                        args.insert("client".into(), Value::String(positional.remove(0)));
                    } else {
                        args.insert("client".into(), Value::String("takoctl".into()));
                    }
                    if let Some(sc) = scopes {
                        args.insert(
                            "scopes".into(),
                            Value::Array(sc.iter().map(|s| Value::String(s.clone())).collect()),
                        );
                    }
                    if let Some(d) = description {
                        args.insert("description".into(), Value::String(d.to_string()));
                    }
                }
                "create" => {
                    args.insert("subcommand".into(), Value::String(sub));
                    if let Some(c) = client {
                        args.insert("client".into(), Value::String(c.to_string()));
                    } else if !positional.is_empty() {
                        args.insert("client".into(), Value::String(positional.remove(0)));
                    }
                    if let Some(sc) = scopes {
                        args.insert(
                            "scopes".into(),
                            Value::Array(sc.iter().map(|s| Value::String(s.clone())).collect()),
                        );
                    }
                    if let Some(d) = description {
                        args.insert("description".into(), Value::String(d.to_string()));
                    }
                }
                "revoke" => {
                    args.insert("subcommand".into(), Value::String(sub));
                    if !positional.is_empty() {
                        args.insert("token".into(), Value::String(positional.remove(0)));
                    } else if let Some(t) = token {
                        args.insert("token".into(), Value::String(t.to_string()));
                    } else {
                        return Err("grant revoke requires a token to revoke".into());
                    }
                }
                "list" => {
                    args.insert("subcommand".into(), Value::String(sub));
                }
                other => {
                    return Err(format!(
                        "unknown grant action \"{other}\"; use request, create, revoke, or list"
                    ));
                }
            }
            if !positional.is_empty() {
                return Err(format!("unexpected argument {}", positional[0]));
            }
            Ok(Some(()))
        }
        "broadcast" => {
            let sub = if positional.is_empty() {
                "status".to_string()
            } else {
                positional.remove(0)
            };
            match sub.as_str() {
                "start" | "stop" | "status" => {
                    args.insert("subcommand".into(), Value::String(sub));
                }
                other => {
                    return Err(format!(
                        "unknown broadcast action \"{other}\"; use start, stop, or status"
                    ));
                }
            }
            if !positional.is_empty() {
                return Err(format!("unexpected argument {}", positional[0]));
            }
            Ok(Some(()))
        }
        _ => Ok(None),
    }
}
