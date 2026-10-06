/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

//! Agent hook adapters and configuration management for `takoctl hooks`.
//!
//! Provides inspection, diffing, installation, and byte-identical uninstallation
//! of Tako lifecycle hooks into coding-agent tools (Claude Code, Gemini CLI, Codex, Aider).

pub mod adapter;
pub mod fs_util;
#[cfg(test)]
mod tests;

use std::fs;
use std::io::{self, BufRead, Write};

use serde_json::{Value, json};

#[allow(unused_imports)]
pub use adapter::{
    ADAPTER_AIDER, ADAPTER_CLAUDE, ADAPTER_CODEX, ADAPTER_GEMINI, Adapter, all_adapters, find_adapter,
};
pub use fs_util::unified_diff;
use fs_util::{
    backup_path, file_mode, harden_owner_only_mode, new_marker_path, write_secure,
};

// MARK: - Actions: List, Status, Install, Uninstall

pub fn list(json: bool) -> Result<(), String> {
    let adapters = all_adapters();
    if json {
        let items: Vec<Value> = adapters
            .iter()
            .map(|a| {
                let p = a.resolve_path(None);
                json!({
                    "name": a.name,
                    "title": a.title,
                    "aliases": a.aliases,
                    "config_path": p.display().to_string(),
                    "installed": a.is_installed(&p),
                })
            })
            .collect();
        println!("{}", serde_json::to_string_pretty(&items).unwrap_or_default());
        return Ok(());
    }

    println!("{:<12} {:<24} {:<10} {:<30}", "AGENT", "NAME", "STATUS", "CONFIG FILE");
    println!("{:-<12} {:-<24} {:-<10} {:-<30}", "", "", "", "");
    for a in &adapters {
        let p = a.resolve_path(None);
        let status = if a.is_installed(&p) { "installed" } else { "not installed" };
        println!("{:<12} {:<24} {:<10} {:<30}", a.name, a.title, status, p.display());
    }
    Ok(())
}

pub fn status(agent_query: Option<&str>, json: bool) -> Result<(), String> {
    let adapters = if let Some(q) = agent_query {
        let a = find_adapter(q).ok_or_else(|| format!("unknown agent '{q}' (use 'takoctl hooks list')"))?;
        vec![a]
    } else {
        all_adapters()
    };

    if json {
        let items: Vec<Value> = adapters
            .iter()
            .map(|a| {
                let p = a.resolve_path(None);
                json!({
                    "name": a.name,
                    "title": a.title,
                    "config_path": p.display().to_string(),
                    "installed": a.is_installed(&p),
                    "file_exists": p.exists(),
                })
            })
            .collect();
        println!("{}", serde_json::to_string_pretty(&items).unwrap_or_default());
        return Ok(());
    }

    for a in &adapters {
        let p = a.resolve_path(None);
        let installed = a.is_installed(&p);
        println!("{} ({})", a.title, a.name);
        println!("  Config:    {}", p.display());
        println!("  Status:    {}", if installed { "installed" } else { "not installed" });
        println!("  File exists: {}", if p.exists() { "yes" } else { "no" });
    }
    Ok(())
}

pub fn install(
    agent_query: &str,
    config_override: Option<&str>,
    yes: bool,
    diff_only: bool,
    json: bool,
) -> Result<(), String> {
    let adapter = find_adapter(agent_query)
        .ok_or_else(|| format!("unknown agent '{agent_query}' (use 'takoctl hooks list')"))?;

    let path = adapter.resolve_path(config_override);
    let path_display = path.display().to_string();
    let bak = backup_path(&path);
    let marker = new_marker_path(&path);

    let original_content = if path.exists() {
        fs::read_to_string(&path).map_err(|e| format!("cannot read {path_display}: {e}"))?
    } else {
        String::new()
    };

    let new_content = adapter.apply_hooks(&original_content)?;

    if original_content == new_content {
        // Enforce restrictive owner-only permissions on any existing backup or marker
        if bak.exists() {
            harden_owner_only_mode(&bak)?;
        }
        if marker.exists() {
            harden_owner_only_mode(&marker)?;
        }
        if json {
            println!("{}", json!({"status": "already_installed", "config": path_display, "diff": ""}));
        } else {
            println!("Tako hooks are already installed in {path_display}");
        }
        return Ok(());
    }

    let diff = unified_diff(&original_content, &new_content, &path_display);

    if diff_only {
        if json {
            println!("{}", json!({"status": "diff_only", "config": path_display, "diff": diff}));
        } else {
            print!("{diff}");
        }
        return Ok(());
    }

    if !json {
        println!("Proposed changes for {path_display}:");
        println!("{diff}");
    }

    if !yes {
        print!("Install Tako hooks into {path_display}? [y/N]: ");
        io::stdout().flush().map_err(|e| e.to_string())?;
        let mut line = String::new();
        let stdin = io::stdin();
        stdin.lock().read_line(&mut line).map_err(|e| e.to_string())?;
        let answer = line.trim().to_lowercase();
        if answer != "y" && answer != "yes" {
            println!("Installation cancelled.");
            return Ok(());
        }
    }

    // Ensure parent directories exist
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| format!("cannot create directory {}: {e}", parent.display()))?;
    }

    // Capture original mode before modifying files
    let orig_mode = file_mode(&path);

    // Save byte-identical restoration backup with restrictive permissions (0600):
    if path.exists() {
        // If a backup doesn't already exist, preserve the original pre-Tako bytes
        if !bak.exists() {
            // Backup should strictly have owner-only permissions (0600 or orig_mode & 0600)
            let bak_mode = orig_mode.map(|m| m & 0o600).unwrap_or(0o600);
            write_secure(&bak, original_content.as_bytes(), Some(bak_mode))?;
        } else {
            // Pre-existing backup might have over-permissive mode from an earlier install or outside tool.
            // Enforce restrictive owner-only permissions before proceeding, failing closed if permissions cannot be tightened.
            harden_owner_only_mode(&bak)?;
        }
    } else {
        // Record that this file was created anew by Tako
        if !marker.exists() {
            write_secure(&marker, b"new", Some(0o600))?;
        } else {
            harden_owner_only_mode(&marker)?;
        }
    }

    // Write new content preserving source mode or defaulting to 0600
    let target_mode = orig_mode.unwrap_or(0o600);
    write_secure(&path, new_content.as_bytes(), Some(target_mode))?;

    if json {
        println!("{}", json!({"status": "installed", "config": path_display, "diff": diff}));
    } else {
        println!("Successfully installed Tako hooks into {path_display}");
    }

    Ok(())
}

