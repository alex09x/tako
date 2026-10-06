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

pub fn expand_path(file: &str) -> String {
    if let Some(stripped) = file.strip_prefix("~/") {
        if let Ok(home) = std::env::var("HOME") {
            return format!("{home}/{stripped}");
        }
    } else if file == "~" {
        if let Ok(home) = std::env::var("HOME") {
            return home;
        }
    } else if !file.starts_with('/') {
        if let Ok(cwd) = std::env::current_dir() {
            return cwd.join(file).to_string_lossy().to_string();
        }
    }
    file.to_string()
}


pub fn layout_report(result: &Value) -> String {
    if result.get("saved") == Some(&Value::Bool(true)) {
        let path = result["path"].as_str().unwrap_or("layout.json");
        let tabs = result["tabs"].as_f64().unwrap_or(0.0) as u64;
        let panes = result["panes"].as_f64().unwrap_or(0.0) as u64;
        return format!(
            "Saved layout to {path} ({tabs} tab{}, {panes} pane{})\n",
            if tabs == 1 { "" } else { "s" },
            if panes == 1 { "" } else { "s" }
        );
    }
    if result.get("applied") == Some(&Value::Bool(true)) {
        let path = result["path"].as_str().unwrap_or("");
        let tabs = result["tabs"].as_f64().unwrap_or(0.0) as u64;
        let panes = result["panes"].as_f64().unwrap_or(0.0) as u64;
        let started = result["programs_started"].as_f64().unwrap_or(0.0) as u64;
        let suppressed = result["programs_suppressed"].as_f64().unwrap_or(0.0) as u64;
        let trusted = result["trusted"].as_bool().unwrap_or(true);

        let mut msg = if path.is_empty() {
            format!(
                "Applied layout ({tabs} tab{}, {panes} pane{})",
                if tabs == 1 { "" } else { "s" },
                if panes == 1 { "" } else { "s" }
            )
        } else {
            format!(
                "Applied layout from {path} ({tabs} tab{}, {panes} pane{})",
                if tabs == 1 { "" } else { "s" },
                if panes == 1 { "" } else { "s" }
            )
        };
        if started > 0 {
            msg.push_str(&format!(
                ", {started} program{} started",
                if started == 1 { "" } else { "s" }
            ));
        }
        if suppressed > 0 {
            msg.push_str(&format!(
                ", {suppressed} program{} suppressed (untrusted layout)",
                if suppressed == 1 { "" } else { "s" }
            ));
        } else if !trusted {
            msg.push_str(" (untrusted layout: programs not started)");
        }
        msg.push('\n');
        return msg;
    }
    if result.get("approved") == Some(&Value::Bool(true)) {
        let path = result["path"].as_str().unwrap_or("");
        let sha = result["sha256"].as_str().unwrap_or("");
        let short_sha = if sha.len() >= 12 { &sha[..12] } else { sha };
        return format!("Approved layout {path} (sha256: {short_sha})\n");
    }
    if let Some(status) = result["status"].as_str() {
        let path = result["path"].as_str().unwrap_or("");
        let sha = result["sha256"].as_str().unwrap_or("");
        let short_sha = if sha.len() >= 12 { &sha[..12] } else { sha };
        return format!("Layout {path}: {status} (sha256: {short_sha})\n");
    }
    format!("{result}\n")
}


pub fn pane_line(pane: &Value, depth: usize) -> String {
    let mark = if pane["focused"].as_bool() == Some(true) {
        "*"
    } else {
        " "
    };
    let mut line = format!(
        "{}{mark}{}  {}  {}",
        "  ".repeat(depth),
        pane["id"].as_str().unwrap_or(""),
        pane["cwd"].as_str().unwrap_or("-"),
        pane["title"].as_str().unwrap_or("")
    );
    if let Some(label) = pane["label"].as_str() {
        line += &format!("  [{label}]");
    }
    if let Some(status) = pane["status"].as_str() {
        if status != "unknown" {
            line += &format!("  [{status}");
            if let Some(text) = pane["statusText"].as_str() {
                line += &format!(": {text}");
            }
            line.push(']');
        }
    }
    if let Some(summary) = pane["childrenStatus"].as_str() {
        line += &format!("  ({summary})");
    }
    if pane["collapsed"].as_bool() == Some(true) {
        line += "  [collapsed]";
    }
    line.push('\n');
    line
}


pub fn outline(out: &mut String, node: &Value, panes: &[&Value], depth: usize) {
    if let Some(id) = node["pane"].as_str() {
        match panes.iter().find(|p| p["id"].as_str() == Some(id)) {
            Some(pane) => *out += &pane_line(pane, depth),
            None => *out += &format!("{} {id}\n", "  ".repeat(depth)),
        }
        return;
    }
    let ratio = node["ratio"]
        .as_f64()
        .map(|r| format!(" {:.0}%", r * 100.0))
        .unwrap_or_default();
    *out += &format!(
        "{}split {}{ratio}\n",
        "  ".repeat(depth),
        node["split"].as_str().unwrap_or("?")
    );
    for child in node["children"].as_array().into_iter().flatten() {
        outline(out, child, panes, depth + 1);
    }
}
