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

#[test]
fn test_adapters_list_and_match() {
    let adapters = all_adapters();
    assert_eq!(adapters.len(), 4);
    assert!(find_adapter("claude").is_some());
    assert!(find_adapter("claude-code").is_some());
    assert!(find_adapter("gemini").is_some());
    assert!(find_adapter("antigravity").is_some());
    assert!(find_adapter("codex").is_some());
    assert!(find_adapter("aider").is_some());
    assert!(find_adapter("nonexistent").is_none());
}

#[test]
fn test_skill_install_and_uninstall_lifecycle() {
    let temp_dir = std::env::temp_dir().join(format!("tako-skills-test-{}", std::process::id()));
    let _ = fs::create_dir_all(&temp_dir);
    let skill_file = temp_dir.join("SKILL.md");
    let skill_str = skill_file.to_string_lossy().to_string();

    // Initially not installed
    assert!(!skill_file.exists());

    // Install
    install("claude", Some(&skill_str), true, false, true).expect("install succeeds");
    assert!(skill_file.exists());
    let content = fs::read_to_string(&skill_file).expect("read installed");
    assert!(content.contains("Tako Terminal Integration"));
    assert!(fs_util::new_marker_path(&skill_file).exists());

    // Uninstall
    uninstall("claude", Some(&skill_str), true, false, true).expect("uninstall succeeds");
    assert!(!skill_file.exists());
    assert!(!fs_util::new_marker_path(&skill_file).exists());

    // Clean up
    let _ = fs::remove_dir_all(&temp_dir);
}

#[test]
fn test_skill_install_preserves_backup_on_overwrite() {
    let temp_dir = std::env::temp_dir().join(format!("tako-skills-bak-test-{}", std::process::id()));
    let _ = fs::create_dir_all(&temp_dir);
    let skill_file = temp_dir.join("SKILL.md");
    let skill_str = skill_file.to_string_lossy().to_string();

    // Write existing file
    let existing = "# Custom Existing Skill\n";
    fs::write(&skill_file, existing).expect("write existing");

    // Install overwriting
    install("gemini", Some(&skill_str), true, false, true).expect("install succeeds");
    assert!(fs_util::backup_path(&skill_file).exists());
    let installed = fs::read_to_string(&skill_file).expect("read installed");
    assert!(installed.contains("Tako Terminal Integration"));

    // Uninstall restores exact original content
    uninstall("gemini", Some(&skill_str), true, false, true).expect("uninstall succeeds");
    assert!(skill_file.exists());
    let restored = fs::read_to_string(&skill_file).expect("read restored");
    assert_eq!(restored, existing);
    assert!(!fs_util::backup_path(&skill_file).exists());

    // Clean up
    let _ = fs::remove_dir_all(&temp_dir);
}

#[test]
#[cfg(unix)]
fn test_uninstall_rejects_symlink_and_preserves_target() {
    let temp_dir = std::env::temp_dir().join(format!("tako-skills-symlink-test-{}", std::process::id()));
    let _ = fs::create_dir_all(&temp_dir);
    let target_file = temp_dir.join("critical-secret.txt");
    let initial_secret = "TOP SECRET CONFIG DO NOT OVERWRITE\n";
    fs::write(&target_file, initial_secret).expect("write target");

    let skill_symlink = temp_dir.join("SKILL.md");
    std::os::unix::fs::symlink(&target_file, &skill_symlink).expect("create symlink");

    let bak_file = fs_util::backup_path(&skill_symlink);
    fs::write(&bak_file, "Tako skill backup data\n").expect("write bak");

    let skill_str = skill_symlink.to_string_lossy().to_string();
    let res = uninstall("claude", Some(&skill_str), true, false, true);

    assert!(res.is_err(), "uninstall must return Err on symlink");
    let err_msg = res.unwrap_err();
    assert!(err_msg.contains("symlink"), "error message must mention symlink: {err_msg}");

    let content = fs::read_to_string(&target_file).expect("read target");
    assert_eq!(content, initial_secret, "target file must not be modified or truncated");

    let _ = fs::remove_dir_all(&temp_dir);
}

#[test]
#[cfg(unix)]
fn test_install_rejects_symlink_and_preserves_target() {
    let temp_dir = std::env::temp_dir().join(format!("tako-skills-inst-symlink-test-{}", std::process::id()));
    let _ = fs::create_dir_all(&temp_dir);
    let target_file = temp_dir.join("system-target.txt");
    let initial_data = "SYSTEM DATA\n";
    fs::write(&target_file, initial_data).expect("write target");

    let skill_symlink = temp_dir.join("SKILL.md");
    std::os::unix::fs::symlink(&target_file, &skill_symlink).expect("create symlink");

    let skill_str = skill_symlink.to_string_lossy().to_string();
    let res = install("gemini", Some(&skill_str), true, false, true);

    assert!(res.is_err(), "install must return Err on symlink");
    let err_msg = res.unwrap_err();
    assert!(err_msg.contains("symlink"), "error message must mention symlink: {err_msg}");

    let content = fs::read_to_string(&target_file).expect("read target");
    assert_eq!(content, initial_data, "target file must not be modified or truncated");

    let _ = fs::remove_dir_all(&temp_dir);
}
