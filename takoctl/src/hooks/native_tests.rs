/*
 * tako — Native hook event contracts
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */
use super::managed_tests::{Fixture, value};
use super::{adapter::find_adapter, managed, native, transaction};
use serde_json::json;
use std::fs;

#[test]
fn catalogs_and_event_contracts() {
    for name in ["qwen", "muse"] {
        let a = find_adapter(name).unwrap();
        assert_eq!(a.hooks.as_object().unwrap().len(), 9);
        assert!(a.hooks.get("Interrupt").is_none());
        for (event, dispatch) in [
            ("SessionStart", "session_start"),
            ("UserPromptSubmit", "user_prompt_submit"),
            ("PermissionRequest", "permission_request"),
            ("PreToolUse", "question"),
            ("PostToolUse", "post_tool_use"),
            ("PostToolUseFailure", "post_tool_use"),
            ("Stop", "stop"),
            ("StopFailure", "stop_failure"),
            ("SessionEnd", "session_end"),
        ] {
            let hook = &a.hooks[event][0]["hooks"][0];
            let command = hook["command"].as_str().unwrap();
            assert!(command.contains(&format!("tako-hook {name} {dispatch};")));
            assert!(command.contains("--target \"$TAKO_SURFACE_ID\""));
            assert!(command.contains("$TAKO_SOCKET"));
            assert_eq!(hook["timeout"], 5);
        }
        assert_eq!(
            a.hooks["PreToolUse"][0]["matcher"],
            "^(ask_user_question|request_user_input|ask_question)$"
        );
        assert!(
            a.hooks["PostToolUseFailure"][0]["hooks"][0]["command"]
                .as_str()
                .unwrap()
                .contains("status set working")
        );
        assert!(
            !a.hooks["SessionStart"][0]["hooks"][0]["command"]
                .as_str()
                .unwrap()
                .contains("--text")
        );
    }
}

#[test]
fn qwen_preserves_user_edits_and_requires_all_active_commands() {
    let f = Fixture::new();
    let path = f.settings();
    let a = native::adapter("qwen");
    fs::write(&path, r#"{"theme":"dark","hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"echo user"}]}]}}"#).unwrap();
    let plan = managed::plan(&a, &path, false).unwrap();
    transaction::commit(&plan, None).unwrap();
    assert!(a.is_installed(&path));
    let mut root = value(&path);
    root["later"] = json!(true);
    root["hooks"]["Stop"][1]["enabled"] = json!(false);
    fs::write(&path, root.to_string()).unwrap();
    assert!(!a.is_installed(&path));
    let plan = managed::plan(&a, &path, true).unwrap();
    transaction::commit(&plan, None).unwrap();
    let root = value(&path);
    assert_eq!(root["later"], true);
    assert_eq!(root["theme"], "dark");
    assert_eq!(root["hooks"]["Stop"][0]["hooks"][0]["command"], "echo user");
}

#[test]
fn disabled_and_malformed_configs_are_rejected_without_changes() {
    let f = Fixture::new();
    for bad in [
        "not json",
        "[]",
        r#"{"disableAllHooks":true}"#,
        r#"{"disableAllHooks":"false"}"#,
        r#"{"hooks":{"Other":{}}}"#,
        r#"{"hooks":{"Stop":[{"hooks":"bad"}]}}"#,
    ] {
        fs::write(f.settings(), bad).unwrap();
        for name in ["muse", "qwen"] {
            let a = native::adapter(name);
            assert!(managed::plan(&a, &f.settings(), false).is_err(), "{bad}");
            assert!(!a.is_installed(&f.settings()));
        }
        assert_eq!(fs::read_to_string(f.settings()).unwrap(), bad);
    }
    assert_eq!(fs::read_dir(&f.0).unwrap().count(), 1);
}

#[test]
fn native_paths_and_skills_use_the_provider_roots() {
    use std::path::PathBuf;
    let fallback = PathBuf::from("/home/example/.config");
    assert_eq!(
        native::muse_root_from(Some(PathBuf::from("/custom/config")), fallback.clone()),
        PathBuf::from("/custom/config/muse")
    );
    assert_eq!(
        native::muse_root_from(Some(PathBuf::from("relative")), fallback.clone()),
        fallback.join("muse")
    );
    let qwen = find_adapter("qwen").unwrap();
    assert!(qwen.resolve_path(None).ends_with(".qwen/settings.json"));
    let muse = find_adapter("muse").unwrap();
    assert_eq!(
        muse.resolve_path(None),
        native::muse_root().join("settings.json")
    );
    assert_eq!(
        muse.resolve_path(Some("isolated/settings.json")),
        std::path::PathBuf::from("isolated/settings.json")
    );
    native::status_at("muse", "isolated/settings.json", true).unwrap();
    let skill = crate::skills::adapter::find_adapter("muse").unwrap();
    assert_eq!(
        skill.resolve_skill_path(None),
        native::muse_root().join("skills/tako/SKILL.md")
    );
    let skill = crate::skills::adapter::find_adapter("qwen").unwrap();
    assert!(
        skill
            .resolve_skill_path(None)
            .ends_with(".qwen/skills/tako/SKILL.md")
    );
}
