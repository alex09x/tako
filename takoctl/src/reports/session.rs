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

pub fn overlay_report(result: &Value) -> String {
    if let Some(true) = result.get("closed").and_then(Value::as_bool) {
        let id = result["id"].as_str().unwrap_or("pane");
        return format!("Closed overlay for pane {id}.\n");
    }
    if let Some(false) = result.get("closed").and_then(Value::as_bool) {
        let id = result["id"].as_str().unwrap_or("pane");
        return format!("No active overlay to close on pane {id}.\n");
    }
    if let Some(true) = result.get("reloaded").and_then(Value::as_bool) {
        let id = result["id"].as_str().unwrap_or("pane");
        return format!("Reloaded overlay for pane {id}.\n");
    }
    if let Some(open) = result.get("open").and_then(Value::as_bool) {
        let id = result["id"].as_str().unwrap_or("pane");
        if open {
            let file = result["file"].as_str().unwrap_or("");
            let file_type = result["type"].as_str().unwrap_or("document");
            let title = result["title"].as_str().unwrap_or("");
            let sandboxed = result["sandboxed"].as_str().unwrap_or("");
            let split = result.get("split").and_then(Value::as_str);

            let mut out = String::new();
            if let Some(s) = split {
                out.push_str(&format!("Overlay active on pane {id} (split {s}):\n"));
            } else {
                out.push_str(&format!("Overlay active on pane {id}:\n"));
            }
            out.push_str(&format!("  File: {file}\n"));
            out.push_str(&format!("  Type: {file_type}\n"));
            if !title.is_empty() && title != file {
                out.push_str(&format!("  Title: {title}\n"));
            }
            if !sandboxed.is_empty() {
                out.push_str(&format!("  Sandboxed: {sandboxed}\n"));
            }
            return out;
        } else {
            return format!("No overlay active on pane {id}.\n");
        }
    }
    format!("{result}\n")
}


pub fn session_report(result: &Value) -> String {
    if result.get("exported") == Some(&Value::Bool(true)) {
        let path = result["path"].as_str().unwrap_or("");
        let windows = result["windows"].as_f64().unwrap_or(0.0) as u64;
        let panes = result["panes"].as_f64().unwrap_or(0.0) as u64;
        let resumes = result["resumes"].as_f64().unwrap_or(0.0) as u64;
        let mut msg = format!(
            "Exported session to {path} ({windows} window{}, {panes} pane{})",
            if windows == 1 { "" } else { "s" },
            if panes == 1 { "" } else { "s" }
        );
        if resumes > 0 {
            msg.push_str(&format!(
                ", {resumes} resume binding{}",
                if resumes == 1 { "" } else { "s" }
            ));
        }
        msg.push('\n');
        return msg;
    }
    if result.get("imported") == Some(&Value::Bool(true)) {
        let path = result["path"].as_str().unwrap_or("");
        let windows = result["windows"].as_f64().unwrap_or(0.0) as u64;
        return format!(
            "Imported session from {path} ({windows} window{} created)\n  (Untrusted session: control sequences dropped, nothing runs automatically)\n",
            if windows == 1 { "" } else { "s" }
        );
    }
    if let Some(ver) = result.get("format_version").and_then(Value::as_f64) {
        let format_ver = ver as u64;
        let tako_ver = result["tako_version"].as_str().unwrap_or("unknown");
        let exported_at = result["exported_at"].as_str().unwrap_or("");
        let windows = result["windows"].as_f64().unwrap_or(0.0) as u64;
        let panes = result["panes"].as_f64().unwrap_or(0.0) as u64;
        let resumes = result["resumes"].as_f64().unwrap_or(0.0) as u64;
        let mut out = format!(
            "Session file (format v{format_ver}, exported by Tako {tako_ver} at {exported_at}):\n  {windows} window{}, {panes} pane{}",
            if windows == 1 { "" } else { "s" },
            if panes == 1 { "" } else { "s" }
        );
        if resumes > 0 {
            out.push_str(&format!(
                ", {resumes} resume record{}",
                if resumes == 1 { "" } else { "s" }
            ));
        }
        out.push('\n');
        return out;
    }
    format!("{result}\n")
}


