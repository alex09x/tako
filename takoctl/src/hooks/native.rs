/*
 * tako — Native agent hook configurations
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */
use super::adapter::Adapter;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};

pub fn muse_root() -> PathBuf {
    muse_root_from(
        std::env::var_os("XDG_CONFIG_HOME").map(PathBuf::from),
        super::fs_util::resolve_home_path("~/.config"),
    )
}

pub(super) fn muse_root_from(xdg: Option<PathBuf>, fallback: PathBuf) -> PathBuf {
    xdg.filter(|p| p.is_absolute())
        .unwrap_or(fallback)
        .join("muse")
}

pub fn adapter(provider: &str) -> Adapter {
    let claude = Adapter::from_json_str(super::adapter::ADAPTER_CLAUDE).unwrap();
    let mut hooks = serde_json::Map::new();
    for (event, dispatch, fallback) in [
        ("SessionStart", "session_start", "UserPromptSubmit"),
        ("UserPromptSubmit", "user_prompt_submit", "UserPromptSubmit"),
        (
            "PermissionRequest",
            "permission_request",
            "PermissionRequest",
        ),
        ("PreToolUse", "question", "Elicitation"),
        ("PostToolUse", "post_tool_use", "UserPromptSubmit"),
        ("PostToolUseFailure", "post_tool_use", "UserPromptSubmit"),
        ("Stop", "stop", "Stop"),
        ("StopFailure", "stop_failure", "Stop"),
        ("SessionEnd", "session_end", "SessionEnd"),
    ] {
        let mut command = claude.hooks[fallback][0]["hooks"][0]["command"]
            .as_str()
            .unwrap()
            .to_owned();
        let old = match fallback {
            "PermissionRequest" => "permission_request",
            "Elicitation" => "question",
            "Stop" => "stop",
            "SessionEnd" => "session_end",
            _ => "user_prompt_submit",
        };
        command = command.replace(
            &format!("tako-hook claude {old}"),
            &format!("tako-hook {provider} {dispatch}"),
        );
        if event == "SessionStart" {
            command = command
                .replace("status set working", "status clear")
                .replace(" --text \"Thinking...\"", "")
                .replace("progress indeterminate", "progress clear");
        } else if event == "StopFailure" {
            command = command.replace("status set done", "status set error");
        }
        let matcher = if event == "PreToolUse" {
            "^(ask_user_question|request_user_input|ask_question)$"
        } else {
            ""
        };
        hooks.insert(
            event.into(),
            json!([{ "matcher": matcher, "hooks": [{
                "type": "command", "command": command, "timeout": 5
            }]}]),
        );
    }
    Adapter {
        name: provider.into(),
        title: if provider == "qwen" {
            "Qwen Code"
        } else {
            "Muse"
        }
        .into(),
        aliases: vec![],
        config_path: if provider == "qwen" {
            "~/.qwen/settings.json"
        } else {
            "~/.config/muse/settings.json"
        }
        .into(),
        format: "json".into(),
        hook_field: "hooks".into(),
        hooks: Value::Object(hooks),
    }
}

pub fn validate(root: &Value) -> Result<(), String> {
    let obj = root.as_object().ok_or("configuration must be an object")?;
    if obj.get("disableAllHooks").is_some_and(|v| !v.is_boolean()) {
        return Err("disableAllHooks must be a boolean".into());
    }
    if let Some(hooks) = obj.get("hooks") {
        for value in hooks.as_object().ok_or("hooks must be an object")?.values() {
            for group in value.as_array().ok_or("hook event must be an array")? {
                let group = group.as_object().ok_or("hook group must be an object")?;
                if group.get("enabled").is_some_and(|v| !v.is_boolean()) {
                    return Err("hook group enabled must be a boolean".into());
                }
                if group.get("matcher").is_some_and(|v| !v.is_string()) {
                    return Err("hook matcher must be a string".into());
                }
                for hook in group
                    .get("hooks")
                    .and_then(Value::as_array)
                    .ok_or("hook group must contain a hooks array")?
                {
                    if !hook.is_object() || !hook["type"].is_string() {
                        return Err("hook must be an object with a type".into());
                    }
                    if ["enabled", "async"]
                        .iter()
                        .any(|key| hook.get(*key).is_some_and(|v| !v.is_boolean()))
                    {
                        return Err("hook activation flags must be booleans".into());
                    }
                    if hook.get("timeout").is_some_and(|v| !v.is_number()) {
                        return Err("hook timeout must be a number of seconds".into());
                    }
                    if hook["type"] == "command" && !hook["command"].is_string() {
                        return Err("command hook must contain a command string".into());
                    }
                }
            }
        }
    }
    Ok(())
}

pub fn active(adapter: &Adapter, root: &Value) -> bool {
    if validate(root).is_err() || root["disableAllHooks"] == true {
        return false;
    }
    adapter
        .hooks
        .as_object()
        .unwrap()
        .iter()
        .all(|(event, expected)| {
            root["hooks"][event].as_array().is_some_and(|groups| {
                groups.iter().any(|g| {
                    g["enabled"] != false
                        && g["matcher"] == expected[0]["matcher"]
                        && g["hooks"].as_array().is_some_and(|hs| {
                            hs.iter().any(|h| {
                                h["enabled"] != false
                                    && h["type"] == "command"
                                    && h["command"] == expected[0]["hooks"][0]["command"]
                                    && h["async"] != true
                            })
                        })
                })
            })
        })
}

pub fn managed_path(settings: &Value, path: &Path) -> Result<PathBuf, String> {
    match settings.get("managed_hooks_path") {
        Some(v) => {
            let raw = v
                .as_str()
                .filter(|s| !s.is_empty())
                .ok_or("managed_hooks_path must be a nonempty string")?;
            let p = PathBuf::from(raw);
            Ok(if p.is_absolute() {
                p
            } else {
                path.parent().unwrap_or(Path::new(".")).join(p)
            })
        }
        None => Ok(path.with_file_name("tako-managed-hooks.json")),
    }
}

pub fn status_at(query: &str, override_path: &str, json: bool) -> Result<(), String> {
    let adapter = super::adapter::find_adapter(query)
        .ok_or_else(|| format!("unknown agent '{query}' (use 'takoctl hooks list')"))?;
    let path = adapter.resolve_path(Some(override_path));
    let installed = adapter.is_installed(&path);
    if json {
        println!(
            "{}",
            serde_json::to_string_pretty(&vec![json!({
                "name": adapter.name, "title": adapter.title,
                "config_path": path.display().to_string(),
                "installed": installed, "file_exists": path.exists(),
            })])
            .map_err(|e| e.to_string())?
        );
    } else {
        println!("{} ({})", adapter.title, adapter.name);
        println!("  Config:    {}", path.display());
        println!(
            "  Status:    {}",
            if installed { "installed" } else { "not installed" }
        );
        println!("  File exists: {}", if path.exists() { "yes" } else { "no" });
    }
    Ok(())
}
