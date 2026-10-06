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

pub fn resolve(program: &str, path: &str) -> Option<String> {
    use std::os::unix::fs::PermissionsExt;
    if program.contains('/') {
        return Some(program.to_string());
    }
    path.split(':').filter(|d| !d.is_empty()).find_map(|dir| {
        let candidate = std::path::Path::new(dir).join(program);
        let meta = std::fs::metadata(&candidate).ok()?;
        (meta.is_file() && meta.permissions().mode() & 0o111 != 0)
            .then(|| candidate.to_string_lossy().into_owned())
    })
}

pub fn parse(
    cmd: &str,
    args: &mut Map<String, Value>,
    positional: &mut Vec<String>,
    dashdash: bool,
) -> Result<Option<()>, String> {
    match cmd {
        "history" => {
            if !positional.is_empty() {
                let q = positional.remove(0);
                if !args.contains_key("query") {
                    args.insert("query".into(), Value::String(q));
                }
            }
            if !positional.is_empty() {
                return Err(format!("unexpected argument {}", positional[0]));
            }
            Ok(Some(()))
        }
        "screenshot" => {
            if !positional.is_empty() {
                let p = positional.remove(0);
                args.insert("out".into(), Value::String(expand_path(&p)));
            }
            if !positional.is_empty() {
                return Err(format!("unexpected argument {}", positional[0]));
            }
            Ok(Some(()))
        }
        "run" => {
            if !dashdash || positional.is_empty() {
                return Err("run needs -- PROGRAM [ARGS...]".into());
            }
            let path = std::env::var("PATH").unwrap_or_default();
            let mut argv = std::mem::take(positional);
            argv[0] = resolve(&argv[0], &path)
                .ok_or_else(|| format!("{}: not found on PATH", argv[0]))?;
            args.insert("argv".into(), Value::from(argv));
            args.insert("path".into(), Value::String(path));
            Ok(Some(()))
        }
        "hooks" => {
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
                "status" => {
                    args.insert("action".into(), Value::String("status".into()));
                    if !positional.is_empty() {
                        args.insert("agent".into(), Value::String(positional.remove(0)));
                    }
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                "install" => {
                    args.insert("action".into(), Value::String("install".into()));
                    if positional.is_empty() {
                        return Err(
                            "hooks install needs an agent name (e.g. claude, gemini, codex, aider)"
                                .into(),
                        );
                    }
                    args.insert("agent".into(), Value::String(positional.remove(0)));
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                "uninstall" => {
                    args.insert("action".into(), Value::String("uninstall".into()));
                    if positional.is_empty() {
                        return Err("hooks uninstall needs an agent name (e.g. claude, gemini, codex, aider)".into());
                    }
                    args.insert("agent".into(), Value::String(positional.remove(0)));
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                other => {
                    return Err(format!(
                        "unknown hooks action \"{other}\"; use list, status, install, or uninstall"
                    ));
                }
            }
            Ok(Some(()))
        }
        "skills" => {
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
                "status" => {
                    args.insert("action".into(), Value::String("status".into()));
                    if !positional.is_empty() {
                        let agent = positional.remove(0);
                        args.insert("agent".into(), Value::String(agent));
                    }
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                "install" => {
                    args.insert("action".into(), Value::String("install".into()));
                    if positional.is_empty() {
                        return Err("skills install needs an agent name (e.g. claude, gemini, codex, aider)".into());
                    }
                    args.insert("agent".into(), Value::String(positional.remove(0)));
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                "uninstall" => {
                    args.insert("action".into(), Value::String("uninstall".into()));
                    if positional.is_empty() {
                        return Err("skills uninstall needs an agent name (e.g. claude, gemini, codex, aider)".into());
                    }
                    args.insert("agent".into(), Value::String(positional.remove(0)));
                    if !positional.is_empty() {
                        return Err(format!("unexpected argument {}", positional[0]));
                    }
                }
                other => {
                    return Err(format!(
                        "unknown skills action \"{other}\"; use list, status, install, or uninstall"
                    ));
                }
            }
            Ok(Some(()))
        }
        "split" => {
            if positional.is_empty() {
                args.insert("direction".into(), Value::String("right".into()));
            } else if positional.len() == 1 {
                let dir = positional.remove(0);
                match dir.to_lowercase().as_str() {
                    "right" | "left" | "down" | "up" => {
                        args.insert("direction".into(), Value::String(dir));
                    }
                    other => {
                        return Err(format!(
                            "split direction must be right, left, down, or up (got \"{other}\")"
                        ));
                    }
                }
            } else {
                return Err(
                    "split takes at most one direction argument (right, left, down, up)".into(),
                );
            }
            Ok(Some(()))
        }
        "collapse" | "expand" => {
            if !positional.is_empty() {
                args.insert("target".into(), Value::String(positional.remove(0)));
            }
            if !positional.is_empty() {
                return Err(format!("unexpected argument {}", positional[0]));
            }
            Ok(Some(()))
        }
        _ => Ok(None),
    }
}
