/*
 * tako — Transactional configuration writes
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */
use super::fs_util::{file_mode, unified_diff};
use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
    sync::atomic::{AtomicU64, Ordering},
};
static SEQUENCE: AtomicU64 = AtomicU64::new(0);

pub fn inspect(path: &Path) -> Result<(), String> {
    for ancestor in path.ancestors() {
        match fs::symlink_metadata(ancestor) {
            Ok(meta) if meta.file_type().is_symlink() => {
                return Err(format!("refusing symlink at {}", ancestor.display()));
            }
            Ok(meta) if ancestor == path && !meta.is_file() => {
                return Err(format!("expected regular file at {}", path.display()));
            }
            Ok(_) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(format!("cannot inspect {}: {e}", ancestor.display())),
        }
    }
    Ok(())
}

pub fn read(path: &Path) -> Result<Option<String>, String> {
    inspect(path)?;
    match fs::read_to_string(path) {
        Ok(s) => Ok(Some(s)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(format!("cannot read {}: {e}", path.display())),
    }
}

pub struct Change {
    pub path: PathBuf,
    pub before: Option<String>,
    pub after: Option<String>,
    mode: u32,
    original_mode: Option<u32>,
}

impl Change {
    pub fn new(path: PathBuf, after: Option<String>) -> Result<Self, String> {
        let before = read(&path)?;
        let original_mode = file_mode(&path);
        let mode = original_mode.unwrap_or(0o600);
        Ok(Self {
            path,
            before,
            after,
            mode,
            original_mode,
        })
    }
    pub fn secure(path: PathBuf, after: Option<String>) -> Result<Self, String> {
        let mut change = Self::new(path, after)?;
        change.mode = 0o600;
        Ok(change)
    }
    pub fn diff(&self) -> String {
        unified_diff(
            self.before.as_deref().unwrap_or(""),
            self.after.as_deref().unwrap_or(""),
            &self.path.display().to_string(),
        )
    }
    pub fn changed(&self) -> bool {
        self.before != self.after
            || (self.after.is_some() && self.original_mode.is_some_and(|m| m != self.mode))
    }
}

fn replace(path: &Path, content: Option<&str>, mode: u32) -> Result<(), String> {
    inspect(path)?;
    let Some(content) = content else {
        return match fs::remove_file(path) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(format!("cannot remove {}: {e}", path.display())),
        };
    };
    let temporary = path.with_file_name(format!(
        ".tako-write-{}-{}",
        std::process::id(),
        SEQUENCE.fetch_add(1, Ordering::Relaxed)
    ));
    let mut created = false;
    let result: Result<(), String> = (|| {
        let mut opts = fs::OpenOptions::new();
        opts.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            opts.mode(mode);
        }
        let mut file = opts.open(&temporary).map_err(|e| e.to_string())?;
        created = true;
        file.write_all(content.as_bytes())
            .map_err(|e| e.to_string())?;
        file.sync_all().map_err(|e| e.to_string())?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            file.set_permissions(fs::Permissions::from_mode(mode))
                .map_err(|e| e.to_string())?;
        }
        fs::rename(&temporary, path).map_err(|e| e.to_string())
    })();
    if created {
        let _ = fs::remove_file(&temporary);
    }
    result.map_err(|e| format!("cannot write {}: {e}", path.display()))
}

pub fn commit(changes: &[Change], fail_at: Option<usize>) -> Result<(), String> {
    let changes: Vec<_> = changes.iter().filter(|c| c.changed()).collect();
    let mut directories = Vec::new();
    for change in &changes {
        if read(&change.path)? != change.before {
            return Err("configuration changed during planning".into());
        }
    }
    let mut applied = 0;
    let result: Result<(), String> = (|| {
        for change in &changes {
            if let Some(parent) = change.path.parent() {
                let mut missing = Vec::new();
                for p in parent.ancestors().take_while(|p| !p.exists()) {
                    missing.push(p.to_owned());
                }
                for p in missing.into_iter().rev() {
                    fs::create_dir(&p).map_err(|e| e.to_string())?;
                    directories.push(p);
                }
            }
        }
        for (index, change) in changes.iter().enumerate() {
            if fail_at == Some(index) {
                return Err("injected transaction failure".into());
            }
            replace(&change.path, change.after.as_deref(), change.mode)?;
            applied += 1;
        }
        Ok(())
    })();
    if let Err(error) = result {
        let mut failures = Vec::new();
        for change in changes[..applied].iter().rev() {
            if let Err(e) = replace(
                &change.path,
                change.before.as_deref(),
                change.original_mode.unwrap_or(0o600),
            ) {
                failures.push(e);
            }
        }
        for directory in directories.iter().rev() {
            let _ = fs::remove_dir(directory);
        }
        return Err(format!("{error}; rollback errors: {}", failures.join("; ")));
    }
    Ok(())
}
