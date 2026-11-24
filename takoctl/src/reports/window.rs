/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use serde_json::Value;

/// `pane`: the pane and its state; after `move`, the window it went to.
pub fn pane_report(result: &Value) -> String {
    let id = result["id"].as_str().unwrap_or("");
    if let Some(window) = result["window"].as_str() {
        return format!("{id} moved to {window}\n");
    }
    let mut line = format!("{id}  {}", result["state"].as_str().unwrap_or("?"));
    if let Some(back) = result["restoresTo"].as_str() {
        line += &format!(" (restores to {back})");
    }
    let frame = &result["frame"];
    if frame.is_object() {
        let n = |k: &str| frame[k].as_f64().unwrap_or(0.0).round() as i64;
        line += &format!("  {}x{} at {},{}", n("width"), n("height"), n("x"), n("y"));
    }
    if result["shown"].as_bool() == Some(false) {
        line += "  [tab not shown]";
    }
    line + "\n"
}

fn window_line(window: &Value) -> String {
    let frame = &window["frame"];
    let n = |k: &str| frame[k].as_f64().unwrap_or(0.0).round() as i64;
    let mut line = format!(
        "{}  {} tab{}  {}x{} at {},{}",
        window["id"].as_str().unwrap_or(""),
        window["tabs"]
            .as_u64()
            .or_else(|| window["tabs"].as_f64().map(|t| t as u64))
            .unwrap_or(0),
        if window["tabs"].as_f64() == Some(1.0) {
            ""
        } else {
            "s"
        },
        n("width"),
        n("height"),
        n("x"),
        n("y"),
    );
    for flag in ["minimized", "fullscreen", "key"] {
        if window[flag].as_bool() == Some(true) {
            line += &format!("  {flag}");
        }
    }
    line + "\n"
}

/// `window`: one line per window; `new` prints the new pane's id, `close`
/// what became of the window.
pub fn window_report(result: &Value) -> String {
    if let Some(windows) = result["windows"].as_array() {
        return windows.iter().map(window_line).collect();
    }
    if result.get("frame").is_some() {
        return window_line(result);
    }
    // `new` answers with the new pane's id; `close` with what happened.
    match result["id"].as_str() {
        Some(id) => format!("{id}\n"),
        None => format!("{}\n", result["state"].as_str().unwrap_or("")),
    }
}

fn setting_lines(setting: &Value) -> String {
    let key = setting["key"].as_str().unwrap_or("");
    let set = setting["set"].as_bool() == Some(true);
    if let Some(values) = setting["values"].as_array() {
        if values.is_empty() {
            return format!("# {key} (not set)\n");
        }
        return values
            .iter()
            .map(|v| format!("{key} = {}\n", v.as_str().unwrap_or("")))
            .collect();
    }
    match (setting["value"].as_str(), set) {
        (Some(value), true) => format!("{key} = {value}\n"),
        (Some(value), false) => format!("# {key} = {value} (default)\n"),
        (None, _) => format!("# {key} (not set)\n"),
    }
}

/// One shortcut: the action, its chord (marked when the user chose it), its title.
fn shortcut_line(entry: &Value) -> String {
    let trigger = entry["trigger"].as_str().unwrap_or("-");
    let mark = if entry["custom"].as_bool() == Some(true) {
        "*"
    } else {
        " "
    };
    format!(
        "{mark}{:<24} {:<20} {}\n",
        entry["action"].as_str().unwrap_or(""),
        trigger,
        entry["title"].as_str().unwrap_or("")
    )
}

/// `config`: the settings as config-file lines -- set ones as they are,
/// defaults and unset ones commented out -- then any errors the reload saw.
pub fn config_report(result: &Value) -> String {
    let mut out = String::new();
    if let Some(shortcuts) = result["shortcuts"].as_array() {
        for entry in shortcuts {
            out += &shortcut_line(entry);
        }
    } else if let Some(settings) = result["settings"].as_array() {
        for setting in settings {
            out += &setting_lines(setting);
        }
    } else if let Some(path) = result["path"].as_str() {
        out += &format!("{path}\n");
    } else if result["reloaded"].as_bool() == Some(true) {
        out += "reloaded\n";
    }
    for error in result["errors"].as_array().into_iter().flatten() {
        out += &format!("error: {}\n", error.as_str().unwrap_or(""));
    }
    out
}
