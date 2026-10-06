/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use serde_json::{Value, json};

pub fn format_answer(name: &str, answer: &Value) -> Value {
    let is_ok = answer.get("ok").and_then(Value::as_bool).unwrap_or(true);
    if is_ok {
        if name == "tako_text" {
            let text = answer["result"]["text"].as_str().unwrap_or("").to_string();
            return json!({
                "content": [
                    {
                        "type": "text",
                        "text": text
                    }
                ],
                "isError": false
            });
        }
        if name == "tako_screenshot" {
            if let Some(data) = answer["result"]["data"].as_str() {
                let id = answer["result"]["id"].as_str().unwrap_or("");
                let width = answer["result"]["width"].as_f64().unwrap_or(0.0) as u64;
                let height = answer["result"]["height"].as_f64().unwrap_or(0.0) as u64;
                return json!({
                    "content": [
                        {
                            "type": "image",
                            "data": data,
                            "mimeType": "image/png"
                        },
                        {
                            "type": "text",
                            "text": format!("Screenshot of pane {id} ({width}x{height} png)")
                        }
                    ],
                    "isError": false
                });
            }
        }
        let text = if let Some(res) = answer.get("result") {
            serde_json::to_string_pretty(res).unwrap_or_else(|_| res.to_string())
        } else {
            serde_json::to_string_pretty(answer).unwrap_or_else(|_| answer.to_string())
        };
        json!({
            "content": [
                {
                    "type": "text",
                    "text": text
                }
            ],
            "isError": false
        })
    } else {
        let error_text = if let Some(err) = answer.get("error") {
            format!(
                "{}: {}",
                err.get("code").and_then(Value::as_str).unwrap_or("error"),
                err.get("message").and_then(Value::as_str).unwrap_or("command failed")
            )
        } else {
            answer.to_string()
        };
        json!({
            "content": [
                {
                    "type": "text",
                    "text": error_text
                }
            ],
            "isError": true
        })
    }
}
