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
use std::io::Write;
use std::path::{Path, PathBuf};

#[cfg(unix)]
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};

pub fn resolve_home_path(raw: &str) -> PathBuf {
    if let Some(stripped) = raw.strip_prefix("~/") {
        if let Ok(home) = std::env::var("HOME") {
            return PathBuf::from(home).join(stripped);
        }
    }
    PathBuf::from(raw)
}

pub fn backup_path(path: &Path) -> PathBuf {
    let mut s = path.as_os_str().to_os_string();
    s.push(".tako-bak");
    PathBuf::from(s)
}

pub fn new_marker_path(path: &Path) -> PathBuf {
    let mut s = path.as_os_str().to_os_string();
    s.push(".tako-new");
    PathBuf::from(s)
}

pub fn file_mode(path: &Path) -> Option<u32> {
    #[cfg(unix)]
    {
        path.metadata().ok().map(|m| m.permissions().mode() & 0o777)
    }
    #[cfg(not(unix))]
    {
        let _ = path;
        None
    }
}

/// Writes bytes to a file with explicit permission mode (on Unix).
/// If `mode` is None, defaults to 0o600 (owner read/write only).
pub fn write_secure(path: &Path, content: &[u8], mode: Option<u32>) -> Result<(), String> {
    #[cfg(unix)]
    {
        let file_mode = mode.unwrap_or(0o600);
        let mut opts = fs::OpenOptions::new();
        opts.write(true).create(true).truncate(true).mode(file_mode);
        let mut file = opts
            .open(path)
            .map_err(|e| format!("cannot open {} with mode {:o}: {e}", path.display(), file_mode))?;
        file.write_all(content)
            .map_err(|e| format!("cannot write {}: {e}", path.display()))?;
        file.flush()
            .map_err(|e| format!("cannot flush {}: {e}", path.display()))?;
        let perms = fs::Permissions::from_mode(file_mode);
        let _ = fs::set_permissions(path, perms);
        Ok(())
    }
    #[cfg(not(unix))]
    {
        let _ = mode;
        fs::write(path, content).map_err(|e| format!("cannot write {}: {e}", path.display()))
    }
}

/// Enforces owner-only permissions (0600 on Unix, no group/other access) on a file.
/// Fails closed if the file is a symlink, not a regular file, or if permissions cannot be tightened.
pub fn harden_owner_only_mode(path: &Path) -> Result<(), String> {
    #[cfg(unix)]
    {
        let meta = fs::symlink_metadata(path).map_err(|e| {
            format!("cannot inspect metadata on {}: {e}", path.display())
        })?;
        if meta.file_type().is_symlink() {
            return Err(format!("refusing to use symlink at {}", path.display()));
        }
        if !meta.is_file() {
            return Err(format!("expected regular file at {}", path.display()));
        }

        let current_mode = meta.permissions().mode() & 0o777;
        if current_mode & 0o077 != 0 || current_mode & 0o600 != 0o600 {
            let hardened_mode = (current_mode & 0o700) | 0o600;
            let perms = fs::Permissions::from_mode(hardened_mode);
            fs::set_permissions(path, perms).map_err(|e| {
                format!("failed to harden permissions on {}: {e}", path.display())
            })?;

            let verified_mode = path
                .metadata()
                .map_err(|e| format!("cannot verify permissions on {}: {e}", path.display()))?
                .permissions()
                .mode() & 0o777;
            if verified_mode & 0o077 != 0 {
                return Err(format!(
                    "cannot enforce owner-only permissions on {}: mode is still {:o}",
                    path.display(),
                    verified_mode
                ));
            }
        }
    }
    #[cfg(not(unix))]
    {
        let _ = path;
    }
    Ok(())
}

/// Generates a unified diff comparing old and new strings.
pub fn unified_diff(old_text: &str, new_text: &str, label: &str) -> String {
    let old_lines: Vec<&str> = if old_text.is_empty() {
        Vec::new()
    } else {
        old_text.lines().collect()
    };
    let new_lines: Vec<&str> = if new_text.is_empty() {
        Vec::new()
    } else {
        new_text.lines().collect()
    };

    if old_lines == new_lines {
        return String::new();
    }

    let mut out = String::new();
    out += &format!("--- a/{label}\n");
    out += &format!("+++ b/{label}\n");

    let mut prefix = 0;
    while prefix < old_lines.len() && prefix < new_lines.len() && old_lines[prefix] == new_lines[prefix] {
        prefix += 1;
    }

    let mut suffix = 0;
    while suffix < (old_lines.len() - prefix)
        && suffix < (new_lines.len() - prefix)
        && old_lines[old_lines.len() - 1 - suffix] == new_lines[new_lines.len() - 1 - suffix]
    {
        suffix += 1;
    }

    let old_mid_end = old_lines.len() - suffix;
    let new_mid_end = new_lines.len() - suffix;

    let context_before = prefix.saturating_sub(3);
    let old_start = context_before + 1;
    let old_count = (old_mid_end + 3.min(suffix)) - context_before;
    let new_start = context_before + 1;
    let new_count = (new_mid_end + 3.min(suffix)) - context_before;

    out += &format!("@@ -{old_start},{old_count} +{new_start},{new_count} @@\n");

    for line in &old_lines[context_before..prefix] {
        out += &format!(" {line}\n");
    }
    for line in &old_lines[prefix..old_mid_end] {
        out += &format!("-{line}\n");
    }
    for line in &new_lines[prefix..new_mid_end] {
        out += &format!("+{line}\n");
    }
    let after_end = (old_mid_end + 3).min(old_lines.len());
    for line in &old_lines[old_mid_end..after_end] {
        out += &format!(" {line}\n");
    }

    out
}