pub fn resume_report(result: &Value) -> String {
    if result["cleared"].as_bool() == Some(true) {
        return format!(
            "Resume session cleared for pane {}\n",
            result["id"].as_str().unwrap_or("")
        );
    }
    if result["executed"].as_bool() == Some(true) {
        return format!(
            "Executed resume command for pane {}\n",
            result["id"].as_str().unwrap_or("")
        );
    }
    if result["approved"].as_bool() == Some(true) && result.get("prefix").is_some() {
        return format!(
            "Approved prefix \"{}\" for directory \"{}\"\n",
            result["prefix"].as_str().unwrap_or(""),
            result["cwd"].as_str().unwrap_or("")
        );
    }
    if result["has_resume"].as_bool() == Some(false) {
        return format!(
            "No resume session recorded for pane {}\n",
            result["id"].as_str().unwrap_or("")
        );
    }
    let mut out = String::new();
    if let Some(id) = result["id"].as_str() {
        out += &format!("Pane: {}\n", id);
    }
    if let Some(argv) = result["argv"].as_array() {
        let cmd = argv
            .iter()
            .filter_map(Value::as_str)
            .collect::<Vec<_>>()
            .join(" ");
        out += &format!("Command: {}\n", cmd);
    }
    if let Some(cwd) = result["cwd"].as_str() {
        out += &format!("Directory: {}\n", cwd);
    }
    if let Some(is_imported) = result["is_imported"].as_bool() {
        if is_imported {
            out += "Imported: yes (untrusted, auto-run disabled)\n";
        }
    }
    if let Some(approved) = result["approved"].as_bool() {
        out += &format!(
            "Auto-run approved: {}\n",
            if approved { "yes" } else { "no" }
        );
    }
    if let Some(recorded_at) = result["recorded_at"].as_str() {
        out += &format!("Recorded at: {}\n", recorded_at);
    }
    out
}


pub fn action_report(result: &Value) -> String {
    if let Some(actions) = result.get("actions").and_then(Value::as_array) {
        if actions.is_empty() {
            return "No project actions found\n".into();
        }
        let project = result["project"].as_str().unwrap_or("");
        let status = result["status"].as_str().unwrap_or("untrusted");
        let mut out = if let Some(name) = result["name"].as_str() {
            format!("Project actions for {name} ({project}) [{status}]:\n")
        } else {
            format!("Project actions for {project} [{status}]:\n")
        };
        for act in actions {
            let id = act["id"].as_str().unwrap_or("");
            let title = act["title"].as_str().unwrap_or(id);
            let target = act["target"].as_str().unwrap_or("split");
            let cmd = act["command"]
                .as_array()
                .map(|arr| {
                    arr.iter()
                        .filter_map(Value::as_str)
                        .collect::<Vec<_>>()
                        .join(" ")
                })
                .unwrap_or_default();
            out += &format!("  * {id} ({target}): {title}\n");
            if !cmd.is_empty() {
                out += &format!("      $ {cmd}\n");
            }
        }
        return out;
    }
    if result.get("ran") == Some(&Value::Bool(true)) {
        let id = result["id"].as_str().unwrap_or("");
        let title = result["title"].as_str().unwrap_or(id);
        let target = result["target"].as_str().unwrap_or("");
        let cwd = result["cwd"].as_str().unwrap_or("");
        return format!("Ran action '{title}' ({id}) in {target} (cwd: {cwd})\n");
    }
    if result.get("approved") == Some(&Value::Bool(true)) {
        let path = result["path"].as_str().unwrap_or("");
        let sha = result["sha256"].as_str().unwrap_or("");
        let short_sha = if sha.len() >= 12 { &sha[..12] } else { sha };
        return format!("Approved project actions at {path} (sha256: {short_sha})\n");
    }
    if let Some(status) = result["status"].as_str() {
        let path = result["path"].as_str().unwrap_or("");
        let sha = result["sha256"].as_str().unwrap_or("");
        let count = result["actions_count"].as_f64().unwrap_or(0.0) as u64;
        let short_sha = if sha.len() >= 12 { &sha[..12] } else { sha };
        return format!(
            "Project actions {path}: {status} (sha256: {short_sha}, {count} action{})\n",
            if count == 1 { "" } else { "s" }
        );
    }
    format!("{result}\n")
}


