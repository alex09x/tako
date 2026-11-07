/*
 * tako — Surgical migration of legacy status hooks to native OSC 7501
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use std::fs;
use std::io::{self, BufRead, Write};
use std::path::Path;

use serde_json::{Map, Value, json};

use super::adapter::Adapter;
use super::fs_util::{backup_path, file_mode, new_marker_path, unified_diff, write_secure};
use super::managed;
use super::osc7501_ownership::is_owned_hook_entry;
#[cfg(test)]
pub use super::osc7501_ownership::is_tako_owned_status_command;
pub use super::osc7501_ownership::{json_contains_owned_hooks, uses_native_osc7501};

/// Surgically strips only Tako-owned status commands from `root[hook_field]`,
/// preserving sibling hooks, custom fields, and top-level sections.
/// When no owned hooks exist, returns `(content.to_string(), false)` so clean
/// user files are never reformatted.
pub fn remove_owned_json_hooks(
    content: &str,
    agent: &str,
    hook_field: &str,
) -> Result<(String, bool), String> {
    if content.trim().is_empty() {
        return Ok((String::new(), false));
    }
    let mut root: Value =
        serde_json::from_str(content).map_err(|e| format!("cannot parse JSON: {e}"))?;
    let root_obj = root.as_object_mut().ok_or("JSON root must be an object")?;
    let mut changed = false;

    if let Some(hooks_val) = root_obj.get_mut(hook_field) {
        let hooks_obj = hooks_val
            .as_object_mut()
            .ok_or_else(|| format!("'{hook_field}' field must be an object"))?;
        let keys: Vec<String> = hooks_obj.keys().cloned().collect();
        for key in keys {
            let Some(arr) = hooks_obj.get(&key).and_then(Value::as_array) else {
                continue;
            };
            let mut kept_groups = Vec::with_capacity(arr.len());
            for item in arr {
                let Some(obj) = item.as_object() else {
                    return Err("hook entries must be objects".into());
                };
                if let Some(inner) = obj.get("hooks").and_then(Value::as_array) {
                    let mut kept_inner = Vec::with_capacity(inner.len());
                    for hook in inner {
                        if is_owned_hook_entry(hook, agent) {
                            changed = true;
                        } else {
                            kept_inner.push(hook.clone());
                        }
                    }
                    if !kept_inner.is_empty() {
                        let mut updated_group: Map<String, Value> = obj.clone();
                        updated_group.insert("hooks".into(), Value::Array(kept_inner));
                        kept_groups.push(Value::Object(updated_group));
                    } else if inner.is_empty() {
                        kept_groups.push(item.clone());
                    }
                } else if is_owned_hook_entry(item, agent) {
                    changed = true;
                } else {
                    kept_groups.push(item.clone());
                }
            }
            if kept_groups.is_empty() && !arr.is_empty() {
                hooks_obj.remove(&key);
            } else if kept_groups.len() != arr.len() || changed {
                hooks_obj.insert(key, Value::Array(kept_groups));
            }
        }
        let only_antigravity_enabled_flag =
            agent == "antigravity" && hooks_obj.len() == 1 && hooks_obj.contains_key("enabled");
        if hooks_obj.is_empty() || (changed && only_antigravity_enabled_flag) {
            root_obj.remove(hook_field);
            changed = true;
        }
    }

    if !changed {
        return Ok((content.to_string(), false));
    }
    if root_obj.is_empty() {
        return Ok((String::new(), true));
    }
    let mut out =
        serde_json::to_string_pretty(&root).map_err(|e| format!("serialization error: {e}"))?;
    out.push('\n');
    Ok((out, true))
}

fn ensure_not_symlink(path: &Path, label: &str) -> Result<bool, String> {
    match fs::symlink_metadata(path) {
        Ok(meta) => {
            if meta.file_type().is_symlink() {
                Err(format!(
                    "refusing to use symlink at {label} {}",
                    path.display()
                ))
            } else {
                Ok(true)
            }
        }
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(e) => Err(format!("cannot inspect {label} {}: {e}", path.display())),
    }
}

fn cleanup_managed_orphans(adapter: &Adapter, path: &Path) -> Result<(), String> {
    if adapter.is_installed(path) {
        return Ok(());
    }
    let bak = backup_path(path);
    if ensure_not_symlink(&bak, "backup")? {
        let _ = fs::remove_file(&bak);
    }
    if adapter.name == "muse"
        && let Some(parent) = path.parent()
    {
        let pointer_still_points = fs::read_to_string(path)
            .ok()
            .and_then(|s| serde_json::from_str::<Value>(&s).ok())
            .and_then(|v| {
                v.get("managed_hooks_path")
                    .and_then(Value::as_str)
                    .map(str::to_owned)
            })
            .as_deref()
            == Some("tako-managed-hooks.json");
        let managed_hooks = parent.join("tako-managed-hooks.json");
        if !pointer_still_points && ensure_not_symlink(&managed_hooks, "managed hooks")? {
            let is_empty_obj = fs::read_to_string(&managed_hooks)
                .ok()
                .and_then(|s| serde_json::from_str::<Value>(&s).ok())
                .is_some_and(|v| v == json!({}));
            if is_empty_obj {
                let _ = fs::remove_file(&managed_hooks);
                let managed_bak = backup_path(&managed_hooks);
                if ensure_not_symlink(&managed_bak, "backup")? {
                    let _ = fs::remove_file(&managed_bak);
                }
            }
        }
    }
    Ok(())
}

/// Idempotently removes legacy Tako status hooks for an `OSC 7501`-native agent
/// without writing new hook entries or restoring stale `.tako-bak` snapshots
/// over newer user/Prod/Rex configuration.
pub fn run_native_cleanup(
    adapter: &Adapter,
    path: &Path,
    yes: bool,
    diff_only: bool,
    json: bool,
    from_install: bool,
) -> Result<(), String> {
    if adapter.name == "qwen" || adapter.name == "muse" {
        managed::run(adapter, path, true, yes, diff_only, json)?;
        if !diff_only {
            cleanup_managed_orphans(adapter, path)?;
        }
        return Ok(());
    }

    let path_display = path.display().to_string();
    let bak = backup_path(path);
    let marker = new_marker_path(path);
    let path_exists = ensure_not_symlink(path, "configuration")?;
    let bak_exists = ensure_not_symlink(&bak, "backup")?;
    let marker_exists = ensure_not_symlink(&marker, "marker")?;

    if !path_exists {
        if !diff_only {
            if bak_exists {
                let _ = fs::remove_file(&bak);
            }
            if marker_exists {
                let _ = fs::remove_file(&marker);
            }
        }
        let status = if from_install {
            "native_osc7501"
        } else {
            "not_installed"
        };
        if json {
            println!(
                "{}",
                json!({"status": status, "config": path_display, "diff": ""})
            );
        } else {
            println!(
                "{} uses native OSC 7501 status; no hook file needed at {path_display}",
                adapter.title
            );
        }
        return Ok(());
    }

    let current_content =
        fs::read_to_string(path).map_err(|e| format!("cannot read {path_display}: {e}"))?;
    let (stripped, changed) =
        remove_owned_json_hooks(&current_content, &adapter.name, &adapter.hook_field)?;

    if !changed {
        let status = if from_install {
            "native_osc7501"
        } else {
            "not_installed"
        };
        if json {
            println!(
                "{}",
                json!({"status": status, "config": path_display, "diff": ""})
            );
        } else {
            println!(
                "{} uses native OSC 7501 status; no legacy Tako hooks in {path_display}",
                adapter.title
            );
        }
        return Ok(());
    }

    let delete_empty_file = stripped.is_empty() && marker_exists;
    let target_str = if delete_empty_file {
        String::new()
    } else if stripped.is_empty() {
        "{}\n".to_string()
    } else {
        stripped
    };

    let diff = unified_diff(&current_content, &target_str, &path_display);
    if diff_only {
        if json {
            println!(
                "{}",
                json!({"status": "diff_only", "config": path_display, "diff": diff})
            );
        } else {
            print!("{diff}");
        }
        return Ok(());
    }

    if !json {
        println!(
            "Removing legacy Tako status hooks (superseded by native OSC 7501) from {path_display}:"
        );
        println!("{diff}");
    }
    if !yes {
        print!("Remove legacy Tako status hooks from {path_display}? [y/N]: ");
        io::stdout().flush().map_err(|e| e.to_string())?;
        let mut line = String::new();
        io::stdin()
            .lock()
            .read_line(&mut line)
            .map_err(|e| e.to_string())?;
        if !matches!(line.trim().to_lowercase().as_str(), "y" | "yes") {
            println!("Cancelled.");
            return Ok(());
        }
    }

    let orig_mode = file_mode(path);
    if delete_empty_file {
        fs::remove_file(path).map_err(|e| format!("cannot remove {path_display}: {e}"))?;
    } else {
        write_secure(path, target_str.as_bytes(), orig_mode)
            .map_err(|e| format!("cannot update {path_display}: {e}"))?;
    }
    if bak_exists {
        let _ = fs::remove_file(&bak);
    }
    if marker_exists {
        let _ = fs::remove_file(&marker);
    }

    let status = if from_install {
        "migrated_osc7501"
    } else {
        "uninstalled"
    };
    if json {
        println!(
            "{}",
            json!({"status": status, "config": path_display, "diff": diff})
        );
    } else {
        println!("Removed legacy Tako status hooks from {path_display} (native OSC 7501 active)");
    }
    Ok(())
}
