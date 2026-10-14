/*
 * tako — Hook ownership and mixed-group preservation regressions
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::adapter::find_adapter;
use serde_json::{json, Value};

#[test]
fn mixed_group_upgrade_and_removal_preserve_user_siblings_and_metadata() {
    for agent in ["claude", "codex", "gemini"] {
        let adapter = find_adapter(agent).unwrap();
        let event = if agent == "gemini" { "BeforeAgent" } else { "UserPromptSubmit" };
        let user = json!({"type":"command", "command":"echo user", "timeout":10});
        let disabled = json!({"type":"command", "command":"echo disabled", "enabled":false});
        let mention = json!({"type":"command", "command":"echo 'tako-hook is documented here'"});
        let original = json!({"other":42,"hooks":{event:[{
            "matcher":"git.*", "label":"tako-hook user metadata", "hooks":[
                user, {"type":"command","command":format!("/home/test/.local/bin/tako-hook {agent} working")}, disabled, mention
            ]
        }]}});
        let updated = adapter.apply_hooks(&original.to_string()).unwrap();
        let value: Value = serde_json::from_str(&updated).unwrap();
        let group = &value["hooks"][event][0];
        assert_eq!(group["matcher"], "git.*");
        assert_eq!(group["label"], original["hooks"][event][0]["label"]);
        assert_eq!(group["hooks"][0], user);
        assert_eq!(group["hooks"][2], disabled);
        assert_eq!(group["hooks"][3], mention);
        assert_eq!(value["hooks"][event].as_array().unwrap().len(), 1);
        assert_eq!(adapter.apply_hooks(&updated).unwrap(), updated);
        let removed: Value = serde_json::from_str(&adapter.remove_hooks(&updated).unwrap()).unwrap();
        assert_eq!(removed["hooks"][event][0]["hooks"], json!([user, disabled, mention]));
        assert_eq!(removed["hooks"][event][0]["matcher"], "git.*");
        assert_eq!(removed["other"], 42);
    }
}

#[test]
fn metadata_mentions_and_custom_commands_are_not_ownership() {
    let adapter = find_adapter("claude").unwrap();
    let group = json!({"matcher":"*", "description":"takoctl status / tako-hook",
        "hooks":[{"type":"command","command":"echo takoctl status"}]});
    let original = json!({"hooks":{"Stop":[group]}});
    let updated = adapter.apply_hooks(&original.to_string()).unwrap();
    let removed: Value = serde_json::from_str(&adapter.remove_hooks(&updated).unwrap()).unwrap();
    assert_eq!(removed, original);
}

#[test]
fn malformed_existing_event_is_rejected_before_writing() {
    let adapter = find_adapter("codex").unwrap();
    for malformed in [json!("not an array"), json!([7]), json!([{"hooks":"invalid"}]), json!([{"hooks":[null]}])] {
        let original = json!({"hooks":{"Stop":malformed}}).to_string();
        assert!(adapter.apply_hooks(&original).is_err());
        assert!(adapter.remove_hooks(&original).is_err());
    }
}

#[test]
fn disabled_dispatcher_and_group_are_not_reenabled() {
    let adapter = find_adapter("claude").unwrap();
    for (group_enabled, hook_enabled) in [(false, true), (true, false)] {
        let original = json!({"hooks":{"Stop":[{"enabled":group_enabled,"hooks":[{
            "type":"command", "enabled":hook_enabled,"command":"tako-hook claude stop"
        }]}]}}).to_string();
        assert!(adapter.apply_hooks(&original).is_err());
    }
}

#[test]
fn direct_antigravity_hooks_preserve_unrelated_commands() {
    let adapter = find_adapter("antigravity").unwrap();
    let user = json!({"command":"echo user", "enabled":false});
    let original = json!({"tako-status":{"Stop":[user, {"command":"tako-hook agy stop"}]}});
    let updated = adapter.apply_hooks(&original.to_string()).unwrap();
    assert_eq!(adapter.apply_hooks(&updated).unwrap(), updated);
    let removed: Value = serde_json::from_str(&adapter.remove_hooks(&updated).unwrap()).unwrap();
    assert_eq!(removed["tako-status"]["Stop"], json!([user]));
}
