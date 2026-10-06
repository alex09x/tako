/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::*;
use std::fs;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;

#[test]
fn all_adapters_parse_valid_json() {
    let adapters = all_adapters();
    assert_eq!(adapters.len(), 4);
    assert!(find_adapter("claude").is_some());
    assert!(find_adapter("gemini").is_some());
    assert!(find_adapter("antigravity").is_some());
    assert!(find_adapter("agy").is_some());
    assert!(find_adapter("codex").is_some());
    assert!(find_adapter("opencode").is_some());
    assert!(find_adapter("aider").is_some());
}

#[test]
fn claude_adapter_injects_and_removes_hooks() {
    let adapter = find_adapter("claude").unwrap();
    let sample_orig = r#"{
  "theme": "dark",
  "autoUpdate": true
}
"#;
    let modified = adapter.apply_hooks(sample_orig).unwrap();
    assert!(modified.contains("takoctl status set working"));
    assert!(modified.contains("takoctl status set needs_approval"));
    assert!(modified.contains("takoctl status set done"));
    assert!(modified.contains("takoctl status clear"));
    assert!(modified.contains("\"theme\": \"dark\""));

    let diff = unified_diff(sample_orig, &modified, "settings.json");
    assert!(diff.contains("+    \"UserPromptSubmit\":"));
    assert!(diff.contains("+    \"PreToolUse\":"));

    // Fallback removal
    let restored = adapter.remove_hooks(&modified).unwrap();
    assert!(!restored.contains("takoctl"));
    assert!(restored.contains("\"theme\": \"dark\""));
}

#[test]
fn gemini_adapter_injects_and_removes_hooks() {
    let adapter = find_adapter("gemini").unwrap();
    let sample_orig = r#"{
  "model": "gemini-2.5-pro"
}
"#;
    let modified = adapter.apply_hooks(sample_orig).unwrap();
    assert!(modified.contains("on_prompt"));
    assert!(modified.contains("on_approval"));
    assert!(modified.contains("on_wait_input"));
    assert!(modified.contains("on_done"));
    assert!(modified.contains("on_session_end"));
    assert!(modified.contains("model"));

    let restored = adapter.remove_hooks(&modified).unwrap();
    assert!(!restored.contains("takoctl"));
    assert!(restored.contains("model"));
}

#[test]
fn codex_adapter_injects_and_removes_hooks() {
    let adapter = find_adapter("codex").unwrap();
    let empty = "";
    let modified = adapter.apply_hooks(empty).unwrap();
    assert!(modified.contains("prompt_submit"));
    assert!(modified.contains("approval_requested"));
    assert!(modified.contains("turn_done"));

    let restored = adapter.remove_hooks(&modified).unwrap();
    assert_eq!(restored.trim(), "");
}

#[test]
fn aider_adapter_injects_and_removes_hooks() {
    let adapter = find_adapter("aider").unwrap();
    let sample_orig = "auto-commits: true\nmodel: gpt-4o\n";
    let modified = adapter.apply_hooks(sample_orig).unwrap();
    assert!(modified.contains("notifications-command:"));
    assert!(modified.contains("takoctl status set done"));

    let restored = adapter.remove_hooks(&modified).unwrap();
    assert!(!restored.contains("takoctl"));
    assert_eq!(restored, sample_orig);
}

#[test]
fn install_and_uninstall_roundtrip_is_byte_identical_on_existing_file() {
    let temp_dir = std::env::temp_dir().join(format!("takoctl-test-{}", std::process::id()));
    let _ = fs::create_dir_all(&temp_dir);
    let config_file = temp_dir.join("existing-claude-settings.json");

    let original_bytes = b"{\n  \"customKey\": \"value123\",\n  \"fontSize\": 14\n}\n";
    fs::write(&config_file, original_bytes).unwrap();

    let path_str = config_file.to_str().unwrap();

    // 1. Install
    install("claude", Some(path_str), true, false, false).unwrap();
    assert!(config_file.exists());
    let installed_content = fs::read_to_string(&config_file).unwrap();
    assert!(installed_content.contains("takoctl"));
    assert!(installed_content.contains("customKey"));

    // 2. Uninstall
    uninstall("claude", Some(path_str), true, false, false).unwrap();
    assert!(config_file.exists());
    let restored_bytes = fs::read(&config_file).unwrap();

    // Must be EXACTLY byte-identical!
    assert_eq!(restored_bytes, original_bytes);

    let _ = fs::remove_dir_all(&temp_dir);
}

