/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

//! `pane`, `window` and `config`: a pane's place on its tab's canvas, the
//! windows themselves, and the settings in the config file.

use serde_json::{Map, Value, json};

pub const PANE_STATES: [&str; 4] = ["tiled", "floating", "maximized", "minimized"];

pub fn parse(
    cmd: &str,
    args: &mut Map<String, Value>,
    positional: &mut Vec<String>,
) -> Result<Option<()>, String> {
    match cmd {
        "pane" => pane(args, positional)?,
        "window" => window(args, positional)?,
        "config" => config(args, positional)?,
        _ => return Ok(None),
    }
    if !positional.is_empty() {
        return Err(format!("unexpected argument {}", positional[0]));
    }
    Ok(Some(()))
}

fn action(positional: &mut Vec<String>, default: &str) -> String {
    if positional.is_empty() {
        default.to_string()
    } else {
        positional.remove(0)
    }
}

/// A state name as `--state` and `pane set` take it.
pub fn pane_state(name: &str) -> Result<String, String> {
    let canonical = match name.to_lowercase().as_str() {
        "tiled" | "tile" | "docked" | "dock" | "grid" => "tiled",
        "floating" | "float" => "floating",
        "maximized" | "maximize" | "zoomed" => "maximized",
        "minimized" | "minimize" | "shelf" => "minimized",
        _ => {
            return Err(format!(
                "unknown pane state \"{name}\"; use {}",
                PANE_STATES.join(", ")
            ));
        }
    };
    Ok(canonical.to_string())
}

fn pane(args: &mut Map<String, Value>, positional: &mut Vec<String>) -> Result<(), String> {
    let action = match action(positional, "state").as_str() {
        "get" => "state".to_string(),
        "tile" => "dock".to_string(),
        other => other.to_string(),
    };
    if args.contains_key("state") && action != "set" {
        return Err(format!(
            "pane {action} does not take --state; use pane set STATE"
        ));
    }
    if args.contains_key("frame") && action != "frame" {
        return Err(format!("pane {action} does not take a frame"));
    }
    match action.as_str() {
        "state" | "float" | "dock" | "maximize" | "unmaximize" | "minimize" | "restore" => {}
        "frame" => positional_frame(args, positional)?,
        "set" => match (positional.is_empty(), args.contains_key("state")) {
            (true, true) => {}
            (true, false) => {
                return Err(format!(
                    "pane set needs a state: {}",
                    PANE_STATES.join(", ")
                ));
            }
            (false, true) => return Err("give the state once: pane set STATE".into()),
            (false, false) => {
                let state = pane_state(&positional.remove(0))?;
                args.insert("state".into(), json!(state));
            }
        },
        "move" => {
            let window = args
                .get("window")
                .and_then(Value::as_str)
                .unwrap_or("new")
                .to_string();
            if window != "new" {
                return Err("pane move takes --window new".into());
            }
            args.insert("window".into(), json!("new"));
        }
        other => {
            return Err(format!(
                "unknown pane action \"{other}\"; use state, set, float, dock, maximize, unmaximize, minimize, restore, frame or move"
            ));
        }
    }
    args.insert("action".into(), json!(action));
    Ok(())
}

fn window(args: &mut Map<String, Value>, positional: &mut Vec<String>) -> Result<(), String> {
    let action = action(positional, "list");
    // `--window` names an existing window; `new` is pane move's word for a
    // window yet to open, never a stand-in for the current one.
    match args.get("window").and_then(Value::as_str) {
        Some(_) if matches!(action.as_str(), "list" | "new") => {
            return Err(format!("window {action} does not take --window"));
        }
        Some("new") => {
            return Err(
                "--window new is for pane move; name an existing window (takoctl window list)"
                    .into(),
            );
        }
        _ => {}
    }
    match action.as_str() {
        "list" | "new" | "state" | "minimize" | "restore" | "focus" | "close" => {}
        "unminimize" => {
            args.insert("action".into(), json!("restore"));
            return Ok(());
        }
        "fullscreen" => {
            let value = action_value(positional, "toggle");
            if !matches!(value.as_str(), "on" | "off" | "toggle") {
                return Err(format!(
                    "window fullscreen takes on, off or toggle, not \"{value}\""
                ));
            }
            args.insert("value".into(), json!(value));
        }
        "frame" => positional_frame(args, positional)?,
        other => {
            return Err(format!(
                "unknown window action \"{other}\"; use list, new, state, minimize, restore, fullscreen, focus, frame or close"
            ));
        }
    }
    if args.contains_key("frame") && !matches!(action.as_str(), "new" | "frame") {
        return Err(format!("window {action} does not take a frame"));
    }
    if args.contains_key("state") && action != "new" {
        return Err(format!(
            "window {action} does not take --state; pane states are set with takoctl pane"
        ));
    }
    args.insert("action".into(), json!(action));
    Ok(())
}

