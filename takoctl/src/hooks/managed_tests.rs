/*
 * tako — Native hook planner tests
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */
use super::{managed, native, transaction};
use serde_json::{Value, json};
use std::{
    fs,
    path::{Path, PathBuf},
    sync::atomic::{AtomicU64, Ordering},
};
static NEXT: AtomicU64 = AtomicU64::new(0);
pub(super) struct Fixture(pub(super) PathBuf);
impl Fixture {
    pub(super) fn new() -> Self {
        let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "tako-native-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&root).unwrap();
        Self(root)
    }
    pub(super) fn settings(&self) -> PathBuf {
        self.0.join("settings.json")
    }
    fn managed(&self) -> PathBuf {
        self.0.join("tako-managed-hooks.json")
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
pub(super) fn value(path: &Path) -> Value {
    serde_json::from_str(&fs::read_to_string(path).unwrap()).unwrap()
}
fn install(path: &Path) {
    let plan = managed::plan(&native::adapter("muse"), path, false).unwrap();
    transaction::commit(&plan, None).unwrap();
}
fn uninstall(path: &Path) {
    let plan = managed::plan(&native::adapter("muse"), path, true).unwrap();
    transaction::commit(&plan, None).unwrap();
}

#[test]
fn muse_relative_foreign_pointer_permissions_and_grants_survive() {
    let f = Fixture::new();
    fs::create_dir(f.0.join("shared")).unwrap();
    let hooks = f.0.join("shared/hooks.json");
    fs::write(
        &hooks,
        r#"{"custom":17,"hooks":{"Other":[{"hooks":[{"type":"command","command":"echo user"}]}]}}"#,
    )
    .unwrap();
    fs::write(f.settings(), r#"{"schema_version":1,"managed_hooks_path":"shared/hooks.json","managed_hooks_env_vars":["EXISTING","TAKO_SOCKET"],"permissions":{"shell":false}}"#).unwrap();
    install(&f.settings());
    assert!(native::adapter("muse").is_installed(&f.settings()));
    assert_eq!(
        value(&f.settings())["managed_hooks_path"],
        "shared/hooks.json"
    );
    let mut settings = value(&f.settings());
    settings["later"] = json!("keep");
    settings["managed_hooks_env_vars"]
        .as_array_mut()
        .unwrap()
        .push(json!("LATER"));
    fs::write(f.settings(), settings.to_string()).unwrap();
    uninstall(&f.settings());
    let settings = value(&f.settings());
    assert_eq!(
        settings["managed_hooks_env_vars"],
        json!(["EXISTING", "TAKO_SOCKET", "LATER"])
    );
    assert_eq!(settings["managed_hooks_path"], "shared/hooks.json");
    assert_eq!(settings["permissions"]["shell"], false);
    assert_eq!(settings["later"], "keep");
    assert_eq!(value(&hooks)["custom"], 17);
    assert_eq!(value(&hooks)["hooks"].as_object().unwrap().len(), 1);
}

#[test]
fn muse_owned_fields_removed_and_install_is_idempotent() {
    let f = Fixture::new();
    fs::write(f.settings(), "{\"user\":true}\n").unwrap();
    install(&f.settings());
    let a = native::adapter("muse");
    assert!(a.is_installed(&f.settings()));
    assert!(
        managed::plan(&a, &f.settings(), false)
            .unwrap()
            .iter()
            .all(|c| !c.changed())
    );
    uninstall(&f.settings());
    assert_eq!(value(&f.settings()), json!({"user":true}));
    assert!(!a.is_installed(&f.settings()));
    assert_eq!(value(&f.managed()), json!({}));
    assert!(!f.0.join("settings.json.tako-muse-receipt").exists());
    assert!(
        managed::plan(&a, &f.settings(), true)
            .unwrap()
            .iter()
            .all(|c| !c.changed())
    );
}

#[test]
fn muse_status_requires_allowlist_and_each_exact_command() {
    let f = Fixture::new();
    install(&f.settings());
    let a = native::adapter("muse");
    let settings = value(&f.settings());
    for name in ["TAKO_SOCKET", "TAKO_SURFACE_ID"] {
        let mut s = settings.clone();
        s["managed_hooks_env_vars"]
            .as_array_mut()
            .unwrap()
            .retain(|v| v != name);
        fs::write(f.settings(), s.to_string()).unwrap();
        assert!(!a.is_installed(&f.settings()));
    }
    fs::write(f.settings(), settings.to_string()).unwrap();
    let hooks = value(&f.managed());
    for event in a.hooks.as_object().unwrap().keys() {
        let mut altered = hooks.clone();
        altered["hooks"][event][0]["hooks"][0]["command"] = json!("echo tako-hook muse stop");
        fs::write(f.managed(), altered.to_string()).unwrap();
        assert!(!a.is_installed(&f.settings()), "{event}");
    }
}

#[test]
fn muse_diff_has_no_mutations_and_override_is_isolated() {
    let f = Fixture::new();
    let path = f.0.join("isolated/settings.json");
    let a = native::adapter("muse");
    managed::run(&a, &path, false, true, true, true).unwrap();
    assert_eq!(fs::read_dir(&f.0).unwrap().count(), 0);
    let plan = managed::plan(&a, &path, false).unwrap();
    assert!(
        plan.iter()
            .all(|c| c.path.starts_with(f.0.join("isolated")))
    );
    transaction::commit(&plan, None).unwrap();
    assert!(a.is_installed(&path));
}

#[test]
fn muse_invalid_settings_or_managed_file_fail_before_writes() {
    let f = Fixture::new();
    for bad in [
        r#"{"schema_version":2}"#,
        r#"{"managed_hooks_path":[]}"#,
        r#"{"managed_hooks_env_vars":"TAKO_SOCKET"}"#,
        r#"{"managed_hooks_env_vars":[5]}"#,
        r#"{"managed_hooks_path":"settings.json"}"#,
    ] {
        fs::write(f.settings(), bad).unwrap();
        assert!(managed::plan(&native::adapter("muse"), &f.settings(), false).is_err());
        assert_eq!(fs::read_dir(&f.0).unwrap().count(), 1);
    }
    fs::write(f.settings(), "{}").unwrap();
    for bad in ["bad", r#"{"hooks":[]}"#, r#"{"disableAllHooks":true}"#] {
        fs::write(f.managed(), bad).unwrap();
        assert!(managed::plan(&native::adapter("muse"), &f.settings(), false).is_err());
        assert_eq!(fs::read_to_string(f.settings()).unwrap(), "{}");
        assert_eq!(fs::read_to_string(f.managed()).unwrap(), bad);
    }
}

#[test]
fn partial_write_failure_rolls_back_settings_hooks_backups_and_receipt() {
    for failure in 0..5 {
        let f = Fixture::new();
        fs::write(f.settings(), "{\"original\":true}\n").unwrap();
        fs::write(f.managed(), "{\"original\":17}\n").unwrap();
        let plan = managed::plan(&native::adapter("muse"), &f.settings(), false).unwrap();
        assert!(transaction::commit(&plan, Some(failure)).is_err());
        assert_eq!(
            fs::read_to_string(f.settings()).unwrap(),
            "{\"original\":true}\n"
        );
        assert_eq!(
            fs::read_to_string(f.managed()).unwrap(),
            "{\"original\":17}\n"
        );
        assert_eq!(fs::read_dir(&f.0).unwrap().count(), 2);
    }
}

#[cfg(unix)]
#[test]
fn symlink_targets_parents_and_receipts_are_rejected_and_backups_are_secure() {
    use std::os::unix::fs::{PermissionsExt, symlink};
    let f = Fixture::new();
    let foreign = f.0.join("foreign");
    fs::write(&foreign, "{}").unwrap();
    symlink(&foreign, f.settings()).unwrap();
    assert!(managed::plan(&native::adapter("muse"), &f.settings(), false).is_err());
    fs::remove_file(f.settings()).unwrap();
    fs::write(f.settings(), "{}").unwrap();
    let receipt = f.0.join("settings.json.tako-muse-receipt");
    symlink(&foreign, &receipt).unwrap();
    assert!(managed::plan(&native::adapter("muse"), &f.settings(), false).is_err());
    fs::remove_file(&receipt).unwrap();
    symlink(&foreign, f.managed()).unwrap();
    assert!(managed::plan(&native::adapter("muse"), &f.settings(), false).is_err());
    fs::remove_file(f.managed()).unwrap();
    symlink(&f.0, f.0.join("link")).unwrap();
    assert!(
        managed::plan(
            &native::adapter("muse"),
            &f.0.join("link/settings.json"),
            false
        )
        .is_err()
    );
    install(&f.settings());
    for p in [&receipt, &f.0.join("settings.json.tako-bak")] {
        assert_eq!(fs::metadata(p).unwrap().permissions().mode() & 0o777, 0o600);
    }
    assert_eq!(fs::read_to_string(foreign).unwrap(), "{}");
}

#[test]
fn later_pointer_and_user_hooks_are_preserved_on_uninstall() {
    let f = Fixture::new();
    install(&f.settings());
    let mut settings = value(&f.settings());
    settings["managed_hooks_path"] = json!("new-user-hooks.json");
    fs::write(f.settings(), settings.to_string()).unwrap();
    fs::write(f.0.join("new-user-hooks.json"), "{}").unwrap();
    uninstall(&f.settings());
    assert_eq!(
        value(&f.settings())["managed_hooks_path"],
        "new-user-hooks.json"
    );
    assert_eq!(
        fs::read_to_string(f.0.join("new-user-hooks.json")).unwrap(),
        "{}"
    );
}

#[test]
fn absolute_pointer_and_disabled_required_hooks() {
    let f = Fixture::new();
    let hooks = f.0.join("foreign-managed.json");
    fs::write(&hooks, "{}").unwrap();
    fs::write(
        f.settings(),
        json!({"managed_hooks_path": hooks}).to_string(),
    )
    .unwrap();
    install(&f.settings());
    let a = native::adapter("muse");
    let mut root = value(&hooks);
    root["hooks"]["Stop"][0]["enabled"] = json!(false);
    fs::write(&hooks, root.to_string()).unwrap();
    assert!(!a.is_installed(&f.settings()));
    assert!(managed::plan(&a, &f.settings(), false).is_err());
    uninstall(&f.settings());
    assert_eq!(
        value(&f.settings())["managed_hooks_path"],
        hooks.to_string_lossy().as_ref()
    );
}

#[test]
fn later_hooks_keep_the_owned_pointer_accessible() {
    let f = Fixture::new();
    install(&f.settings());
    let mut root = value(&f.managed());
    root["hooks"]["Other"] = json!([{"hooks":[{"type":"command","command":"echo later"}]}]);
    fs::write(f.managed(), root.to_string()).unwrap();
    uninstall(&f.settings());
    assert_eq!(
        value(&f.settings())["managed_hooks_path"],
        "tako-managed-hooks.json"
    );
    assert_eq!(value(&f.managed())["hooks"].as_object().unwrap().len(), 1);
}

#[test]
fn removed_allowlist_is_not_recreated_by_uninstall() {
    let f = Fixture::new();
    install(&f.settings());
    let mut settings = value(&f.settings());
    settings
        .as_object_mut()
        .unwrap()
        .remove("managed_hooks_env_vars");
    fs::write(f.settings(), settings.to_string()).unwrap();
    uninstall(&f.settings());
    assert!(value(&f.settings()).get("managed_hooks_env_vars").is_none());
}