#[test]
fn install_and_uninstall_roundtrip_is_byte_identical_on_new_file() {
    let temp_dir = std::env::temp_dir().join(format!("takoctl-test-new-{}", std::process::id()));
    let _ = fs::create_dir_all(&temp_dir);
    let config_file = temp_dir.join("brand-new-codex.json");
    let path_str = config_file.to_str().unwrap();

    assert!(!config_file.exists());

    // 1. Install into non-existent file
    install("codex", Some(path_str), true, false, false).unwrap();
    assert!(config_file.exists());
    let installed = fs::read_to_string(&config_file).unwrap();
    assert!(installed.contains("takoctl"));

    // 2. Uninstall
    uninstall("codex", Some(path_str), true, false, false).unwrap();

    // File must no longer exist (byte-identical to before install!)
    assert!(!config_file.exists());

    let _ = fs::remove_dir_all(&temp_dir);
}

#[test]
fn diff_only_does_not_modify_file_or_create_backup() {
    let temp_dir = std::env::temp_dir().join(format!("takoctl-test-diff-{}", std::process::id()));
    let _ = fs::create_dir_all(&temp_dir);
    let config_file = temp_dir.join("diff-test.json");
    let path_str = config_file.to_str().unwrap();

    let initial_bytes = b"{\n  \"model\": \"test\"\n}\n";
    fs::write(&config_file, initial_bytes).unwrap();

    // Run install with diff_only = true
    install("gemini", Some(path_str), true, true, false).unwrap();

    // Content must be completely unchanged
    let current_bytes = fs::read(&config_file).unwrap();
    assert_eq!(current_bytes, initial_bytes);

    // No backup file should have been written
    let bak = backup_path(&config_file);
    assert!(!bak.exists());

    let _ = fs::remove_dir_all(&temp_dir);
}

#[test]
fn install_reports_already_installed_when_run_twice() {
    let temp_dir = std::env::temp_dir().join(format!("takoctl-test-double-{}", std::process::id()));
    let _ = fs::create_dir_all(&temp_dir);
    let config_file = temp_dir.join("double-install.json");
    let path_str = config_file.to_str().unwrap();

    // 1. First install
    install("codex", Some(path_str), true, false, false).unwrap();
    assert!(config_file.exists());

    // 2. Second install should detect already installed and succeed without error
    install("codex", Some(path_str), true, false, false).unwrap();

    // 3. Uninstall cleans it up completely
    uninstall("codex", Some(path_str), true, false, false).unwrap();
    assert!(!config_file.exists());

    let _ = fs::remove_dir_all(&temp_dir);
}

#[test]
fn uninstall_on_file_without_hooks_succeeds_cleanly() {
    let temp_dir = std::env::temp_dir().join(format!("takoctl-test-nohooks-{}", std::process::id()));
    let _ = fs::create_dir_all(&temp_dir);
    let config_file = temp_dir.join("no-hooks.json");
    let path_str = config_file.to_str().unwrap();

    fs::write(&config_file, b"{\n  \"key\": \"value\"\n}\n").unwrap();

    uninstall("claude", Some(path_str), true, false, false).unwrap();

    // File remains as is
    assert!(config_file.exists());

    let _ = fs::remove_dir_all(&temp_dir);
}

#[test]
fn invalid_json_returns_error_without_panicking() {
    let temp_dir = std::env::temp_dir().join(format!("takoctl-test-invalid-{}", std::process::id()));
    let _ = fs::create_dir_all(&temp_dir);
    let config_file = temp_dir.join("corrupted.json");
    let path_str = config_file.to_str().unwrap();

    fs::write(&config_file, b"this is not valid json!").unwrap();

    assert!(install("claude", Some(path_str), true, false, false).is_err());

    let _ = fs::remove_dir_all(&temp_dir);
}

#[test]
fn status_and_list_execute_cleanly() {
    assert!(list(false).is_ok());
    assert!(list(true).is_ok());
    assert!(status(None, false).is_ok());
    assert!(status(None, true).is_ok());
    assert!(status(Some("claude"), false).is_ok());
    assert!(status(Some("claude"), true).is_ok());
    assert!(status(Some("invalid_agent_xyz"), false).is_err());
}

