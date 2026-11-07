/*
 * tako — Managed Muse configuration planner
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */
use super::{
    adapter::Adapter,
    native,
    transaction::{self, Change},
};
use serde_json::{Value, json};
use std::{
    io::{self, BufRead, Write},
    path::{Component, Path, PathBuf},
};
const ENV: [&str; 2] = ["TAKO_SURFACE_ID", "TAKO_SOCKET"];

fn parse(content: Option<&str>) -> Result<Value, String> {
    let value = match content {
        None => json!({}),
        Some(s) => serde_json::from_str(s).map_err(|e| format!("invalid JSON: {e}"))?,
    };
    native::validate(&value)?;
    Ok(value)
}

fn encode(value: &Value) -> String {
    format!("{}\n", serde_json::to_string_pretty(value).unwrap())
}

fn preserved(before: &Option<String>, after: String) -> Option<String> {
    let old = parse(before.as_deref()).ok();
    let new = parse(Some(if after.is_empty() { "{}" } else { &after })).ok();
    if old.is_some() && old == new {
        before.clone()
    } else {
        Some(if after.is_empty() {
            "{}\n".into()
        } else {
            after
        })
    }
}

fn normalized(path: &Path) -> Result<PathBuf, String> {
    let absolute = if path.is_absolute() {
        path.to_owned()
    } else {
        std::env::current_dir()
            .map_err(|e| e.to_string())?
            .join(path)
    };
    // Inspect before normalizing so an intervening symlink cannot hide behind '..'.
    transaction::inspect(&absolute)?;
    let mut result = PathBuf::new();
    for component in absolute.components() {
        match component {
            Component::ParentDir => {
                result.pop();
            }
            Component::CurDir => {}
            other => result.push(other.as_os_str()),
        }
    }
    Ok(result)
}

fn validate_settings(settings: &Value) -> Result<(), String> {
    if settings
        .get("schema_version")
        .is_some_and(|v| v.as_u64() != Some(1))
    {
        return Err("Muse schema_version must be 1".into());
    }
    if let Some(env) = settings.get("managed_hooks_env_vars")
        && !env
            .as_array()
            .is_some_and(|a| a.iter().all(Value::is_string))
    {
        return Err("managed_hooks_env_vars must be an array of strings".into());
    }
    Ok(())
}

fn receipt_path(path: &Path) -> PathBuf {
    let mut name = path.as_os_str().to_os_string();
    name.push(".tako-muse-receipt");
    PathBuf::from(name)
}

fn receipt(path: &Path) -> Result<Option<Value>, String> {
    let Some(text) = transaction::read(path)? else {
        return Ok(None);
    };
    let v: Value =
        serde_json::from_str(&text).map_err(|e| format!("invalid ownership receipt: {e}"))?;
    if v["version"] != 1
        || !v["managed_path"]
            .as_str()
            .is_some_and(|s| Path::new(s).is_absolute())
        || !v["added_env"].as_array().is_some_and(|a| {
            a.iter()
                .all(|s| s.as_str().is_some_and(|s| ENV.contains(&s)))
        })
        || !v["pointer_added"].is_boolean()
        || !v["schema_added"].is_boolean()
        || !v["env_added"].is_boolean()
    {
        return Err("invalid Muse ownership receipt".into());
    }
    Ok(Some(v))
}

pub fn installed(adapter: &Adapter, path: &Path) -> bool {
    (|| -> Result<bool, String> {
        let settings = parse(transaction::read(path)?.as_deref())?;
        validate_settings(&settings)?;
        if settings["schema_version"] != 1
            || settings["disableAllHooks"] == true
            || settings.get("managed_hooks_path").is_none()
        {
            return Ok(false);
        }
        let Some(env) = settings["managed_hooks_env_vars"].as_array() else {
            return Ok(false);
        };
        if !ENV.iter().all(|name| env.contains(&json!(name))) {
            return Ok(false);
        }
        let managed = native::managed_path(&settings, path)?;
        let hooks = parse(transaction::read(&managed)?.as_deref())?;
        Ok(native::active(adapter, &hooks))
    })()
    .unwrap_or(false)
}

