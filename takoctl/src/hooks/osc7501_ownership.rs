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

const TOKEN_PREAMBLE: &str = "tako_hook_token=\"${TAKO_CONTROL_TOKEN-${TAKO_AUTH_TOKEN-}}\"; case \"$tako_hook_token\" in *[!0-9a-f]*) tako_hook_token=\"\";; esac; ";

/// Exact literal closed set of historical inline `takoctl` hook bodies emitted by
/// `AgentHooksTool` and `takoctl/adapters/*.json` prior to `OSC 7501`.
/// Arbitrary user-appended shell statements (e.g. `; /usr/bin/touch ...`) never match.
const LEGACY_INLINE_TEMPLATES: &[&str] = &[
    r#"if [ -n "$TAKO_SOCKET" ] && [ "${#TAKO_SURFACE_ID}" -eq 36 ]; then takoctl status set working --target "$TAKO_SURFACE_ID" --text "Thinking..." >/dev/null 2>&1 || true; takoctl progress indeterminate --target "$TAKO_SURFACE_ID" >/dev/null 2>&1 || true; fi; :"#,
    r#"if [ -n "$TAKO_SOCKET" ] && [ "${#TAKO_SURFACE_ID}" -eq 36 ] && [ "${#tako_hook_token}" -eq 64 ]; then takoctl status set working --target "$TAKO_SURFACE_ID" --text "Thinking..." >/dev/null 2>&1 || true; takoctl progress indeterminate --target "$TAKO_SURFACE_ID" >/dev/null 2>&1 || true; fi; :"#,
    r#"if [ -n "$TAKO_SOCKET" ] && [ "${#TAKO_SURFACE_ID}" -eq 36 ]; then takoctl status set done --target "$TAKO_SURFACE_ID" >/dev/null 2>&1 || true; takoctl progress clear --target "$TAKO_SURFACE_ID" >/dev/null 2>&1 || true; fi; :"#,
    r#"if [ -n "$TAKO_SOCKET" ] && [ "${#TAKO_SURFACE_ID}" -eq 36 ] && [ "${#tako_hook_token}" -eq 64 ]; then takoctl status set done --target "$TAKO_SURFACE_ID" >/dev/null 2>&1 || true; takoctl progress clear --target "$TAKO_SURFACE_ID" >/dev/null 2>&1 || true; fi; :"#,
    r#"if [ -n "$TAKO_SOCKET" ] && [ "${#TAKO_SURFACE_ID}" -eq 36 ]; then takoctl status set idle --target "$TAKO_SURFACE_ID" >/dev/null 2>&1 || true; takoctl progress clear --target "$TAKO_SURFACE_ID" >/dev/null 2>&1 || true; fi; :"#,
    r#"if [ -n "$TAKO_SOCKET" ] && [ "${#TAKO_SURFACE_ID}" -eq 36 ]; then takoctl status clear --target "$TAKO_SURFACE_ID" >/dev/null 2>&1 || true; takoctl progress clear --target "$TAKO_SURFACE_ID" >/dev/null 2>&1 || true; fi; :"#,
    r#"if [ -n "$TAKO_SOCKET" ] && [ "${#TAKO_SURFACE_ID}" -eq 36 ] && [ "${#tako_hook_token}" -eq 64 ]; then takoctl status clear --target "$TAKO_SURFACE_ID" >/dev/null 2>&1 || true; takoctl progress clear --target "$TAKO_SURFACE_ID" >/dev/null 2>&1 || true; fi; :"#,
    r#"if [ -n "$TAKO_SOCKET" ] && [ "${#TAKO_SURFACE_ID}" -eq 36 ]; then takoctl status set needs_approval --target "$TAKO_SURFACE_ID" --text "Approval requested" >/dev/null 2>&1 || true; takoctl progress pause --target "$TAKO_SURFACE_ID" >/dev/null 2>&1 || true; fi; :"#,
    r#"if [ -n "$TAKO_SOCKET" ] && [ "${#TAKO_SURFACE_ID}" -eq 36 ] && [ "${#tako_hook_token}" -eq 64 ]; then takoctl status set needs_approval --target "$TAKO_SURFACE_ID" --text "Approval requested" >/dev/null 2>&1 || true; takoctl progress pause --target "$TAKO_SURFACE_ID" >/dev/null 2>&1 || true; fi; :"#,
    r#"if [ -n "$TAKO_SOCKET" ] && [ "${#TAKO_SURFACE_ID}" -eq 36 ]; then takoctl status set waiting_for_input --target "$TAKO_SURFACE_ID" --text "Question" >/dev/null 2>&1 || true; fi; :"#,
    r#"if [ -n "$TAKO_SOCKET" ] && [ "${#TAKO_SURFACE_ID}" -eq 36 ] && [ "${#tako_hook_token}" -eq 64 ]; then takoctl status set waiting_for_input --target "$TAKO_SURFACE_ID" --text "Question" >/dev/null 2>&1 || true; fi; :"#,
    r#"if [ -n "$TAKO_SOCKET" ] && [ "${#TAKO_SURFACE_ID}" -eq 36 ]; then takoctl notify "$CLAUDE_NOTIFICATION" --title "Claude Code" >/dev/null 2>&1 || true; fi; :"#,
    r#"if [ -n "$TAKO_SOCKET" ] && [ "${#TAKO_SURFACE_ID}" -eq 36 ]; then takoctl status set working --target "$TAKO_SURFACE_ID" --text "Thinking..." >/dev/null 2>&1; takoctl progress indeterminate --target "$TAKO_SURFACE_ID" >/dev/null 2>&1; fi; echo "{}""#,
    r#"if [ -n "$TAKO_SOCKET" ] && [ "${#TAKO_SURFACE_ID}" -eq 36 ] && [ "${#tako_hook_token}" -eq 64 ]; then takoctl status set working --target "$TAKO_SURFACE_ID" --text "Thinking..." >/dev/null 2>&1; takoctl progress indeterminate --target "$TAKO_SURFACE_ID" >/dev/null 2>&1; fi; echo "{}""#,
    r#"if [ -n "$TAKO_SOCKET" ] && [ "${#TAKO_SURFACE_ID}" -eq 36 ]; then takoctl status set done --target "$TAKO_SURFACE_ID" >/dev/null 2>&1; takoctl progress clear --target "$TAKO_SURFACE_ID" >/dev/null 2>&1; fi; echo "{}""#,
    r#"if [ -n "$TAKO_SOCKET" ] && [ "${#TAKO_SURFACE_ID}" -eq 36 ] && [ "${#tako_hook_token}" -eq 64 ]; then takoctl status set done --target "$TAKO_SURFACE_ID" >/dev/null 2>&1; takoctl progress clear --target "$TAKO_SURFACE_ID" >/dev/null 2>&1; fi; echo "{}""#,
    "[ -z \"$TAKO_SOCKET\" ] && eval $(ps eww -p $PPID 2>/dev/null | tr \" \" \"\\n\" | grep -E \"^TAKO_(SOCKET|SURFACE_ID)=\"); export TAKO_SOCKET TAKO_SURFACE_ID; if [ -n \"$TAKO_SOCKET\" ] && [ \"${#TAKO_SURFACE_ID}\" -eq 36 ]; then takoctl status set working --text \"Thinking...\" >/dev/null 2>&1; takoctl progress indeterminate >/dev/null 2>&1; fi; echo \"{}\"",
    "[ -z \"$TAKO_SOCKET\" ] && eval $(ps eww -p $PPID 2>/dev/null | tr \" \" \"\\n\" | grep -E \"^TAKO_(SOCKET|SURFACE_ID)=\"); export TAKO_SOCKET TAKO_SURFACE_ID; if [ -n \"$TAKO_SOCKET\" ] && [ \"${#TAKO_SURFACE_ID}\" -eq 36 ] && [ \"${#tako_hook_token}\" -eq 64 ]; then takoctl status set working --text \"Thinking...\" >/dev/null 2>&1; takoctl progress indeterminate >/dev/null 2>&1; fi; echo \"{}\"",
    "[ -z \"$TAKO_SOCKET\" ] && eval $(ps eww -p $PPID 2>/dev/null | tr \" \" \"\\n\" | grep -E \"^TAKO_(SOCKET|SURFACE_ID)=\"); export TAKO_SOCKET TAKO_SURFACE_ID; if [ -n \"$TAKO_SOCKET\" ] && [ \"${#TAKO_SURFACE_ID}\" -eq 36 ]; then takoctl status set idle >/dev/null 2>&1; takoctl progress clear >/dev/null 2>&1; fi; echo \"{}\"",
    "[ -z \"$TAKO_SOCKET\" ] && eval $(ps eww -p $PPID 2>/dev/null | tr \" \" \"\\n\" | grep -E \"^TAKO_(SOCKET|SURFACE_ID)=\"); export TAKO_SOCKET TAKO_SURFACE_ID; if [ -n \"$TAKO_SOCKET\" ] && [ \"${#TAKO_SURFACE_ID}\" -eq 36 ] && [ \"${#tako_hook_token}\" -eq 64 ]; then takoctl status set idle >/dev/null 2>&1; takoctl progress clear >/dev/null 2>&1; fi; echo \"{}\"",
    r#"if [ -n "$TAKO_SOCKET" ] && [ "${#TAKO_SURFACE_ID}" -eq 36 ]; then takoctl status set working --text "Thinking..." >/dev/null 2>&1; takoctl progress indeterminate >/dev/null 2>&1; fi"#,
    r#"if [ -n "$TAKO_SOCKET" ] && [ "${#TAKO_SURFACE_ID}" -eq 36 ] && [ "${#tako_hook_token}" -eq 64 ]; then takoctl status set working --text "Thinking..." >/dev/null 2>&1; takoctl progress indeterminate >/dev/null 2>&1; fi"#,
    r#"if [ -n "$TAKO_SOCKET" ] && [ "${#TAKO_SURFACE_ID}" -eq 36 ]; then takoctl status set idle >/dev/null 2>&1; takoctl progress clear >/dev/null 2>&1; fi"#,
    r#"if [ -n "$TAKO_SOCKET" ] && [ "${#TAKO_SURFACE_ID}" -eq 36 ] && [ "${#tako_hook_token}" -eq 64 ]; then takoctl status set idle >/dev/null 2>&1; takoctl progress clear >/dev/null 2>&1; fi"#,
    r#"if [ -n "$TAKO_SOCKET" ] && [ "${#TAKO_SURFACE_ID}" -eq 36 ]; then takoctl status set working --text "Thinking..." >/dev/null 2>&1; fi"#,
    r#"if [ -n "$TAKO_SOCKET" ]; then takoctl status set working --target "$TAKO_SURFACE_ID" --text "Thinking..." >/dev/null 2>&1 || true; takoctl progress indeterminate --target "$TAKO_SURFACE_ID" >/dev/null 2>&1 || true; fi; :"#,
    r#"if [ -n "$TAKO_SOCKET" ]; then takoctl status set idle --target "$TAKO_SURFACE_ID" >/dev/null 2>&1 || true; takoctl progress clear --target "$TAKO_SURFACE_ID" >/dev/null 2>&1 || true; fi; :"#,
    r#"if [ -n "$TAKO_SOCKET" ]; then takoctl status set working --text "Thinking..." >/dev/null 2>&1; takoctl progress indeterminate >/dev/null 2>&1; fi"#,
    r#"if [ -n "$TAKO_SOCKET" ]; then takoctl status set done >/dev/null 2>&1; takoctl progress clear >/dev/null 2>&1; fi"#,
    r#"if [ -n "$TAKO_SOCKET" ]; then takoctl status set working; fi"#,
    r#"takoctl status set working --text "Thinking..." && takoctl progress indeterminate"#,
    r#"takoctl status clear && takoctl progress clear"#,
    r#"takoctl status set done --text "Turn complete" && takoctl notify "Claude finished turn" --title "Claude Code" && takoctl progress clear"#,
    r#"takoctl status set needs_approval --text "Approval requested" && takoctl notify "Claude requested tool approval" --title "Claude Approval" && takoctl progress pause"#,
    r#"takoctl status set done --text "Done" && takoctl notify "Codex completed turn" --title "Codex" && takoctl progress clear"#,
    r#"takoctl status set needs_approval --text "Approval requested" && takoctl notify "Codex requested approval" --title "Approval Needed" && takoctl progress pause"#,
    r#"takoctl status set waiting_for_input --text "Waiting for input" && takoctl notify "Codex waiting for input" --title "Input Needed" && takoctl progress clear"#,
    r#"takoctl status set done --text "Done" && takoctl notify "Antigravity completed task" --title "Task Complete" && takoctl progress clear"#,
    r#"takoctl status set needs_approval --text "Approval requested" && takoctl notify "Antigravity requested tool approval" --title "Approval Required" && takoctl progress pause"#,
    r#"takoctl status set waiting_for_input --text "Waiting for input" && takoctl notify "Antigravity waiting for input" --title "Input Needed" && takoctl progress clear"#,
];