/// `frame X Y W H` as positional numbers, or `--frame`; neither only reads.
fn positional_frame(
    args: &mut Map<String, Value>,
    positional: &mut Vec<String>,
) -> Result<(), String> {
    if positional.is_empty() {
        return Ok(());
    }
    if args.contains_key("frame") {
        return Err("give the frame once: --frame or X Y W H".into());
    }
    if positional.len() != 4 {
        return Err("frame takes four numbers: X Y WIDTH HEIGHT".into());
    }
    let frame = frame(&std::mem::take(positional).join(","))?;
    args.insert("frame".into(), frame);
    Ok(())
}

fn action_value(positional: &mut Vec<String>, default: &str) -> String {
    if positional.is_empty() {
        default.to_string()
    } else {
        positional.remove(0).to_lowercase()
    }
}

/// `X,Y,W,H` as four numbers.
pub fn frame(text: &str) -> Result<Value, String> {
    let parts: Vec<&str> = text.split(',').map(str::trim).collect();
    if parts.len() != 4 {
        return Err("a frame is four numbers: X,Y,WIDTH,HEIGHT".into());
    }
    let mut numbers = Vec::with_capacity(4);
    for part in parts {
        let n: f64 = part
            .parse()
            .map_err(|_| format!("\"{part}\" in the frame is not a number"))?;
        if !n.is_finite() {
            return Err(format!("\"{part}\" in the frame is not a number"));
        }
        numbers.push(json!(n));
    }
    if numbers[2].as_f64() < Some(100.0) || numbers[3].as_f64() < Some(60.0) {
        return Err("a window frame must be at least 100 x 60 points".into());
    }
    Ok(Value::Array(numbers))
}

fn config(args: &mut Map<String, Value>, positional: &mut Vec<String>) -> Result<(), String> {
    let action = action(positional, "list");
    match action.as_str() {
        "list" | "path" | "reload" => {}
        "get" | "unset" => {
            if positional.is_empty() {
                return Err(format!("config {action} needs at least one setting"));
            }
            let mut keys = Vec::new();
            for key in positional.drain(..) {
                if key.contains('=') {
                    return Err(format!(
                        "config {action} takes setting names, not KEY=VALUE: {key}"
                    ));
                }
                keys.push(json!(key));
            }
            args.insert("keys".into(), Value::Array(keys));
        }
        "set" | "add" => {
            if positional.is_empty() {
                return Err(format!("config {action} needs KEY=VALUE"));
            }
            let mut settings = Vec::new();
            for setting in positional.drain(..) {
                let (key, value) = setting
                    .split_once('=')
                    .ok_or_else(|| format!("expected KEY=VALUE: {setting}"))?;
                let key = key.trim();
                if key.is_empty() {
                    return Err("a setting's name cannot be empty".into());
                }
                settings.push(json!({"key": key, "value": value.trim()}));
            }
            args.insert("settings".into(), Value::Array(settings));
        }
        "shortcut" | "shortcuts" => {
            args.insert("action".into(), json!("shortcut"));
            return shortcut(args, positional);
        }
        other => {
            return Err(format!(
                "unknown config action \"{other}\"; use list, get, set, add, unset, shortcut, path or reload"
            ));
        }
    }
    if args.contains_key("filter") && action != "list" {
        return Err("--filter is for config list".into());
    }
    args.insert("action".into(), json!(action));
    Ok(())
}

/// `config shortcut [list]`, `set ACTION TRIGGER`, `unset ACTION`, `reset`.
fn shortcut(args: &mut Map<String, Value>, positional: &mut Vec<String>) -> Result<(), String> {
    if args.contains_key("filter") {
        return Err("--filter is for config list".into());
    }
    let op = action(positional, "list");
    let wants = match op.as_str() {
        "list" | "reset" => 0,
        "unset" => 1,
        "set" => 2,
        other => {
            return Err(format!(
                "unknown shortcut action \"{other}\"; use list, set ACTION TRIGGER, unset ACTION or reset"
            ));
        }
    };
    if positional.len() < wants {
        return Err(match op.as_str() {
            "set" => "config shortcut set needs an ACTION and a TRIGGER, e.g. new_tab cmd+t".into(),
            _ => format!("config shortcut {op} needs an ACTION"),
        });
    }
    if wants >= 1 {
        args.insert("name".into(), json!(positional.remove(0)));
    }
    if wants == 2 {
        args.insert("trigger".into(), json!(positional.remove(0)));
    }
    if args.contains_key("force") && op != "set" {
        return Err("--force is for config shortcut set".into());
    }
    args.insert("op".into(), json!(op));
    Ok(())
}
