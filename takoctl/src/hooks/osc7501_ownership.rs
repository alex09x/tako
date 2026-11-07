/*
 * tako — Closed-set recognition of legacy Tako status hooks
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use std::path::Path;

use serde_json::Value;

/// Returns `true` for the five modern agents whose status is handled natively
/// via `OSC 7501` in Tako's terminal engine rather than per-agent shell hooks.
pub fn uses_native_osc7501(agent_name: &str) -> bool {
    matches!(
        agent_name,
        "claude" | "codex" | "antigravity" | "qwen" | "muse"
    )
}

const DISPATCHER_EVENTS: &[&str] = &[
    "user_prompt_submit",
    "start",
    "working",
    "pre_invocation",
    "stop",
    "done",
    "post_invocation",
    "permission_request",
    "approval",
    "question",
    "waiting_for_input",
    "ask",
    "question_answered",
    "post_question",
    "session_start",
    "session_end",
    "post_tool_use",
    "stop_failure",
    "interrupt",
];

fn is_three_word_tako_hook_call(clause: &str, agent: &str) -> bool {
    let words: Vec<&str> = clause.split_whitespace().collect();
    if words.len() != 3
        || words
            .iter()
            .any(|w| w.contains([';', '|', '&', '$', '`', '\'', '"', '<', '>']))
    {
        return false;
    }
    let exe = Path::new(words[0]);
    let is_dispatcher = exe.file_name().is_some_and(|n| n == "tako-hook")
        && (exe.is_absolute() || words[0] == "tako-hook");
    let same_agent = words[1] == agent || (agent == "antigravity" && words[1] == "agy");
    is_dispatcher && same_agent && DISPATCHER_EVENTS.contains(&words[2])
}

fn is_legacy_inline_takoctl_fallback(clause: &str) -> bool {
    let trimmed = clause.trim();
    if let Some(rest) = trimmed
        .strip_prefix("if [ -n \"$TAKO_SOCKET\" ] && [ \"${#TAKO_SURFACE_ID}\" -eq 36 ]; then ")
    {
        let valid_end = rest.ends_with("; fi; :")
            || rest.ends_with("; fi")
            || rest.ends_with("; fi; echo \"{}\"");
        return valid_end
            && (rest.starts_with("takoctl status ")
                || rest.starts_with(
                    "takoctl notify \"$CLAUDE_NOTIFICATION\" --title \"Claude Code\"",
                ));
    }
    if trimmed.starts_with("[ -z \"$TAKO_SOCKET\" ] && eval $(ps eww -p $PPID")
        && trimmed.contains("takoctl status set ")
        && trimmed.ends_with("echo \"{}\"")
    {
        return true;
    }
    false
}

/// Closed-set recognition of Tako-owned status hook commands across historical
/// `takoctl` and `AgentHooksTool` releases. Custom user scripts, `echo`, Prod
/// hooks (`prod-code-guard`, `prod-raw-agent-events`), and Rex hooks return `false`.
pub fn is_tako_owned_status_command(command: &str, agent: &str) -> bool {
    let trimmed = command.trim();
    if is_three_word_tako_hook_call(trimmed, agent) {
        return true;
    }
    if matches!(agent, "qwen" | "muse") && super::native::generated_command_owned(trimmed, agent) {
        return true;
    }
    if is_legacy_inline_takoctl_fallback(trimmed) {
        return true;
    }
    if let Some(after_if) = trimmed.strip_prefix("if command -v tako-hook >/dev/null 2>&1; then ")
        && let Some((then_part, else_tail)) = after_if.split_once("; else ")
        && let Some(else_part) = else_tail.strip_suffix("; fi; :")
        && is_three_word_tako_hook_call(then_part.trim(), agent)
    {
        let else_trimmed = else_part.trim();
        if is_three_word_tako_hook_call(else_trimmed, agent)
            || is_legacy_inline_takoctl_fallback(else_trimmed)
        {
            return true;
        }
    }
    false
}

pub(super) fn is_owned_hook_entry(v: &Value, agent: &str) -> bool {
    v.get("type")
        .and_then(Value::as_str)
        .is_none_or(|t| t == "command")
        && v.get("command")
            .and_then(Value::as_str)
            .is_some_and(|c| is_tako_owned_status_command(c, agent))
}

pub fn json_contains_owned_hooks(root: &Value, agent: &str, hook_field: &str) -> bool {
    let Some(hooks_obj) = root.get(hook_field).and_then(Value::as_object) else {
        return false;
    };
    for val in hooks_obj.values() {
        let Some(items) = val.as_array() else {
            continue;
        };
        for item in items {
            if let Some(inner) = item.get("hooks").and_then(Value::as_array) {
                if inner.iter().any(|h| is_owned_hook_entry(h, agent)) {
                    return true;
                }
            } else if is_owned_hook_entry(item, agent) {
                return true;
            }
        }
    }
    false
}
