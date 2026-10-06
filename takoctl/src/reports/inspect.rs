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

pub fn history_report(result: &Value) -> String {
    let mut out = String::new();
    let entries = result["entries"].as_array();
    let Some(entries) = entries else {
        return "no history recorded\n".to_string();
    };
    if entries.is_empty() {
        return "no history recorded\n".to_string();
    }
    for entry in entries {
        let raw_cmd = entry["command"].as_str().unwrap_or("");
        let cmd = sanitize_terminal_control(raw_cmd);
        let mut line = format!("$ {cmd}");
        if let Some(raw_cwd) = entry["cwd"].as_str() {
            let cwd = sanitize_terminal_control(raw_cwd);
            line += &format!("   ({cwd})");
        }
        if let Some(code) = entry["exit_code"].as_f64() {
            line += &format!("   exit {}", code as i64);
        }
        if let Some(dur) = entry["duration"].as_f64() {
            line += &format!("   ({})", format_duration(dur));
        }
        out += &line;
        out.push('\n');
    }
    out
}

/// Sanitizes untrusted text for safe terminal display by replacing ANSI escape sequences
/// and terminal control codes (C0 controls except \t and \n, DEL, and C1 controls)
/// with safe visible caret/escape representations.
pub fn sanitize_terminal_control(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        let u = c as u32;
        if c == '\n' {
            out.push('\n');
        } else if c == '\t' {
            out.push('\t');
        } else if c == '\x1b' {
            out.push_str("^[");
        } else if u < 0x20 {
            // C0 controls (< 0x20 except \t, \n): Caret notation ^@, ^A, ... ^G (BEL), ^H (BS), ^M (CR), etc.
            if let Some(ch) = char::from_u32(u + 0x40) {
                out.push('^');
                out.push(ch);
            }
        } else if u == 0x7f {
            out.push_str("^?");
        } else if (0x80..=0x9f).contains(&u) {
            // C1 controls: safely encode as unicode hex escape
            out.push_str(&format!("\\u{{{:04X}}}", u));
        } else {
            out.push(c);
        }
    }
    out
}


pub fn progress_report(result: &Value) -> String {
    let state = result["state"].as_str().unwrap_or("none");
    let mut out = state.to_string();
    if let Some(prog) = result["progress"].as_f64() {
        out += &format!(" ({}%)", prog as u64);
    }
    out.push('\n');
    out
}


pub fn status_report(result: &Value) -> String {
    let status = result["status"].as_str().unwrap_or("unknown");
    let mut out = status.to_string();
    if let Some(text) = result["text"].as_str() {
        out += &format!(" ({text})");
    }
    if let Some(ttl) = result["ttl"].as_f64() {
        if ttl < 60.0 {
            out += &format!(" [TTL: {:.1}s]", ttl);
        } else {
            out += &format!(" [TTL: {}m {}s]", (ttl as u64) / 60, (ttl as u64) % 60);
        }
    }
    if result["unread"].as_bool() == Some(true) {
        out += " [unread]";
    }
    out.push('\n');
    out
}


pub fn format_duration(seconds: f64) -> String {
    if seconds < 0.001 {
        "<1ms".to_string()
    } else if seconds < 1.0 {
        format!("{}ms", (seconds * 1000.0).round() as u64)
    } else if seconds < 10.0 {
        format!("{:.1}s", seconds)
    } else if seconds < 60.0 {
        format!("{}s", seconds.round() as u64)
    } else {
        let mins = (seconds as u64) / 60;
        let secs = (seconds as u64) % 60;
        format!("{}m {:02}s", mins, secs)
    }
}

/// A command as `last` reports it: `$ line   (cwd)   exit N   (dur)`, then its output.

