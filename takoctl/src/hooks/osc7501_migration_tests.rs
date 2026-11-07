/*
 * tako — Native OSC 7501 hook migration tests
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use std::fs;
use std::sync::atomic::{AtomicU64, Ordering};

use serde_json::{Value, json};

use super::fs_util::{backup_path, new_marker_path};
use super::osc7501_migration::{is_tako_owned_status_command, uses_native_osc7501};
use super::{find_adapter, install, managed, native, uninstall};

static SEQ: AtomicU64 = AtomicU64::new(1);

struct TempDir(std::path::PathBuf);

impl TempDir {
    fn new(tag: &str) -> Self {
        let id = SEQ.fetch_add(1, Ordering::Relaxed);
        let dir =
            std::env::temp_dir().join(format!("takoctl-osc7501-{tag}-{}-{id}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        Self(dir.canonicalize().unwrap())
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn native_osc7501_set_covers_five_agents_and_leaves_gemini_aider_hook_based() {
    for name in ["claude", "codex", "antigravity", "qwen", "muse"] {
        assert!(uses_native_osc7501(name), "{name} must use native OSC 7501");
    }
    for name in ["gemini", "aider"] {
        assert!(!uses_native_osc7501(name), "{name} must remain hook-based");
    }
}

#[test]
fn command_ownership_rejects_echo_prod_rex_and_custom_wrappers() {
    assert!(!is_tako_owned_status_command(
        "echo tako-hook claude stop",
        "claude"
    ));
    assert!(!is_tako_owned_status_command(
        "/Users/alex/.prod/hooks/prod-raw-agent-events claude",
        "claude"
    ));
    assert!(!is_tako_owned_status_command(
        "prod-code-guard pre-tool",
        "antigravity"
    ));
    assert!(!is_tako_owned_status_command(
        "rex-hook codex stop",
        "codex"
    ));
    assert!(!is_tako_owned_status_command(
        "my-wrapper && tako-hook codex stop",
        "codex"
    ));
}

#[test]
fn claude_migration_preserves_newer_user_and_prod_hooks_despite_stale_tako_bak() {
    let dir = TempDir::new("claude");
    let cfg = dir.0.join("settings.json");
    let cfg_str = cfg.to_str().unwrap();

    // Simulate a stale .tako-bak from weeks ago BEFORE the user installed Prod hooks.
    let bak = backup_path(&cfg);
    fs::write(&bak, b"{\"theme\":\"old\"}\n").unwrap();

    let claude = find_adapter("claude").unwrap();
    let mut seeded = claude
        .apply_hooks(
            &json!({
                "theme": "dark",
                "hooks": {
                    "PreToolUse": [{
                        "matcher": "Edit|Write",
                        "hooks": [{"type": "command", "command": "/usr/local/bin/prod-code-guard"}]
                    }],
                    "Stop": [{
                        "matcher": "",
                        "hooks": [{"type": "command", "command": "/usr/local/bin/prod-raw-agent-events claude stop"}]
                    }]
                }
            })
            .to_string(),
        )
        .unwrap();
    seeded.push('\n');
    fs::write(&cfg, seeded).unwrap();
    assert!(claude.is_installed(&cfg));

    // Both `install` and `uninstall` migrate away Tako status hooks WITHOUT restoring stale .tako-bak!
    install("claude", Some(cfg_str), true, false, true).unwrap();
    assert!(!claude.is_installed(&cfg));
    assert!(!bak.exists());

    let parsed: Value = serde_json::from_str(&fs::read_to_string(&cfg).unwrap()).unwrap();
    assert_eq!(parsed["theme"], "dark");
    let stop_str = parsed["hooks"]["Stop"].to_string();
    assert!(stop_str.contains("prod-raw-agent-events"));
    assert!(!stop_str.contains("tako-hook"));
    assert!(!stop_str.contains("takoctl status"));
    assert!(
        parsed["hooks"]["PreToolUse"]
            .to_string()
            .contains("prod-code-guard")
    );
}

#[test]
fn codex_and_antigravity_migration_preserve_siblings_and_handle_missing_files() {
    let dir = TempDir::new("codex-agy");

    // Missing config is an idempotent no-op that never creates hook files.
    let missing_codex = dir.0.join("missing-hooks.json");
    install(
        "codex",
        Some(missing_codex.to_str().unwrap()),
        true,
        false,
        true,
    )
    .unwrap();
    uninstall(
        "codex",
        Some(missing_codex.to_str().unwrap()),
        true,
        false,
        true,
    )
    .unwrap();
    assert!(!missing_codex.exists());

    // Codex file created solely by Tako (.tako-new) is cleanly removed when empty.
    let codex_cfg = dir.0.join("hooks.json");
    let codex = find_adapter("codex").unwrap();
    fs::write(&codex_cfg, codex.apply_hooks("").unwrap()).unwrap();
    fs::write(new_marker_path(&codex_cfg), b"new").unwrap();
    install(
        "codex",
        Some(codex_cfg.to_str().unwrap()),
        true,
        false,
        true,
    )
    .unwrap();
    assert!(!codex_cfg.exists());

    // Antigravity hooks.json preserves prod-code-guard and prod-raw-agent-events while dropping tako-status.
    let agy_cfg = dir.0.join("agy-hooks.json");
    let agy = find_adapter("antigravity").unwrap();
    let initial = json!({
        "prod-code-guard": {"PreToolUse": [{"type": "command", "command": "prod-code-guard"}]},
        "prod-raw-agent-events": {"Stop": [{"type": "command", "command": "prod-raw-agent-events"}]}
    });
    let with_tako = agy.apply_hooks(&initial.to_string()).unwrap();
    fs::write(&agy_cfg, with_tako).unwrap();
    assert!(agy.is_installed(&agy_cfg));

    uninstall(
        "antigravity",
        Some(agy_cfg.to_str().unwrap()),
        true,
        false,
        true,
    )
    .unwrap();
    assert!(!agy.is_installed(&agy_cfg));
    let after: Value = serde_json::from_str(&fs::read_to_string(&agy_cfg).unwrap()).unwrap();
    assert!(after.get("tako-status").is_none());
    assert!(after.get("prod-code-guard").is_some());
    assert!(after.get("prod-raw-agent-events").is_some());
}

#[test]
fn qwen_and_muse_legacy_hooks_and_receipts_are_cleaned_via_public_install_and_uninstall() {
    let dir = TempDir::new("qwen-muse");

    // Seed legacy Qwen install via internal managed::run(remove = false), plus disableAllHooks & user hook.
    let qwen_cfg = dir.0.join("qwen-settings.json");
    fs::write(
        &qwen_cfg,
        r#"{"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"user-qwen-hook"}]}]}}"#,
    )
    .unwrap();
    let qwen = native::adapter("qwen");
    managed::run(&qwen, &qwen_cfg, false, true, false, true).unwrap();
    assert!(qwen.is_installed(&qwen_cfg));

    // Public `install("qwen", ...)` now migrates legacy Qwen hooks + receipt away!
    install("qwen", Some(qwen_cfg.to_str().unwrap()), true, false, true).unwrap();
    assert!(!qwen.is_installed(&qwen_cfg));
    assert!(!super::ownership::qwen_receipt_path(&qwen_cfg).exists());
    let qwen_after = fs::read_to_string(&qwen_cfg).unwrap();
    assert!(qwen_after.contains("user-qwen-hook"));
    assert!(!qwen_after.contains("tako-hook"));

    // Seed legacy Muse install via internal managed::run(remove = false) with custom env var.
    let muse_dir = dir.0.join("muse");
    fs::create_dir_all(&muse_dir).unwrap();
    let muse_cfg = muse_dir.join("settings.json");
    fs::write(&muse_cfg, r#"{"managed_hooks_env_vars":["CUSTOM_VAR"]}"#).unwrap();
    let muse = native::adapter("muse");
    managed::run(&muse, &muse_cfg, false, true, false, true).unwrap();
    assert!(muse.is_installed(&muse_cfg));

    // Public `install("muse", ...)` removes tako-managed-hooks.json, receipt, and Tako env vars while keeping CUSTOM_VAR.
    install("muse", Some(muse_cfg.to_str().unwrap()), true, false, true).unwrap();
    assert!(!muse.is_installed(&muse_cfg));
    assert!(!muse_dir.join("tako-managed-hooks.json").exists());
    let muse_after: Value = serde_json::from_str(&fs::read_to_string(&muse_cfg).unwrap()).unwrap();
    assert_eq!(muse_after["managed_hooks_env_vars"], json!(["CUSTOM_VAR"]));
    assert!(muse_after.get("managed_hooks_path").is_none());
}

#[cfg(unix)]
#[test]
fn native_cleanup_rejects_symlinks() {
    let dir = TempDir::new("symlink");
    let cfg = dir.0.join("settings.json");
    fs::write(&cfg, b"{\"ok\":true}\n").unwrap();
    let target = dir.0.join("secret.txt");
    fs::write(&target, b"secret").unwrap();
    std::os::unix::fs::symlink(&target, backup_path(&cfg)).unwrap();

    let err = install("claude", Some(cfg.to_str().unwrap()), true, false, true).unwrap_err();
    assert!(err.contains("refusing to use symlink"));
}

#[cfg(unix)]
#[test]
fn partial_legacy_qwen_and_muse_decline_prompt_preserves_backup_and_files() {
    let dir = TempDir::new("partial-decline");

    let qwen_cfg = dir.0.join("qwen-settings.json");
    let qwen_bak = backup_path(&qwen_cfg);
    let qwen_seed = r#"{
  "hooks": {
    "UserPromptSubmit": [
      {
        "matcher": "*",
        "hooks": [
          {"type": "command", "command": "PATH='/Applications/Tako.app/Contents/MacOS':\"$PATH\" /usr/bin/python3 '/Applications/Tako.app/Contents/Resources/tako-hook.py' qwen user_prompt_submit; :"}
        ]
      }
    ]
  }
}
"#;
    fs::write(&qwen_cfg, qwen_seed).unwrap();
    fs::write(&qwen_bak, b"{\"user_backup\":true}\n").unwrap();

    let muse_dir = dir.0.join("muse");
    fs::create_dir_all(&muse_dir).unwrap();
    let muse_cfg = muse_dir.join("settings.json");
    let muse_bak = backup_path(&muse_cfg);
    let muse_managed = muse_dir.join("tako-managed-hooks.json");
    let muse_seed = "{\"managed_hooks_path\":\"tako-managed-hooks.json\",\"managed_hooks_env_vars\":[\"TAKO_SURFACE_ID\",\"TAKO_SOCKET\"],\"schema_version\":1}\n";
    let muse_managed_seed = "{\"hooks\":{\"UserPromptSubmit\":[{\"matcher\":\"*\",\"hooks\":[{\"type\":\"command\",\"command\":\"PATH='/Applications/Tako.app/Contents/MacOS':\\\"$PATH\\\" /usr/bin/python3 '/Applications/Tako.app/Contents/Resources/tako-hook.py' muse user_prompt_submit; :\"}]}]}}\n";
    fs::write(&muse_cfg, muse_seed).unwrap();
    fs::write(&muse_managed, muse_managed_seed).unwrap();
    fs::write(&muse_bak, b"{\"muse_backup\":true}\n").unwrap();

    unsafe {
        let mut fds = [0i32; 2];
        assert_eq!(libc::pipe(fds.as_mut_ptr()), 0);
        let saved_stdin = libc::dup(0);
        assert!(saved_stdin >= 0);
        assert_eq!(libc::write(fds[1], b"n\nn\n".as_ptr().cast(), 4), 4);
        libc::close(fds[1]);
        assert!(libc::dup2(fds[0], 0) >= 0);
        libc::close(fds[0]);
        let r1 = install("qwen", Some(qwen_cfg.to_str().unwrap()), false, false, true);
        let r2 = uninstall("muse", Some(muse_cfg.to_str().unwrap()), false, false, true);
        libc::dup2(saved_stdin, 0);
        libc::close(saved_stdin);
        r1.unwrap();
        r2.unwrap();
    }

    assert_eq!(fs::read_to_string(&qwen_cfg).unwrap(), qwen_seed);
    assert!(
        qwen_bak.exists(),
        ".tako-bak must NOT be deleted when user answers 'n' on partial Qwen config"
    );
    assert_eq!(fs::read_to_string(&muse_cfg).unwrap(), muse_seed);
    assert_eq!(
        fs::read_to_string(&muse_managed).unwrap(),
        muse_managed_seed
    );
    assert!(
        muse_bak.exists(),
        ".tako-bak must NOT be deleted when user answers 'n' on partial Muse config"
    );
}

#[test]
fn user_modified_inline_takoctl_wrapper_is_preserved_untouched() {
    let dir = TempDir::new("closed-set");
    let claude_cfg = dir.0.join("claude-settings.json");
    let user_cmd = r#"if [ -n "$TAKO_SOCKET" ] && [ "${#TAKO_SURFACE_ID}" -eq 36 ]; then takoctl status set working --target "$TAKO_SURFACE_ID"; /usr/bin/touch /tmp/user-owned-marker; fi; :"#;
    let seed = json!({
        "hooks": {
            "UserPromptSubmit": [
                {
                    "matcher": "",
                    "hooks": [
                        {"type": "command", "command": user_cmd}
                    ]
                }
            ]
        }
    });
    fs::write(&claude_cfg, serde_json::to_string_pretty(&seed).unwrap()).unwrap();

    uninstall(
        "claude",
        Some(claude_cfg.to_str().unwrap()),
        true,
        false,
        true,
    )
    .unwrap();
    let after = fs::read_to_string(&claude_cfg).unwrap();
    assert!(
        after.contains("/usr/bin/touch /tmp/user-owned-marker"),
        "user-edited inline takoctl command must never be deleted: {after}"
    );
}