fn is_legacy_inline_takoctl_fallback(clause: &str) -> bool {
    let trimmed = clause.trim();
    let body = trimmed.strip_prefix(TOKEN_PREAMBLE).unwrap_or(trimmed);
    LEGACY_INLINE_TEMPLATES.contains(&body)
}

fn is_bundled_python_dispatcher(trimmed: &str, agent: &str) -> bool {
    let rest = if let Some(after_path) = trimmed.strip_prefix("PATH='") {
        let Some((macos_dir, after_colon)) =
            after_path.split_once("':\"$PATH\" /usr/bin/python3 '")
        else {
            return false;
        };
        let decoded_macos = macos_dir.replace("'\\''", "'");
        let macos_path = Path::new(&decoded_macos);
        if !macos_path.is_absolute() || macos_path.file_name().is_none_or(|n| n != "MacOS") {
            return false;
        }
        after_colon
    } else if let Some(after_py) = trimmed.strip_prefix("/usr/bin/python3 '") {
        after_py
    } else {
        return false;
    };
    let Some(without_end) = rest.strip_suffix("; :") else {
        return false;
    };
    let Some((script_quoted, args_str)) = without_end.rsplit_once("' ") else {
        return false;
    };
    let decoded_script = script_quoted.replace("'\\''", "'");
    if !decoded_script.ends_with("/Contents/Resources/tako-hook.py")
        || !Path::new(&decoded_script).is_absolute()
    {
        return false;
    }
    let parts: Vec<&str> = args_str.split_whitespace().collect();
    let same_agent =
        parts.len() == 2 && (parts[0] == agent || (agent == "antigravity" && parts[0] == "agy"));
    same_agent && DISPATCHER_EVENTS.contains(&parts[1])
}