pub fn command_report(result: &Value) -> String {
    if let Some(process) = result.get("process") {
        return process_report(process, result);
    }
    if result["state"].as_str() == Some("gone") {
        return format!(
            "command {} is no longer kept\n",
            result["command"]["ref"].as_str().unwrap_or("?")
        );
    }
    let command = &result["command"];
    if command.is_null() {
        return "no command marked by the shell in this pane (shell integration off?)\n".into();
    }
    let status = match (
        result["state"].as_str(),
        command["running"].as_bool(),
        command["exitCode"].as_f64(),
    ) {
        (Some("timeout"), _, _) => "still running (timed out waiting)".to_string(),
        (_, Some(true), _) => "running".to_string(),
        _ if command["abandoned"].as_bool() == Some(true) => {
            "abandoned (a new prompt came before it ended)".to_string()
        }
        (_, _, Some(code)) => format!("exit {}", code as i64),
        _ => "ended, no exit status".to_string(),
    };
    let mut out = format!(
        "$ {}",
        command["input"]
            .as_str()
            .unwrap_or("(command line not reported by the shell)")
    );
    if let Some(cwd) = command["cwd"].as_str() {
        out += &format!("   ({cwd})");
    }
    out += &format!("   {status}");
    if let Some(dur) = command["duration"]
        .as_f64()
        .or_else(|| result["duration"].as_f64())
    {
        out += &format!("   ({})", format_duration(dur));
    }
    if let Some(r) = command["ref"].as_str() {
        out += &format!("   [{r}]");
    }
    out.push('\n');
    if result["more"].as_bool() == Some(true) {
        out += "...\n";
    }
    if result["incomplete"].as_bool() == Some(true) {
        out += "(some of its output was written over or is no longer kept)\n";
    }
    let output = result["output"].as_str().unwrap_or("");
    if !output.is_empty() {
        out += output;
        out.push('\n');
    }
    out
}

/// Matches grouped as the panel groups them: by pane, then by the command
/// that printed them.

pub fn find_report(result: &Value) -> String {
    let mut out = String::new();
    let mut pane = None;
    let mut command = None;
    for m in result["matches"].as_array().into_iter().flatten() {
        let id = m["id"].as_str().unwrap_or("");
        if pane != Some(id) {
            pane = Some(id);
            command = None;
            let label = match m["pane"].as_str() {
                Some(p) => format!("{} -- {p}", m["place"].as_str().unwrap_or("")),
                None => m["place"].as_str().unwrap_or("").to_string(),
            };
            out += &format!("{}  {label}\n", &id[..id.len().min(8)]);
        }
        let heading = m.get("command").map(|c| {
            let mut h = format!(
                "$ {}",
                c["input"].as_str().unwrap_or("(command line not reported)")
            );
            h += &format!("   {}", c["status"].as_str().unwrap_or(""));
            if let Some(cwd) = c["cwd"].as_str() {
                h += &format!("   {cwd}");
            }
            h
        });
        if heading != command {
            if let Some(h) = &heading {
                out += &format!("  {h}\n");
            }
            command = heading;
        }
        out += &format!("    {}\n", m["line"].as_str().unwrap_or("").trim_end());
    }
    if out.is_empty() {
        out = "no matches\n".into();
    } else if result["more"].as_bool() == Some(true) {
        out += "... more matches (--limit N)\n";
    }
    out
}

/// The questions up, each as its frame, text and buttons; or what was pressed.

pub fn dialog_report(result: &Value) -> String {
    if let Some(label) = result["pressed"].as_str() {
        return format!(
            "pressed {label} in \"{}\"\n",
            result["title"].as_str().unwrap_or("")
        );
    }
    let mut out = String::new();
    for d in result["dialogs"].as_array().into_iter().flatten() {
        out += &format!(
            "{}  {}\n",
            d["window"].as_str().unwrap_or(""),
            d["title"].as_str().unwrap_or("")
        );
        for line in d["text"].as_str().unwrap_or("").lines() {
            out += &format!("  {line}\n");
        }
        let selected = d["selected"].as_str();
        let buttons: Vec<String> = d["buttons"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
            .map(|b| {
                if Some(b) == selected {
                    format!("[{b}]")
                } else {
                    b.to_string()
                }
            })
            .collect();
        out += &format!("  buttons: {}\n", buttons.join("  "));
    }
    if out.is_empty() {
        "no question is up\n".into()
    } else {
        out
    }
}

/// A program run started: its argv, how it ended, what the pane shows.

pub fn process_report(process: &Value, result: &Value) -> String {
    let argv: Vec<&str> = process["argv"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
        .collect();
    let status = match (
        result["state"].as_str(),
        process["running"].as_bool(),
        process["exitCode"].as_f64(),
    ) {
        _ if process["startError"].is_string() => {
            format!(
                "could not start: {}",
                process["startError"].as_str().unwrap_or("")
            )
        }
        (Some("timeout"), _, _) => "still running (timed out waiting)".to_string(),
        (_, Some(true), _) => "running".to_string(),
        (_, _, Some(code)) => format!("exit {}", code as i64),
        _ => "exited, status unknown".to_string(),
    };
    let mut out = format!("{}   {status}\n", argv.join(" "));
    let output = result["output"].as_str().unwrap_or("");
    if !output.is_empty() {
        out += output;
        out.push('\n');
    }
    out
}