#[cfg(unix)]
#[test]
fn test_backup_created_with_restrictive_permissions() {
    let temp_dir = std::env::temp_dir().join(format!("takoctl-test-perms-{}", std::process::id()));
    let _ = fs::create_dir_all(&temp_dir);
    let config_file = temp_dir.join("secret-config.json");
    let path_str = config_file.to_str().unwrap();

    let secret_bytes = b"{\n  \"api_key\": \"sk-secret-12345\"\n}\n";
    fs::write(&config_file, secret_bytes).unwrap();
    fs::set_permissions(&config_file, fs::Permissions::from_mode(0o644)).unwrap();

    // Install hooks
    install("claude", Some(path_str), true, false, false).unwrap();

    let bak = backup_path(&config_file);
    assert!(bak.exists());
    let bak_meta = fs::metadata(&bak).unwrap();
    let mode = bak_meta.permissions().mode() & 0o777;
    // Mode must be restrictive: no group or other read/write/execute (0600)
    assert_eq!(mode & 0o077, 0, "backup must not be readable/writable by group or others");
    assert_eq!(mode, 0o600);

    // Uninstall
    uninstall("claude", Some(path_str), true, false, false).unwrap();
    assert_eq!(fs::read(&config_file).unwrap(), secret_bytes);

    let _ = fs::remove_dir_all(&temp_dir);
}

#[cfg(unix)]
#[test]
fn test_pre_existing_overpermissive_backup_is_hardened_on_install() {
    let temp_dir = std::env::temp_dir().join(format!("takoctl-test-preexist-{}", std::process::id()));
    let _ = fs::create_dir_all(&temp_dir);
    let config_file = temp_dir.join("legacy-config.json");
    let path_str = config_file.to_str().unwrap();

    let orig_bytes = b"{\n  \"theme\": \"light\"\n}\n";
    fs::write(&config_file, orig_bytes).unwrap();

    // Simulate a pre-existing backup created by an older version with 0644 mode
    let bak = backup_path(&config_file);
    fs::write(&bak, orig_bytes).unwrap();
    fs::set_permissions(&bak, fs::Permissions::from_mode(0o644)).unwrap();
    assert_ne!(fs::metadata(&bak).unwrap().permissions().mode() & 0o077, 0);

    // Install hooks
    install("claude", Some(path_str), true, false, false).unwrap();

    // Verify the pre-existing backup was tightened to owner-only (0600)
    let mode = fs::metadata(&bak).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode & 0o077, 0, "existing backup must be hardened to no group/other access");
    assert_eq!(mode, 0o600);

    // Now test when hooks are ALREADY installed:
    // Set bak back to 0644 to test early-return hardening
    fs::set_permissions(&bak, fs::Permissions::from_mode(0o644)).unwrap();
    assert_ne!(fs::metadata(&bak).unwrap().permissions().mode() & 0o077, 0);

    // Running install again (which detects already_installed) must also harden existing backup
    install("claude", Some(path_str), true, false, false).unwrap();
    let mode_again = fs::metadata(&bak).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode_again & 0o077, 0, "backup must be hardened even when already installed");
    assert_eq!(mode_again, 0o600);

    let _ = fs::remove_dir_all(&temp_dir);
}

#[cfg(unix)]
#[test]
fn test_symlink_backup_is_rejected_and_fails_closed() {
    let temp_dir = std::env::temp_dir().join(format!("takoctl-test-symlink-{}", std::process::id()));
    let _ = fs::create_dir_all(&temp_dir);
    let config_file = temp_dir.join("config.json");
    let path_str = config_file.to_str().unwrap();
    fs::write(&config_file, b"{\n  \"safe\": true\n}\n").unwrap();

    let sensitive_target = temp_dir.join("sensitive.txt");
    fs::write(&sensitive_target, b"sensitive data").unwrap();

    // Create a symlink at .tako-bak pointing to sensitive target
    let bak = backup_path(&config_file);
    std::os::unix::fs::symlink(&sensitive_target, &bak).unwrap();

    // Install must fail closed and reject the symlink
    let res = install("claude", Some(path_str), true, false, false);
    assert!(res.is_err());
    assert!(res.unwrap_err().contains("refusing to use symlink"));

    // Uninstall must also fail closed and reject the symlink
    let uninst_res = uninstall("claude", Some(path_str), true, false, false);
    assert!(uninst_res.is_err());
    assert!(uninst_res.unwrap_err().contains("refusing to restore from symlink"));

    let _ = fs::remove_dir_all(&temp_dir);
}