pub fn task_report(result: &Value) -> String {
    if let Some(tasks) = result.get("tasks").and_then(Value::as_array) {
        if tasks.is_empty() {
            return "No worktree tasks found\n".into();
        }
        let mut out = "Worktree tasks:\n".to_string();
        for t in tasks {
            let name = t["name"].as_str().unwrap_or("");
            let branch = t["branch"].as_str().unwrap_or("");
            let status = t["status"].as_str().unwrap_or("running");
            let worktree = t["worktree"].as_str().unwrap_or("");
            let ahead = t["ahead"].as_f64().unwrap_or(0.0) as u64;
            let behind = t["behind"].as_f64().unwrap_or(0.0) as u64;
            let changed = t["changed_files"].as_f64().unwrap_or(0.0) as u64;
            let changes_str = if changed == 0 {
                "clean".to_string()
            } else {
                format!(
                    "{changed} changed file{}",
                    if changed == 1 { "" } else { "s" }
                )
            };
            out += &format!("  * {name} ({branch}): [{status}] (worktree: {worktree})\n");
            out += &format!("      ahead: {ahead}, behind: {behind}, {changes_str}\n");
        }
        return out;
    }
    if result.get("created") == Some(&Value::Bool(true)) {
        let name = result["name"].as_str().unwrap_or("");
        let branch = result["branch"].as_str().unwrap_or("");
        let base = result["base"].as_str().unwrap_or("");
        let target = result["target"].as_str().unwrap_or("tab");
        let worktree = result["worktree"].as_str().unwrap_or("");
        return format!(
            "Created worktree task '{name}' on branch {branch} (base: {base}, target: {target})\n  Worktree: {worktree}\n"
        );
    }
    if result.get("finished") == Some(&Value::Bool(true)) {
        let name = result["name"].as_str().unwrap_or("");
        let archived = result["archived"].as_bool().unwrap_or(false);
        let editor = result["opened_in_editor"].as_bool().unwrap_or(false);
        let worktree = result["worktree"].as_str().unwrap_or("");
        if archived {
            return format!("Archived worktree task '{name}' (removed worktree at {worktree})\n");
        } else if editor {
            return format!("Finished worktree task '{name}' (opened in editor at {worktree})\n");
        } else {
            return format!("Finished worktree task '{name}'\n");
        }
    }
    if let Some(status) = result.get("status").and_then(Value::as_str) {
        let name = result["name"].as_str().unwrap_or("");
        let branch = result["branch"].as_str().unwrap_or("");
        let worktree = result["worktree"].as_str().unwrap_or("");
        let ahead = result["ahead"].as_f64().unwrap_or(0.0) as u64;
        let behind = result["behind"].as_f64().unwrap_or(0.0) as u64;
        let changed = result["changed_files"].as_f64().unwrap_or(0.0) as u64;
        let changes_str = if changed == 0 {
            "clean".to_string()
        } else {
            format!(
                "{changed} changed file{}",
                if changed == 1 { "" } else { "s" }
            )
        };
        return format!(
            "Worktree task '{name}' ({branch}): [{status}]\n  Worktree: {worktree}\n  ahead: {ahead}, behind: {behind}, {changes_str}\n"
        );
    }
    format!("{result}\n")
}


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
    format!("{result}\n")
}


