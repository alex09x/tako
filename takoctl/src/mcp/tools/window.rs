/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

//! Pane states, windows and settings for agents: the same requests
//! `takoctl pane`, `window` and `config` send.

use serde_json::{Map, Value, json};

use super::McpTool;
use crate::cli::window::{PANE_STATES, frame, pane_state};
use crate::mcp::capabilities::CapabilityScope;

pub fn tools() -> Vec<McpTool> {
    vec![
        McpTool {
            name: "tako_pane",
            description: "Read or change where a pane sits on its tab: tiled on the grid, floating over it, maximized over the whole tab, or minimized to the shelf; or move it into a new window.",
            required_scopes: &[CapabilityScope::Layout],
            input_schema: json!({
                "type": "object",
                "properties": {
                    "action": {
                        "type": "string",
                        "enum": ["state", "set", "float", "dock", "maximize", "unmaximize", "minimize", "restore", "frame", "move"],
                        "description": "What to do (default: state, which only reads)"
                    },
                    "state": {
                        "type": "string",
                        "enum": PANE_STATES,
                        "description": "For action set: the state to put the pane in"
                    },
                    "target": { "type": "string", "description": "Pane ID (default: current pane)" },
                    "frame": {
                        "type": "array", "items": { "type": "number" }, "minItems": 4, "maxItems": 4,
                        "description": "For frame: x, y, width, height in points from the tab's top left; floats the pane there"
                    },
                    "select": {
                        "type": "boolean",
                        "description": "false keeps the keyboard where it is (default true)"
                    }
                }
            }),
        },
        McpTool {
            name: "tako_window",
            description: "List Tako's windows, open a new one (optionally with its pane floating, maximized or minimized), or minimize, restore, focus, resize or full-screen a window.",
            required_scopes: &[CapabilityScope::Layout],
            input_schema: json!({
                "type": "object",
                "properties": {
                    "action": {
                        "type": "string",
                        "enum": ["list", "new", "state", "minimize", "restore", "fullscreen", "focus", "frame"],
                        "description": "What to do (default: list)"
                    },
                    "window": { "type": "string", "description": "Window ID from list (default: the target pane's window)" },
                    "target": { "type": "string", "description": "A pane in the window (default: current pane)" },
                    "fullscreen": { "type": "string", "enum": ["on", "off", "toggle"] },
                    "frame": {
                        "type": "array", "items": { "type": "number" }, "minItems": 4, "maxItems": 4,
                        "description": "x, y, width, height in screen points from the bottom left"
                    },
                    "cwd": { "type": "string", "description": "For new: the pane's directory" },
                    "state": { "type": "string", "enum": PANE_STATES, "description": "For new: the pane's state" }
                }
            }),
        },
        McpTool {
            name: "tako_config",
            description: "Read Tako's settings, or write them to the user's config file (set, add a repeatable line, unset) and reload.",
            required_scopes: &[CapabilityScope::Config],
            input_schema: json!({
                "type": "object",
                "properties": {
                    "action": {
                        "type": "string",
                        "enum": ["list", "get", "set", "add", "unset", "shortcut", "path", "reload"],
                        "description": "What to do (default: list)"
                    },
                    "keys": { "type": "array", "items": { "type": "string" }, "description": "For get and unset" },
                    "settings": {
                        "type": "object",
                        "additionalProperties": { "type": "string" },
                        "description": "For set and add: setting name to value"
                    },
                    "filter": { "type": "string", "description": "For list: names containing this" },
                    "shortcut": {
                        "type": "object",
                        "properties": {
                            "op": { "type": "string", "enum": ["list", "set", "unset", "reset"] },
                            "name": { "type": "string", "description": "The action, e.g. new_tab" },
                            "trigger": { "type": "string", "description": "The chord, e.g. cmd+t" },
                            "force": { "type": "boolean" }
                        },
                        "description": "For action shortcut: the Keys section of Settings"
                    }
                }
            }),
        },
    ]
}

/// The socket command for one of these tools, its arguments added to
/// `req`; None for any other tool.
pub fn build(
    name: &str,
    args: &Value,
    req: &mut Map<String, Value>,
) -> Result<Option<&'static str>, String> {
    let text = |key: &str| args.get(key).and_then(Value::as_str).map(str::to_string);
    let cmd = match name {
        "tako_pane" => {
            let action = text("action").unwrap_or_else(|| "state".into());
            if action == "set" {
                let state = text("state").ok_or("action set needs a state")?;
                req.insert("state".into(), json!(pane_state(&state)?));
            }
            if action == "move" {
                req.insert("window".into(), json!("new"));
            }
            if let Some(items) = args.get("frame").and_then(Value::as_array) {
                let joined: Vec<String> = items.iter().map(|v| v.to_string()).collect();
                req.insert("frame".into(), frame(&joined.join(","))?);
            }
            if let Some(select) = args.get("select").and_then(Value::as_bool) {
                req.insert("select".into(), json!(select));
            }
            req.insert("action".into(), json!(action));
            "pane"
        }
        "tako_window" => {
            let action = text("action").unwrap_or_else(|| "list".into());
            if let Some(window) = text("window") {
                req.insert("window".into(), json!(window));
            }
            if let Some(value) = text("fullscreen") {
                req.insert("value".into(), json!(value));
            }
            if let Some(items) = args.get("frame").and_then(Value::as_array) {
                let joined: Vec<String> = items.iter().map(|v| v.to_string()).collect();
                req.insert("frame".into(), frame(&joined.join(","))?);
            }
            if let Some(cwd) = text("cwd") {
                req.insert("cwd".into(), json!(cwd));
            }
            if let Some(state) = text("state") {
                req.insert("state".into(), json!(pane_state(&state)?));
            }
            req.insert("action".into(), json!(action));
            "window"
        }
        "tako_config" => {
            let action = text("action").unwrap_or_else(|| "list".into());
            // Arguments of the wrong type are refused before anything is
            // sent: a malformed value must never become a write.
            if let Some(keys) = args.get("keys") {
                let keys = keys
                    .as_array()
                    .ok_or("keys must be a list of setting names")?;
                if keys.iter().any(|k| !k.is_string()) {
                    return Err("every key must be a string".into());
                }
                req.insert("keys".into(), Value::Array(keys.clone()));
            }
            if let Some(settings) = args.get("settings") {
                let settings = settings
                    .as_object()
                    .ok_or("settings must be an object of name to string value")?;
                let mut pairs = Vec::with_capacity(settings.len());
                for (key, value) in settings {
                    let value = value
                        .as_str()
                        .ok_or_else(|| format!("the value of {key} must be a string"))?;
                    pairs.push(json!({"key": key, "value": value}));
                }
                req.insert("settings".into(), Value::Array(pairs));
            }
            if let Some(filter) = args.get("filter") {
                let filter = filter.as_str().ok_or("filter must be a string")?;
                req.insert("filter".into(), json!(filter));
            }
            if let Some(shortcut) = args.get("shortcut") {
                let shortcut = shortcut.as_object().ok_or("shortcut must be an object")?;
                for key in ["op", "name", "trigger"] {
                    if let Some(value) = shortcut.get(key) {
                        let value = value
                            .as_str()
                            .ok_or_else(|| format!("shortcut {key} must be a string"))?;
                        req.insert(key.into(), json!(value));
                    }
                }
                if let Some(force) = shortcut.get("force") {
                    let force = force
                        .as_bool()
                        .ok_or("shortcut force must be true or false")?;
                    req.insert("force".into(), json!(force));
                }
            }
            req.insert("action".into(), json!(action));
            "config"
        }
        _ => return Ok(None),
    };
    Ok(Some(cmd))
}
