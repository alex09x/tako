/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

pub mod control;
pub mod diagnostics;
pub mod inspect;
pub mod layout;
pub mod redact;
pub mod review;
pub mod session;

pub use control::*;
pub use diagnostics::*;
pub use inspect::*;
pub use layout::*;
pub use redact::*;
pub use review::*;
pub use session::*;

use serde_json::Value;

pub fn render(cmd: &str, result: &Value) -> String {
    match cmd {
        "version" => format!(
            "{} {} (build {}), protocol {}",
            result["app"].as_str().unwrap_or("Tako"),
            result["version"].as_str().unwrap_or("?"),
            result["build"].as_str().unwrap_or("?"),
            result["protocol"]
        ),
        "tree" => {
            let mut out = String::new();
            for window in result["windows"].as_array().into_iter().flatten() {
                out += &format!("window {}\n", window["id"].as_str().unwrap_or(""));
                for tab in window["tabs"].as_array().into_iter().flatten() {
                    let mut head = match tab["index"].as_f64() {
                        Some(i) => format!("  tab {}", i as u64),
                        None => format!("  tab {}", tab["id"].as_str().unwrap_or("")),
                    };
                    if let Some(t) = tab["title"].as_str().filter(|t| !t.is_empty()) {
                        head += &format!("  \"{t}\"");
                    }
                    if tab["selected"].as_bool() == Some(true) {
                        head += "  (shown)";
                    }
                    out += &head;
                    out.push('\n');
                    let panes: Vec<&Value> =
                        tab["panes"].as_array().into_iter().flatten().collect();
                    let has_hierarchy = panes
                        .iter()
                        .any(|p| p.get("parent").is_some() || p.get("children").is_some());
                    if has_hierarchy {
                        for pane in panes
                            .iter()
                            .filter(|p| p.get("parent").is_none() || p["parent"].is_null())
                        {
                            out += &pane_line(pane, 2);
                            if pane["collapsed"].as_bool() != Some(true) {
                                if let Some(children_ids) = pane["children"].as_array() {
                                    for cid in children_ids.iter().filter_map(Value::as_str) {
                                        if let Some(child_pane) =
                                            panes.iter().find(|p| p["id"].as_str() == Some(cid))
                                        {
                                            out += &pane_line(child_pane, 3);
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        match tab.get("layout").filter(|l| !l.is_null()) {
                            Some(layout) => outline(&mut out, layout, &panes, 2),
                            None => {
                                for pane in &panes {
                                    out += &pane_line(pane, 2);
                                }
                            }
                        }
                    }
                }
            }
            out
        }
        "text" => {
            let mut out = result["text"].as_str().unwrap_or("").to_string();
            out.push('\n');
            out
        }
        "screenshot" => {
            let width = result["width"].as_f64().unwrap_or(0.0) as u64;
            let height = result["height"].as_f64().unwrap_or(0.0) as u64;
            let id = result["id"].as_str().unwrap_or("");
            format!("screenshot of pane {id} ({width}x{height} png)\n")
        }
        "send" | "type" | "key" | "focus" | "title" | "notify" => String::new(),
        "tab-new" | "split" | "collapse" | "expand" => {
            format!("{}\n", result["id"].as_str().unwrap_or(""))
        }
        "close" => format!("{}\n", result["state"].as_str().unwrap_or("")),
        "run" if result.get("state").is_none() => {
            format!("{}\n", result["id"].as_str().unwrap_or(""))
        }
        "last" | "wait" | "run" => command_report(result),
        "status" => status_report(result),
        "progress" => progress_report(result),
        "find" => find_report(result),
        "dialog" => dialog_report(result),
        "ask" => format!("{}\n", serde_json::to_string(result).unwrap_or_default()),
        "workspace" => workspace_report(result),
        "layout" => layout_report(result),
        "action" => action_report(result),
        "task" => task_report(result),
        "resume" => resume_report(result),
        "input" => input_report(result),
        "broadcast" => broadcast_report(result),
        "session" => session_report(result),
        "overlay" => overlay_report(result),
        "review" => review_report(result),
        "history" => history_report(result),
        "triggers" => triggers_report(result),
        "grant" => grant_report(result),
        "activity" => activity_report(result),
        _ => format!("{result}\n"),
    }
}