pub fn uninstall(
    agent_query: &str,
    config_override: Option<&str>,
    yes: bool,
    diff_only: bool,
    json: bool,
) -> Result<(), String> {
    let adapter = find_adapter(agent_query)
        .ok_or_else(|| format!("unknown agent '{agent_query}' (use 'takoctl hooks list')"))?;

    let path = adapter.resolve_path(config_override);
    let path_display = path.display().to_string();

    if !path.exists() {
        return Err(format!("configuration file {path_display} does not exist"));
    }

    let current_content = fs::read_to_string(&path)
        .map_err(|e| format!("cannot read {path_display}: {e}"))? ;

    let bak = backup_path(&path);
    let marker = new_marker_path(&path);

    // Determine target restored state
    enum RestoreAction {
        DeleteFile,
        WriteBytes(String),
    }

    let action = if marker.exists() {
        let meta = fs::symlink_metadata(&marker)
            .map_err(|e| format!("cannot inspect marker {}: {e}", marker.display()))?;
        if meta.file_type().is_symlink() {
            return Err(format!("refusing to use symlink at {}", marker.display()));
        }
        // The file was created anew by Tako
        RestoreAction::DeleteFile
    } else if bak.exists() {
        let meta = fs::symlink_metadata(&bak)
            .map_err(|e| format!("cannot inspect backup {}: {e}", bak.display()))?;
        if meta.file_type().is_symlink() {
            return Err(format!("refusing to restore from symlink at {}", bak.display()));
        }
        if !meta.is_file() {
            return Err(format!("expected regular file backup at {}", bak.display()));
        }
        // Enforce owner-only permissions on backup before reading
        harden_owner_only_mode(&bak)?;

        // We have the exact original bytes saved
        let orig = fs::read_to_string(&bak).map_err(|e| format!("cannot read backup: {e}"))?;
        RestoreAction::WriteBytes(orig)
    } else {
        // Fallback: surgically remove the Tako hooks
        let stripped = adapter.remove_hooks(&current_content)?;
        if stripped.trim().is_empty() {
            RestoreAction::DeleteFile
        } else {
            RestoreAction::WriteBytes(stripped)
        }
    };

    let target_str = match &action {
        RestoreAction::DeleteFile => String::new(),
        RestoreAction::WriteBytes(s) => s.clone(),
    };

    if current_content == target_str {
        if json {
            println!("{}", json!({"status": "not_installed", "config": path_display, "diff": ""}));
        } else {
            println!("No Tako hooks found in {path_display}");
        }
        return Ok(());
    }

    let diff = unified_diff(&current_content, &target_str, &path_display);

    if diff_only {
        if json {
            println!("{}", json!({"status": "diff_only", "config": path_display, "diff": diff}));
        } else {
            print!("{diff}");
        }
        return Ok(());
    }

    if !json {
        println!("Proposed changes for {path_display}:");
        println!("{diff}");
    }

    if !yes {
        print!("Uninstall Tako hooks from {path_display}? [y/N]: ");
        io::stdout().flush().map_err(|e| e.to_string())?;
        let mut line = String::new();
        let stdin = io::stdin();
        stdin.lock().read_line(&mut line).map_err(|e| e.to_string())?;
        let answer = line.trim().to_lowercase();
        if answer != "y" && answer != "yes" {
            println!("Uninstallation cancelled.");
            return Ok(());
        }
    }

    let orig_mode = file_mode(&bak).or_else(|| file_mode(&path));

    // Apply the uninstallation
    match action {
        RestoreAction::DeleteFile => {
            fs::remove_file(&path).map_err(|e| format!("cannot remove {path_display}: {e}"))?;
        }
        RestoreAction::WriteBytes(ref s) => {
            write_secure(&path, s.as_bytes(), orig_mode)
                .map_err(|e| format!("cannot restore {path_display}: {e}"))?;
        }
    }

    // Clean up backup / marker files
    let _ = fs::remove_file(&bak);
    let _ = fs::remove_file(&marker);

    if json {
        println!("{}", json!({"status": "uninstalled", "config": path_display, "diff": diff}));
    } else {
        println!("Successfully uninstalled Tako hooks from {path_display}");
    }

    Ok(())
}
