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

pub(crate) fn answer(json: bool, answer: &Value) -> String {
    if json {
        format!("{answer}\n")
    } else {
        report(&answer["result"])
    }
}

pub(super) fn report(result: &Value) -> String {
    if let Some(config) = result["effective_config"].as_str() {
        let scope = result["scope"].as_str().unwrap_or("pane");
        let id = result["scope_id"]
            .as_str()
            .or_else(|| result["workspace"].as_str())
            .or_else(|| result["target"].as_str())
            .unwrap_or("current");
        let theme = result["theme"].as_str().unwrap_or("inherit");
        return format!("# {scope} {id}: {theme}\n{config}");
    }
    if let Some(config) = result["config"].as_str() {
        return config.into();
    }
    for key in ["themes", "fonts", "keys"] {
        if let Some(rows) = result[key].as_array() {
            let mut output = String::new();
            for row in rows {
                if let Some(value) = row.as_str() {
                    output += &format!("{value}\n");
                } else {
                    output += &row["name"]
                        .as_str()
                        .map(String::from)
                        .unwrap_or_else(|| row.to_string());
                    if key == "themes" {
                        output += if row["is_user"] == true {
                            " (user)"
                        } else {
                            " (builtin)"
                        };
                        if let Some(path) = row["path"].as_str() {
                            output += &format!("  {path}");
                        }
                    }
                    output.push('\n');
                }
            }
            return output;
        }
    }
    let action = result["action"].as_str().unwrap_or("theme");
    let name = result["name"].as_str().unwrap_or("");
    let mut output = format!("{action} {name}");
    if let Some(scope) = result["scope"].as_str() {
        output += &format!(" ({scope})");
    }
    output.push('\n');
    output
}
