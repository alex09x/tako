/*
 * tako — Preserve user hook configuration during lifecycle hook updates
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use serde_json::Value;

// Ownership is determined from a command field, never serialized group metadata.
// Unknown/custom shell programs are preserved, even if they mention Tako.
fn owned(hook: &Value, replacement: &Value, agent: &str) -> bool {
    let Some(command) = hook.get("command").and_then(Value::as_str) else { return false };
    if hook.get("type").and_then(Value::as_str).is_some_and(|t| t != "command") {
        return false;
    }
    if replacement.get("command").and_then(Value::as_str) == Some(command) {
        return true;
    }
    let words: Vec<_> = command.split_whitespace().collect();
    if words.len() != 3 || words.iter().any(|w| w.contains([';', '|', '&', '$', '`', '\'', '"', '<', '>'])) {
        return false;
    }
    let executable = std::path::Path::new(words[0]);
    let is_dispatcher = executable.file_name().is_some_and(|n| n == "tako-hook")
        && (executable.is_absolute() || words[0] == "tako-hook");
    let same_agent = words[1] == agent || (agent == "antigravity" && words[1] == "agy");
    is_dispatcher && same_agent && matches!(words[2],
        "user_prompt_submit" | "start" | "working" | "pre_invocation" |
        "stop" | "done" | "post_invocation" | "permission_request" | "approval" |
        "question" | "waiting_for_input" | "ask" | "question_answered" | "post_question")
}

fn validate(items: &[Value]) -> Result<(), String> {
    for item in items {
        let obj = item.as_object().ok_or("hook entries must be objects")?;
        if let Some(inner) = obj.get("hooks") {
            let hooks = inner.as_array().ok_or("matcher hooks must be an array")?;
            if hooks.iter().any(|h| !h.is_object()) {
                return Err("matcher hook entries must be objects".into());
            }
        } else if !obj.contains_key("command") {
            return Err("hook entry has neither hooks nor command".into());
        }
    }
    Ok(())
}

/// Update only recognized commands; retain matcher metadata and all user siblings.
pub fn merge_event(existing: Option<&Value>, template: &Value, agent: &str, remove: bool) -> Result<Value, String> {
    let groups = template.as_array().ok_or("template event must be an array")?;
    let first = groups.first().ok_or("empty hook template")?;
    let replacement = first.get("hooks").and_then(Value::as_array)
        .and_then(|a| a.first()).unwrap_or(first);
    let Some(existing) = existing else {
        return Ok(if remove { Value::Array(vec![]) } else { template.clone() });
    };
    let items = existing.as_array().ok_or("existing event must be an array; refusing to overwrite")?;
    validate(items)?;
    let mut result = Vec::new();
    let mut found = false;
    for item in items {
        let disabled = item.get("enabled") == Some(&Value::Bool(false));
        if let Some(inner) = item.get("hooks").and_then(Value::as_array) {
            let mut group = item.clone();
            let mut kept = Vec::new();
            let mut changed = false;
            for hook in inner {
                if owned(hook, replacement, agent) {
                    if !remove && (disabled || hook.get("enabled") == Some(&Value::Bool(false))) {
                        return Err("Tako hook is disabled; refusing to re-enable it".into());
                    }
                    found = true;
                    changed = true;
                    if !remove { kept.push(replacement.clone()); }
                } else {
                    kept.push(hook.clone());
                }
            }
            // An originally empty or unrecognized group is user data, too.
            if !changed || !kept.is_empty() {
                group["hooks"] = Value::Array(kept);
                result.push(group);
            }
        } else if owned(item, replacement, agent) {
            if !remove && disabled {
                return Err("Tako hook is disabled; refusing to re-enable it".into());
            }
            found = true;
            if !remove {
                if first.get("hooks").is_some() { result.push(first.clone()); }
                else { result.push(replacement.clone()); }
            }
        } else {
            result.push(item.clone());
        }
    }
    if !remove && !found { result.extend(groups.iter().cloned()); }
    Ok(Value::Array(result))
}
