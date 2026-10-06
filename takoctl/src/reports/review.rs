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
pub fn review_report(result: &Value) -> String {
    if let Some(closed) = result.get("closed").and_then(Value::as_bool) {
        let id = result["id"].as_str().unwrap_or("pane");
        return if closed {
            format!("Closed diff review on pane {id}.\n")
        } else {
            format!("No active diff review on pane {id}.\n")
        };
    }

    if let Some(true) = result.get("sent").and_then(Value::as_bool) {
        let id = result["id"].as_str().unwrap_or("pane");
        let target = result["target"].as_str().unwrap_or("unknown");
        let msg = result["message"].as_str().unwrap_or("");
        let mut out = format!("Sent diff review feedback from pane {id} to pane {target}.\n");
        if !msg.is_empty() {
            out.push_str("Feedback summary:\n");
            for line in msg.lines() {
                let safe_line = sanitize_terminal_control(line);
                out.push_str(&format!("  {safe_line}\n"));
            }
        }
        return out;
    }

    if let Some(comment_id) = result.get("comment_id").and_then(Value::as_str) {
        let file = sanitize_terminal_control(result["file"].as_str().unwrap_or(""));
        let line = result["line"].as_f64().unwrap_or(0.0) as u64;
        return format!("Added comment {comment_id} on {file}:{line}.\n");
    }

    if let Some(removed) = result.get("removed").and_then(Value::as_bool) {
        return if removed {
            "Removed review comment.\n".to_string()
        } else {
            "Review comment not found.\n".to_string()
        };
    }

    if let Some(true) = result.get("cleared").and_then(Value::as_bool) {
        return "Cleared all review comments.\n".to_string();
    }

    if let Some(comments) = result.get("comments").and_then(Value::as_array) {
        if comments.is_empty() {
            return "No review comments recorded.\n".to_string();
        }
        let mut out = format!("Review comments ({}):\n", comments.len());
        for c in comments {
            let id = c["id"].as_str().unwrap_or("");
            let file = sanitize_terminal_control(c["file"].as_str().unwrap_or(""));
            let line = c["line"].as_f64().unwrap_or(0.0) as u64;
            let text = sanitize_terminal_control(c["text"].as_str().unwrap_or(""));
            out.push_str(&format!("  [{id}] {file}:{line}: {text}\n"));
        }
        return out;
    }

    if let Some(patch) = result.get("patch").and_then(Value::as_str) {
        let mut out = sanitize_terminal_control(patch);
        if !out.is_empty() && !out.ends_with('\n') {
            out.push('\n');
        }
        return out;
    }

    if let Some(files) = result.get("files").and_then(Value::as_array) {
        let task = sanitize_terminal_control(result["task"].as_str().unwrap_or(""));
        let base = sanitize_terminal_control(result["base"].as_str().unwrap_or("main"));
        let mut out = format!(
            "Changed files in review '{task}' against '{base}' ({}):\n",
            files.len()
        );
        for f in files {
            let path = sanitize_terminal_control(f["path"].as_str().unwrap_or(""));
            let status = f["status"].as_str().unwrap_or("modified");
            let status_char = match status {
                "added" => "A",
                "deleted" => "D",
                "renamed" => "R",
                "untracked" => "?",
                _ => "M",
            };
            let adds = f["insertions"].as_f64().unwrap_or(0.0) as u64;
            let dels = f["deletions"].as_f64().unwrap_or(0.0) as u64;
            out.push_str(&format!("  {status_char}  {path} (+{adds}, -{dels})\n"));
        }
        return out;
    }

    if let Some(open) = result.get("open").and_then(Value::as_bool) {
        let id = result["id"].as_str().unwrap_or("pane");
        if open {
            let task = sanitize_terminal_control(result["task"].as_str().unwrap_or(""));
            let base = sanitize_terminal_control(result["base"].as_str().unwrap_or("main"));
            let files_count = result["files_count"].as_f64().unwrap_or(0.0) as u64;
            let comments_count = result["comments_count"].as_f64().unwrap_or(0.0) as u64;
            let target = result.get("target").and_then(Value::as_str);
            let mut out = format!("Diff review active on pane {id}:\n");
            out.push_str(&format!("  Worktree/Task: {task}\n"));
            out.push_str(&format!("  Base branch:   {base}\n"));
            out.push_str(&format!("  Changed files: {files_count}\n"));
            out.push_str(&format!("  Comments:      {comments_count}\n"));
            if let Some(t) = target {
                let safe_target = sanitize_terminal_control(t);
                out.push_str(&format!("  Target pane:   {safe_target}\n"));
            }
            return out;
        } else {
            return format!("No active diff review on pane {id}.\n");
        }
    }

    format!("{result}\n")
}


