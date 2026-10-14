/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use std::fs;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use super::args;
use super::super::*;
use crate::hooks::find_adapter;

static ENV_LOCK: Mutex<()> = Mutex::new(());

#[test]
fn grant_scope_is_new_credential_scope_without_weakening_other_attenuation() {
    for action in ["create", "request"] {
        let opts = parse(&args(&["grant", action, "--client", "hook", "--scope", "signal"])).unwrap();
        let value = request(&opts, None);
        assert!(value.get("scopes").is_none());
        assert_eq!(value["args"]["scopes"], serde_json::json!(["signal"]));
    }
    let opts = parse(&args(&["grant", "list", "--scope", "read"])).unwrap();
    let value = request(&opts, None);
    assert_eq!(value["scopes"], serde_json::json!(["read"]));
}

#[test]
fn restricted_env_token_preferred_for_inherited_target() {
    let _guard = ENV_LOCK.lock().unwrap();

    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let dir = std::env::temp_dir().join(format!("tako_token_test_{nanos}"));
    fs::create_dir_all(&dir).unwrap();

    let socket_path = dir.join("tako.sock");
    let socket_str = socket_path.to_str().unwrap();
    let token_file = dir.join("tako.sock.token");
    fs::write(&token_file, "primary-file-token\n").unwrap();

    // 1. Inherited session with restricted env token
    unsafe {
        std::env::set_var("TAKO_CONTROL_TOKEN", "restricted-env-grant");
        std::env::remove_var("TAKO_AUTH_TOKEN");
    }
    let opts = parse(&args(&["status"])).unwrap();
    assert!(opts.socket.is_none());
    assert!(!opts.bundle_id_explicit);
    let token = resolve_token(&opts, socket_str);
    assert_eq!(
        token,
        Some("restricted-env-grant".to_string()),
        "Inherited target must prefer caller-provided environment grant over file token"
    );

    // 2. Explicit socket target prefers target's file token
    let opts = parse(&args(&["status", "--socket", socket_str])).unwrap();
    assert!(opts.socket.is_some());
    let token = resolve_token(&opts, socket_str);
    assert_eq!(
        token,
        Some("primary-file-token".to_string()),
        "Explicit socket target must prefer the file token of that specific socket"
    );

    // 3. Explicit CLI token always wins
    let opts = parse(&args(&["status", "--token", "explicit-cli-token"])).unwrap();
    let token = resolve_token(&opts, socket_str);
    assert_eq!(token, Some("explicit-cli-token".to_string()));

    // 4. Inherited session without env token falls back to file token
    unsafe {
        std::env::remove_var("TAKO_CONTROL_TOKEN");
        std::env::remove_var("TAKO_AUTH_TOKEN");
    }
    let opts = parse(&args(&["status"])).unwrap();
    let token = resolve_token(&opts, socket_str);
    assert_eq!(token, Some("primary-file-token".to_string()));

    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn claude_adapter_emits_valid_nested_matcher_groups_and_no_ops_safely() {
    let adapter = find_adapter("claude").expect("claude adapter exists");
    let orig = r#"{"autoUpdate": true}"#;
    let modified = adapter.apply_hooks(orig).expect("apply hooks succeeds");

    let val: serde_json::Value = serde_json::from_str(&modified).expect("valid JSON output");
    let hooks = val
        .get("hooks")
        .expect("hooks field present")
        .as_object()
        .expect("hooks is object");

    // All events must be arrays of matcher groups with nested "hooks"
    for event in &["UserPromptSubmit", "PermissionRequest", "Elicitation", "Stop"] {
        let groups = hooks
            .get(*event)
            .unwrap_or_else(|| panic!("missing event {event}"))
            .as_array()
            .expect("event is array");
        assert!(!groups.is_empty(), "event {event} has non-empty groups");

        for group in groups {
            let grp_obj = group.as_object().expect("group is object");
            assert!(grp_obj.contains_key("matcher"), "group must have matcher key");
            let inner_hooks = grp_obj
                .get("hooks")
                .expect("group must have nested hooks key")
                .as_array()
                .expect("nested hooks is array");
            assert!(!inner_hooks.is_empty(), "nested hooks must not be empty");

            for hook in inner_hooks {
                let hook_obj = hook.as_object().expect("hook is object");
                assert_eq!(
                    hook_obj.get("type").and_then(|v| v.as_str()),
                    Some("command")
                );
                let cmd = hook_obj
                    .get("command")
                    .and_then(|v| v.as_str())
                    .expect("command string");
                assert!(!cmd.contains("eval"), "command must never contain eval");
                assert!(
                    cmd.contains("if [ -n \"$TAKO_SOCKET\" ]"),
                    "command must safely no-op outside Tako"
                );
            }
        }
    }

    // Fallback remove cleanly strips takoctl hooks
    let restored = adapter.remove_hooks(&modified).expect("remove succeeds");
    assert!(!restored.contains("takoctl"));
    assert!(restored.contains("\"autoUpdate\": true"));
}

#[test]
fn two_instance_inherited_socket_failure_never_falls_back_to_default_instance() {
    use std::os::unix::net::UnixListener;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;
    use std::thread;
    use std::time::Duration;

    let _guard = ENV_LOCK.lock().unwrap();

    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let pid = std::process::id();
    let test_bundle_id = format!("codes.prod.tako.test.isolation.{pid}_{nanos}");

    // Mock default instance listener bound to the EXACT default_path for this bundle ID
    let default_sock_str = socket::default_path(&test_bundle_id).expect("resolve default path");
    let default_sock_path = std::path::PathBuf::from(&default_sock_str);
    let _ = fs::remove_file(&default_sock_path);
    let listener = UnixListener::bind(&default_sock_path).expect("bind mock default instance");
    let default_contacted = Arc::new(AtomicBool::new(false));
    let contacted_clone = default_contacted.clone();
    let server_running = Arc::new(AtomicBool::new(true));
    let running_clone = server_running.clone();
    let deadline_exhausted = Arc::new(AtomicBool::new(false));
    let deadline_clone = deadline_exhausted.clone();

    let start = std::time::Instant::now();
    let server_thread = thread::spawn(move || {
        listener.set_nonblocking(true).unwrap();
        while running_clone.load(Ordering::SeqCst) {
            if start.elapsed() >= Duration::from_secs(10) {
                deadline_clone.store(true, Ordering::SeqCst);
                break;
            }
            if let Ok((_stream, _)) = listener.accept() {
                contacted_clone.store(true, Ordering::SeqCst);
            }
            thread::sleep(Duration::from_millis(5));
        }
        // Drain any pending accepts before shutting down
        while let Ok((_stream, _)) = listener.accept() {
            contacted_clone.store(true, Ordering::SeqCst);
        }
    });

    // Inherited secondary instance socket that does NOT exist (dead/stopped secondary instance)
    let dead_inherited_socket = std::path::PathBuf::from(format!("/tmp/tk_dead_{pid}_{nanos}.sock"));
    let _ = fs::remove_file(&dead_inherited_socket);
    let dead_socket_str = dead_inherited_socket.to_str().unwrap();

    // Mandatory current-source run_cli orchestration under ENV_LOCK
    let old_sock = std::env::var("TAKO_SOCKET").ok();
    let old_bundle = std::env::var("TAKO_BUNDLE_ID").ok();
    unsafe {
        std::env::set_var("TAKO_SOCKET", dead_socket_str);
        std::env::set_var("TAKO_BUNDLE_ID", &test_bundle_id);
    }
    let exit_code = run_cli(&args(&["workspace", "switch", "Isolated"]));
    unsafe {
        match old_sock {
            Some(s) => std::env::set_var("TAKO_SOCKET", s),
            None => std::env::remove_var("TAKO_SOCKET"),
        }
        match old_bundle {
            Some(b) => std::env::set_var("TAKO_BUNDLE_ID", b),
            None => std::env::remove_var("TAKO_BUNDLE_ID"),
        }
    }
    assert_eq!(
        exit_code,
        ExitCode::from(3),
        "CLI entrypoint must return ExitCode(3) on unreachable inherited socket"
    );

    // Synchronize: keep listener alive across invocation, then drain and shut down
    thread::sleep(Duration::from_millis(50));
    server_running.store(false, Ordering::SeqCst);
    server_thread.join().unwrap();

    // Fail the fixture if the listener deadline was exhausted before completion
    assert!(
        !deadline_exhausted.load(Ordering::SeqCst),
        "Mock listener deadline exhausted before CLI execution completed"
    );

    // The default instance must NEVER have been contacted
    assert!(
        !default_contacted.load(Ordering::SeqCst),
        "Connection failure on inherited instance must never silently fall back or replay to the default instance"
    );

    let _ = fs::remove_file(&default_sock_path);
}
