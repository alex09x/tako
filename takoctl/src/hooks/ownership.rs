/*
 * tako — Native hook ownership receipts
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */
use super::adapter::Adapter;
use serde_json::Value;
use std::path::{Path, PathBuf};

pub fn qwen_receipt_path(path: &Path) -> PathBuf {
    let mut name = path.as_os_str().to_os_string();
    name.push(".tako-qwen-receipt");
    PathBuf::from(name)
}

pub fn is_receipt(path: &Path) -> bool {
    let path = path.to_string_lossy();
    path.ends_with(".tako-muse-receipt") || path.ends_with(".tako-qwen-receipt")
}

// Compare exact commands from the private transactional receipt. The old app
// need not exist, and a path substring or mention of Tako proves nothing.
pub fn relocate(adapter: &Adapter, root: &Value, prior: Option<&Value>) -> Result<String, String> {
    let mut root = root.clone();
    if let Some(prior) = prior {
        let prior = prior.as_object().ok_or("invalid dispatcher ownership receipt")?;
        if let Some(events) = root.get_mut(&adapter.hook_field).and_then(Value::as_object_mut) {
            for (event, template) in adapter.hooks.as_object().unwrap() {
                let replacement = &template[0]["hooks"][0]["command"];
                let Some(old) = prior.get(event) else { continue };
                let old = old[0]["hooks"][0]["command"].as_str()
                    .ok_or("invalid dispatcher ownership receipt command")?;
                if let Some(groups) = events.get_mut(event).and_then(Value::as_array_mut) {
                    for group in groups {
                        if let Some(hooks) = group.get_mut("hooks").and_then(Value::as_array_mut) {
                            for hook in hooks {
                                replace(hook, old, replacement);
                            }
                        } else {
                            replace(group, old, replacement);
                        }
                    }
                }
            }
        }
    }
    serde_json::to_string(&root).map_err(|e| e.to_string())
}

fn replace(hook: &mut Value, old: &str, replacement: &Value) {
    if hook.get("type").and_then(Value::as_str).is_none_or(|t| t == "command")
        && hook.get("command").and_then(Value::as_str) == Some(old)
    {
        hook["command"] = replacement.clone();
    }
}