/// Closed-set recognition of Tako-owned status hook commands across historical
/// `takoctl` and `AgentHooksTool` releases. Custom user scripts, `echo`, Prod
/// hooks (`prod-code-guard`, `prod-raw-agent-events`), and Rex hooks return `false`.
pub fn is_tako_owned_status_command(command: &str, agent: &str) -> bool {
    let trimmed = command.trim();
    let body = trimmed.strip_prefix(TOKEN_PREAMBLE).unwrap_or(trimmed);
    if is_three_word_tako_hook_call(body, agent) {
        return true;
    }
    if matches!(agent, "qwen" | "muse") && super::native::generated_command_owned(body, agent) {
        return true;
    }
    if is_bundled_python_dispatcher(body, agent) {
        return true;
    }
    if is_legacy_inline_takoctl_fallback(body) {
        return true;
    }
    if let Some(after_if) = body.strip_prefix("if command -v tako-hook >/dev/null 2>&1; then ")
        && let Some(inner) = after_if.strip_suffix("; fi; :")
    {
        if let Some((then_part, elif_part)) =
            inner.split_once("; elif [ -x \"$HOME/.local/bin/tako-hook\" ]; then ")
            && let Some(rest_args) = elif_part
                .trim()
                .strip_prefix("\"$HOME/.local/bin/tako-hook\" ")
        {
            let parts: Vec<&str> = rest_args.split_whitespace().collect();
            let same_agent = parts.len() == 2
                && (parts[0] == agent || (agent == "antigravity" && parts[0] == "agy"));
            return is_three_word_tako_hook_call(then_part.trim(), agent)
                && same_agent
                && DISPATCHER_EVENTS.contains(&parts[1]);
        }
        if let Some((then_part, else_tail)) = inner.split_once("; else ")
            && is_three_word_tako_hook_call(then_part.trim(), agent)
        {
            let raw_else = else_tail.trim();
            if is_three_word_tako_hook_call(raw_else, agent)
                || is_legacy_inline_takoctl_fallback(raw_else)
            {
                return true;
            }
            if let Some(stripped) = raw_else.strip_suffix("; :").map(str::trim)
                && (is_three_word_tako_hook_call(stripped, agent)
                    || is_legacy_inline_takoctl_fallback(stripped))
            {
                return true;
            }
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