pub fn plan(adapter: &Adapter, path: &Path, remove: bool) -> Result<Vec<Change>, String> {
    let path = normalized(path)?;
    let original = transaction::read(&path)?;
    let mut settings = parse(original.as_deref())?;
    if adapter.name == "qwen" {
        let after = if remove {
            adapter.remove_hooks(original.as_deref().unwrap_or("{}"))?
        } else {
            adapter.apply_hooks(original.as_deref().unwrap_or(""))?
        };
        return with_backups(
            vec![Change::new(path, preserved(&original, after))?],
            remove,
        );
    }
    validate_settings(&settings)?;
    let receipt_path = receipt_path(&path);
    let existing_receipt = receipt(&receipt_path)?;
    let current_managed = normalized(&native::managed_path(&settings, &path)?)?;
    let managed = match &existing_receipt {
        Some(r) => normalized(Path::new(r["managed_path"].as_str().unwrap()))?,
        None => current_managed.clone(),
    };
    if !remove && managed != current_managed {
        return Err(
            "Muse managed pointer changed since install; uninstall the previous integration first"
                .into(),
        );
    }
    if managed == path
        || managed == receipt_path
        || managed == super::fs_util::backup_path(&path)
        || super::fs_util::backup_path(&managed) == path
        || super::fs_util::backup_path(&managed) == receipt_path
    {
        return Err("Muse configuration paths overlap".into());
    }
    let hooks_before = transaction::read(&managed)?;
    let hooks = parse(hooks_before.as_deref())?;
    let mut ownership = existing_receipt.clone().unwrap_or_else(|| {
        json!({
            "version": 1, "managed_path": managed.to_string_lossy(), "added_env": [],
            "pointer_added": settings.get("managed_hooks_path").is_none(),
            "schema_added": settings.get("schema_version").is_none(),
            "env_added": settings.get("managed_hooks_env_vars").is_none()
        })
    });
    let hooks_after;
    if remove {
        hooks_after = adapter.remove_hooks(&encode(&hooks))?;
        if let Some(r) = &existing_receipt {
            if let Some(env) = settings
                .get_mut("managed_hooks_env_vars")
                .and_then(Value::as_array_mut)
            {
                env.retain(|v| !r["added_env"].as_array().unwrap().contains(v));
                if env.is_empty() && r["env_added"] == true {
                    settings
                        .as_object_mut()
                        .unwrap()
                        .remove("managed_hooks_env_vars");
                }
            }
            if r["pointer_added"] == true
                && current_managed == managed
                && settings["managed_hooks_path"] == "tako-managed-hooks.json"
                && parse(Some(if hooks_after.is_empty() {
                    "{}"
                } else {
                    &hooks_after
                }))? == json!({})
            {
                settings
                    .as_object_mut()
                    .unwrap()
                    .remove("managed_hooks_path");
            }
            if r["schema_added"] == true
                && settings["schema_version"] == 1
                && settings.get("managed_hooks_path").is_none()
            {
                settings.as_object_mut().unwrap().remove("schema_version");
            }
        }
    } else {
        if settings["disableAllHooks"] == true {
            return Err("Muse hooks are disabled".into());
        }
        hooks_after = adapter.apply_hooks(&encode(&hooks))?;
        let obj = settings.as_object_mut().unwrap();
        obj.entry("schema_version").or_insert(json!(1));
        obj.entry("managed_hooks_path")
            .or_insert(json!("tako-managed-hooks.json"));
        let env = obj
            .entry("managed_hooks_env_vars")
            .or_insert(json!([]))
            .as_array_mut()
            .unwrap();
        for name in ENV {
            if !env.contains(&json!(name)) {
                env.push(json!(name));
                let added = ownership["added_env"].as_array_mut().unwrap();
                if !added.contains(&json!(name)) {
                    added.push(json!(name));
                }
            }
        }
    }
    let mut changes = vec![
        Change::new(managed, preserved(&hooks_before, hooks_after))?,
        Change::new(path, preserved(&original, encode(&settings)))?,
        Change::secure(
            receipt_path,
            if remove {
                None
            } else {
                Some(encode(&ownership))
            },
        )?,
    ];
    // Removing an absent integration must not create files or reformat user data.
    if remove && existing_receipt.is_none() {
        changes.retain(|c| c.before.is_some());
    }
    with_backups(changes, remove)
}

fn with_backups(mut changes: Vec<Change>, remove: bool) -> Result<Vec<Change>, String> {
    if !remove {
        let mut backups = Vec::new();
        for change in changes
            .iter()
            .filter(|c| c.changed() && !c.path.to_string_lossy().ends_with(".tako-muse-receipt"))
        {
            if let Some(before) = &change.before {
                let backup = super::fs_util::backup_path(&change.path);
                if changes.iter().any(|c| c.path == backup) {
                    return Err("backup path overlaps configuration".into());
                }
                let existing = transaction::read(&backup)?;
                backups.push(Change::secure(
                    backup,
                    Some(existing.unwrap_or_else(|| before.clone())),
                )?);
            }
        }
        backups.append(&mut changes);
        changes = backups;
    }
    Ok(changes)
}

pub fn run(
    adapter: &Adapter,
    path: &Path,
    remove: bool,
    yes: bool,
    diff_only: bool,
    json: bool,
) -> Result<(), String> {
    let changes = plan(adapter, path, remove)?;
    let changed = changes.iter().any(Change::changed);
    let diff: String = changes.iter().map(Change::diff).collect();
    let status = if diff_only {
        "diff_only"
    } else if !changed {
        if remove {
            "not_installed"
        } else {
            "already_installed"
        }
    } else if remove {
        "uninstalled"
    } else {
        "installed"
    };
    if changed && !diff_only {
        if !yes {
            print!("{diff}\nApply Tako hook changes? [y/N]: ");
            io::stdout().flush().map_err(|e| e.to_string())?;
            let mut answer = String::new();
            io::stdin()
                .lock()
                .read_line(&mut answer)
                .map_err(|e| e.to_string())?;
            if !matches!(answer.trim().to_lowercase().as_str(), "y" | "yes") {
                return Ok(());
            }
        }
        transaction::commit(&changes, None)?;
    }
    if json {
        println!(
            "{}",
            json!({"status": status, "config": path.display().to_string(), "diff": diff})
        );
    } else {
        println!("{status}: {}\n{diff}", path.display());
    }
    Ok(())
}
