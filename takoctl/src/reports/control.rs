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
use super::inspect::sanitize_terminal_control;
pub fn activity_report(result: &Value) -> String {
    if let Some(true) = result.get("cleared").and_then(Value::as_bool) {
        let id = result["id"].as_str().unwrap_or("pane");
        return format!("Activity log cleared for pane {id}.\n");
    }
    if let Some(exported) = result.get("exported").and_then(Value::as_str) {
        let id = result["id"].as_str().unwrap_or("pane");
        return format!("Exported activity log for pane {id} to {exported}\n");
    }
    if let Some(json_str) = result.get("json").and_then(Value::as_str) {
        return format!("{json_str}\n");
    }
    let id = result["id"].as_str().unwrap_or("pane");
    if let Some(entries) = result["entries"].as_array() {
        if entries.is_empty() {
            return format!("No automated activity recorded for pane {id}.\n");
        }
        let mut out = format!(
            "Automated activity log for pane {id} ({} entries):\n",
            entries.len()
        );
        for entry in entries {
            let client = sanitize_terminal_control(entry["client"].as_str().unwrap_or("unknown"));
            let action = sanitize_terminal_control(entry["action"].as_str().unwrap_or(""));
            let ts = sanitize_terminal_control(entry["timestamp"].as_str().unwrap_or(""));
            out += &format!("  [{ts}] {client}: {action}\n");
        }
        return out;
    }
    format!("{result}\n")
}


pub fn grant_report(result: &Value) -> String {
    if let Some(token) = result["token"].as_str() {
        let client = result["client"].as_str().unwrap_or("unknown");
        let scopes = result["scopes"]
            .as_array()
            .map(|a| {
                a.iter()
                    .filter_map(Value::as_str)
                    .collect::<Vec<_>>()
                    .join(", ")
            })
            .unwrap_or_default();
        return format!("token: {token}\nclient: {client}\nscopes: [{scopes}]\n");
    }
    if let Some(revoked) = result["revoked"].as_bool() {
        return format!("revoked: {revoked}\n");
    }
    if let Some(grants) = result["grants"].as_array() {
        if grants.is_empty() {
            return "no grants\n".into();
        }
        let mut out = String::new();
        for g in grants {
            let id = g["id"].as_str().unwrap_or("");
            let client = g["client"].as_str().unwrap_or("");
            let scopes = g["scopes"]
                .as_array()
                .map(|a| {
                    a.iter()
                        .filter_map(Value::as_str)
                        .collect::<Vec<_>>()
                        .join(", ")
                })
                .unwrap_or_default();
            out += &format!("{id} {client} [{scopes}]\n");
        }
        return out;
    }
    format!("{result}\n")
}


pub fn triggers_report(result: &Value) -> String {
    if let Some(id) = result.get("id").and_then(Value::as_str) {
        let pattern = result["pattern"].as_str().unwrap_or("");
        let action = result["action"].as_str().unwrap_or("highlight");
        let safe_pattern = sanitize_terminal_control(pattern);
        let safe_action = sanitize_terminal_control(action);
        return format!("Added trigger {id}: \"{safe_pattern}\" ({safe_action})\n");
    }
    if let Some(removed) = result.get("removed").and_then(Value::as_str) {
        let safe_id = sanitize_terminal_control(removed);
        return format!("Removed trigger {safe_id}\n");
    }
    if let Some(true) = result.get("cleared").and_then(Value::as_bool) {
        return "Cleared dynamic triggers\n".to_string();
    }
    let mut out = String::new();
    let triggers = result["triggers"].as_array();
    let Some(triggers) = triggers else {
        return "no triggers configured\n".to_string();
    };
    if triggers.is_empty() {
        return "no triggers configured\n".to_string();
    }
    for tr in triggers {
        let id = tr["id"].as_str().unwrap_or("?");
        let safe_id = sanitize_terminal_control(id);
        let raw_pat = tr["pattern"].as_str().unwrap_or("");
        let safe_pat = sanitize_terminal_control(raw_pat);
        let action = tr["action"].as_str().unwrap_or("highlight");
        let safe_action = sanitize_terminal_control(action);
        let color = tr["color"].as_str().unwrap_or("yellow");
        let safe_color = sanitize_terminal_control(color);
        let style = tr["style"].as_str().unwrap_or("background");
        let safe_style = sanitize_terminal_control(style);
        let dynamic = tr["is_dynamic"].as_bool().unwrap_or(false);
        let tag = if dynamic { "[dynamic]" } else { "[config]" };
        let mut line = format!("{safe_id}  \"{safe_pat}\"  action={safe_action}  color={safe_color}  style={safe_style}  {tag}");
        if let Some(raw_title) = tr["title"].as_str() {
            let safe_title = sanitize_terminal_control(raw_title);
            line += &format!("  title=\"{safe_title}\"");
        }
        out += &line;
        out.push('\n');
    }
    out
}


pub fn broadcast_report(result: &Value) -> String {
    let active = result["active"].as_bool().unwrap_or(false);
    if !active {
        return "Broadcast input is inactive.\n".to_string();
    }
    let count = result["count"].as_f64().unwrap_or(0.0) as usize;
    let leader = result["leader"].as_str().unwrap_or("none");
    let mut out = format!("Broadcast active across {count} panes (leader: {leader}):\n");
    if let Some(panes) = result["panes"].as_array() {
        for p in panes.iter().filter_map(Value::as_str) {
            let is_leader = p == leader;
            if is_leader {
                out += &format!("  * {p} (leader)\n");
            } else {
                out += &format!("    {p}\n");
            }
        }
    }
    out
}


pub fn input_report(result: &Value) -> String {
    if let Some(entries) = result["entries"].as_array() {
        if entries.is_empty() {
            return "No automated input activity recorded for this pane.\n".to_string();
        }
        let mut out = String::new();
        out += "Automated input activity:\n";
        for entry in entries {
            let client = entry["client"].as_str().unwrap_or("unknown");
            let action = entry["action"].as_str().unwrap_or("");
            let ts = entry["timestamp"].as_str().unwrap_or("");
            out += &format!("  [{ts}] {client}: {action}\n");
        }
        return out;
    }

    if let Some(allowed) = result.get("automation_may_type").and_then(Value::as_bool) {
        let id = result["id"].as_str().unwrap_or("");
        if result.get("owner").is_none() {
            let state = if allowed { "allowed" } else { "disallowed" };
            return format!("Automation typing {state} for pane {id}.\n");
        }
    }

    if result.get("confirmed") == Some(&Value::Bool(true)) {
        let id = result["id"].as_str().unwrap_or("");
        return format!("One-time automation typing confirmed for pane {id}.\n");
    }

    let mut out = String::new();
    let locked = result["locked"].as_bool().unwrap_or(false);
    let owner = result["owner"].as_str().unwrap_or("human");
    let id = result["id"].as_str().unwrap_or("");

    if locked {
        out += &format!("Pane {id}: locked (owner: {owner})\n");
    } else {
        out += &format!("Pane {id}: unlocked (owner: {owner})\n");
    }

    if let Some(allowed) = result["automation_may_type"].as_bool() {
        out += &format!("Automation may type: {}\n", if allowed { "yes" } else { "no" });
    }
    if let Some(creator) = result["creator_client"].as_str() {
        out += &format!("Creator client: {creator}\n");
    }

    if let (Some(client), Some(action)) = (
        result["last_client"].as_str(),
        result["last_action"].as_str(),
    ) {
        out += &format!("Last activity mark: {client}: {action}\n");
    }
    out
}


