/*
 * tako — Workspace command reports
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use serde_json::Value;

pub fn workspace_report(result: &Value) -> String {
    if let Some(workspaces) = result.get("workspaces").and_then(Value::as_array) {
        let mut out = String::new();
        for ws in workspaces {
            let active = if ws["is_active"].as_bool() == Some(true) {
                "* "
            } else {
                "  "
            };
            let name = ws["name"].as_str().unwrap_or("");
            let tabs_count = ws["tabs"].as_array().map_or(0, |a| a.len());
            let attention = ws["attention_count"].as_f64().unwrap_or(0.0) as u64;
            let mut line = format!("{active}{name} ({tabs_count} tabs)");
            if attention > 0 {
                line += &format!(" [{attention} unread]");
            }
            if let Some(root) = ws["root_directory"].as_str() {
                line += &format!("  {root}");
            }
            line.push('\n');
            out += &line;
        }
        return out;
    }
    if let Some(name) = result.get("name").and_then(Value::as_str) {
        if result.get("tabs").is_some() {
            let tabs_count = result["tabs"].as_array().map_or(0, |a| a.len());
            let attention = result["attention_count"].as_f64().unwrap_or(0.0) as u64;
            let mut line = format!("{name} ({tabs_count} tabs)");
            if attention > 0 {
                line += &format!(" [{attention} unread]");
            }
            if let Some(root) = result["root_directory"].as_str() {
                line += &format!("  {root}");
            }
            line.push('\n');
            return line;
        }
        return format!("{name}\n");
    }
    if let Some(deleted) = result.get("deleted").and_then(Value::as_str) {
        return format!("deleted {deleted}\n");
    }
    if let Some(tab) = result.get("tab").and_then(Value::as_str) {
        let ws = result["workspace"].as_str().unwrap_or("");
        return format!("assigned {tab} to {ws}\n");
    }
    if let Some(transitions) = result.get("transitions").and_then(Value::as_array) {
        let mut out = String::new();
        for t in transitions {
            let seq = t["sequence"].as_i64().unwrap_or(0);
            let from = t["from_id"].as_str().unwrap_or("?");
            let to = t["to_id"].as_str().unwrap_or("?");
            let ts = t["timestamp"].as_f64().unwrap_or(0.0);
            if seq > 0 {
                out += &format!("#{seq} {ts:.3}: {from} -> {to}\n");
            } else {
                out += &format!("{ts:.3}: {from} -> {to}\n");
            }
        }
        if let Some(tab_transitions) = result.get("tab_transitions").and_then(Value::as_array)
            && !tab_transitions.is_empty()
        {
            out += "Tab transitions:\n";
            for t in tab_transitions {
                let seq = t["sequence"].as_i64().unwrap_or(0);
                let ws = t["workspace_id"].as_str().unwrap_or("?");
                let from = t["from_id"].as_str().unwrap_or("?");
                let to = t["to_id"].as_str().unwrap_or("?");
                let ts = t["timestamp"].as_f64().unwrap_or(0.0);
                if seq > 0 {
                    out += &format!("  #{seq} {ts:.3} [{ws}]: {from} -> {to}\n");
                } else {
                    out += &format!("  {ts:.3} [{ws}]: {from} -> {to}\n");
                }
            }
        }
        return out;
    }
    format!("{result}\n")
}
