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

fn relocated_adapter(provider: &str, bundle: Option<&str>) -> super::adapter::Adapter {
    let mut adapter = native::adapter(provider);
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
        adapter.hooks[event][0]["hooks"][0]["command"] = json!(
            native::dispatcher_command_at(provider, dispatch, bundle.map(std::path::Path::new))
        );
    }
    adapter
}

#[test]
fn relocation_deduplicates_owned_hooks_and_keeps_mixed_siblings() {
    for provider in ["qwen", "muse"] {
        let f = Fixture::new();
        let path = f.settings();
        let hooks_path = if provider == "muse" {
            path.with_file_name("tako-managed-hooks.json")
        } else {
            path.clone()
        };
        let old = relocated_adapter(provider, Some("/absent/Tako.app/Contents/Resources/tako-hook.py"));
        transaction::commit(&managed::plan(&old, &path, false).unwrap(), None).unwrap();
        let mut root = value(&hooks_path);
        let owned = root["hooks"]["Stop"][0]["hooks"][0].clone();
        let unknown = json!({"type":"command", "command":format!("{} echo custom", owned["command"].as_str().unwrap())});
        root["hooks"]["Stop"][0]["note"] = json!("keep mixed metadata");
        root["hooks"]["Stop"][0]["hooks"] = json!([owned, unknown, owned]);
        fs::write(&hooks_path, root.to_string()).unwrap();
        let new = relocated_adapter(provider, None);
        transaction::commit(&managed::plan(&new, &path, false).unwrap(), None).unwrap();
        let root = value(&hooks_path);
        assert_eq!(root["hooks"]["Stop"][0]["note"], "keep mixed metadata");
        assert_eq!(root["hooks"]["Stop"][0]["hooks"].as_array().unwrap().len(), 2);
        assert_eq!(root["hooks"]["Stop"][0]["hooks"][1], unknown);
        transaction::commit(&managed::plan(&old, &path, true).unwrap(), None).unwrap();
        let root = value(&hooks_path);
        assert_eq!(root["hooks"]["Stop"][0]["hooks"], json!([unknown]));
        assert_eq!(root["hooks"]["Stop"][0]["note"], "keep mixed metadata");
    }
}

#[test]
fn relocation_failure_restores_receipts_configs_and_backups() {
    for provider in ["qwen", "muse"] {
        let f = Fixture::new();
        let path = f.settings();
        let old = relocated_adapter(provider, Some("/absent/Old.app/Contents/Resources/tako-hook.py"));
        transaction::commit(&managed::plan(&old, &path, false).unwrap(), None).unwrap();
        let new = relocated_adapter(provider, None);
        let plan = managed::plan(&new, &path, false).unwrap();
        for failure in 0..plan.iter().filter(|change| change.changed()).count() {
            assert!(transaction::commit(&plan, Some(failure)).is_err());
            for change in &plan {
                assert_eq!(transaction::read(&change.path).unwrap(), change.before);
            }
        }
    }
}

#[test]
fn legacy_generated_templates_are_owned_without_a_receipt_or_old_app() {
    for provider in ["qwen", "muse"] {
        let old = relocated_adapter(provider, Some("/absent/Old 'Tako.app/Contents/Resources/tako-hook.py"));
        let new = relocated_adapter(provider, None);
        let generated = old.apply_hooks("{}").unwrap();
        let upgraded = new.apply_hooks(&generated).unwrap();
        let root: serde_json::Value = serde_json::from_str(&upgraded).unwrap();
        for (event, template) in new.hooks.as_object().unwrap() {
            assert_eq!(&root["hooks"][event], template);
        }
        assert_eq!(new.remove_hooks(&generated).unwrap(), "");
        for command in [
            "echo tako-hook muse stop",
            "PATH='/user/MacOS':\"$PATH\" /usr/bin/python3 '/user/custom.py' muse stop; :",
            "if command -v tako-hook; then echo custom; fi",
        ] {
            assert!(!native::generated_command_owned(command, provider));
        }
    }
}

#[test]
fn native_receipts_follow_bundle_moves_and_standalone_switches() {
    for provider in ["qwen", "muse"] {
        let f = Fixture::new();
        let path = f.settings();
        let hooks_path = if provider == "muse" {
            path.with_file_name("custom-hooks.json")
        } else {
            path.clone()
        };
        let initial = json!({"theme":"dark", "hooks":{"Stop":[{
            "matcher":"", "note":"keep group metadata", "hooks":[
                {"type":"command", "command":"echo user mentions tako-hook"}
            ]
        }]}});
        fs::write(&hooks_path, initial.to_string()).unwrap();
        if provider == "muse" {
            fs::write(&path, json!({
                "schema_version":1, "managed_hooks_path":"custom-hooks.json",
                "managed_hooks_env_vars":["USER_KEEP"], "theme":"dark"
            }).to_string()).unwrap();
        }
        let locations = [
            Some("/missing/First Tako.app/Contents/Resources/tako-hook.py"),
            Some("/missing/Second 'Tako.app/Contents/Resources/tako-hook.py"),
            None,
            Some("/missing/First Tako.app/Contents/Resources/tako-hook.py"),
        ];
        for location in locations {
            let adapter = relocated_adapter(provider, location);
            transaction::commit(&managed::plan(&adapter, &path, false).unwrap(), None).unwrap();
            let once = fs::read_to_string(&hooks_path).unwrap();
            transaction::commit(&managed::plan(&adapter, &path, false).unwrap(), None).unwrap();
            assert_eq!(fs::read_to_string(&hooks_path).unwrap(), once);
            let root = value(&hooks_path);
            for (event, template) in adapter.hooks.as_object().unwrap() {
                let expected = &template[0]["hooks"][0]["command"];
                let count = root["hooks"][event].as_array().unwrap().iter()
                    .flat_map(|group| group["hooks"].as_array().unwrap())
                    .filter(|hook| &hook["command"] == expected).count();
                assert_eq!(count, 1, "{provider} {event}");
                assert_eq!(root["hooks"][event].as_array().unwrap().len(), if event == "Stop" { 2 } else { 1 });
            }
            assert_eq!(root["hooks"]["Stop"][0]["note"], "keep group metadata");
        }
        // The last installed app is absent; uninstall from a different CLI form.
        let adapter = relocated_adapter(provider, None);
        transaction::commit(&managed::plan(&adapter, &path, true).unwrap(), None).unwrap();
        assert_eq!(value(&hooks_path), initial);
        if provider == "muse" {
            let settings = value(&path);
            assert_eq!(settings["managed_hooks_path"], "custom-hooks.json");
            assert_eq!(settings["managed_hooks_env_vars"], json!(["USER_KEEP"]));
        }
    }
}

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
            assert!(
                !command.contains("takoctl"),
                "recipient/subagent checks must not be bypassed"
            );
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
                .contains(" post_tool_use;")
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
