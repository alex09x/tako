/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

//! Bundled agent skills management for `takoctl skills`.
//!
//! Provides inspection, diffing, installation, and byte-identical uninstallation
//! of Tako skill descriptions and MCP configuration into popular coding agents
//! (Claude Code, Gemini CLI, Codex, Aider).

pub mod adapter;
pub mod fs_util;
#[cfg(test)]
mod tests;

use std::fs;
use std::io::{self, BufRead, Write};

use serde_json::{Value, json};

#[allow(unused_imports)]
pub use adapter::{SkillAdapter, all_adapters, find_adapter};
pub use fs_util::unified_diff;
use fs_util::{
    backup_path, file_mode, harden_owner_only_mode, new_marker_path, validate_not_symlink, write_secure,
};

pub const TAKO_SKILL_MD: &str = include_str!("../../skills/tako/SKILL.md");

// MARK: - Actions

pub fn list(json: bool) -> Result<(), String> {
    let adapters = all_adapters();
    if json {
        let items: Vec<Value> = adapters
            .iter()
            .map(|a| {
                let p = a.resolve_skill_path(None);
                json!({
                    "name": a.name,
                    "title": a.title,
                    "aliases": a.aliases,
                    "skill_path": p.display().to_string(),
                    "installed": a.is_installed(&p),
                })
            })
            .collect();
        println!("{}", serde_json::to_string_pretty(&items).unwrap_or_default());
        return Ok(());
    }

    println!("{:<12} {:<24} {:<10} {:<40}", "AGENT", "NAME", "STATUS", "SKILL PATH");
    println!("{:-<12} {:-<24} {:-<10} {:-<40}", "", "", "", "");
    for a in &adapters {
        let p = a.resolve_skill_path(None);
        let status = if a.is_installed(&p) { "installed" } else { "not installed" };
        println!("{:<12} {:<24} {:<10} {:<40}", a.name, a.title, status, p.display());
    }
    Ok(())
}

pub fn status(agent_query: Option<&str>, json: bool) -> Result<(), String> {
    let adapters = if let Some(q) = agent_query {
        let a = find_adapter(q).ok_or_else(|| format!("unknown agent '{q}' (use 'takoctl skills list')"))?;
        vec![a]
    } else {
        all_adapters()
    };

    if json {
        let items: Vec<Value> = adapters
            .iter()
            .map(|a| {
                let p = a.resolve_skill_path(None);
                json!({
                    "name": a.name,
                    "title": a.title,
                    "skill_path": p.display().to_string(),
                    "installed": a.is_installed(&p),
                    "file_exists": p.exists(),
                })
            })
            .collect();
        println!("{}", serde_json::to_string_pretty(&items).unwrap_or_default());
        return Ok(());
    }

    for a in &adapters {
        let p = a.resolve_skill_path(None);
        let installed = a.is_installed(&p);
        println!("{} ({})", a.title, a.name);
        println!("  Skill path:  {}", p.display());
        println!("  Status:      {}", if installed { "installed" } else { "not installed" });
        println!("  File exists: {}", if p.exists() { "yes" } else { "no" });
    }
    Ok(())
}

pub fn install(
    agent_query: &str,
    skill_override: Option<&str>,
    yes: bool,
    diff_only: bool,
    json: bool,
) -> Result<(), String> {
    let adapter = find_adapter(agent_query)
        .ok_or_else(|| format!("unknown agent '{agent_query}' (use 'takoctl skills list')"))?;

    let path = adapter.resolve_skill_path(skill_override);
    let path_display = path.display().to_string();
    let bak = backup_path(&path);
    let marker = new_marker_path(&path);

    validate_not_symlink(&path)?;
    validate_not_symlink(&bak)?;
    validate_not_symlink(&marker)?;

    let original_content = if path.exists() {
        validate_not_symlink(&path)?;
        fs::read_to_string(&path).map_err(|e| format!("cannot read {path_display}: {e}"))?
    } else {
        String::new()
    };

    let new_content = TAKO_SKILL_MD.to_string();

    if original_content == new_content {
        if bak.exists() {
            harden_owner_only_mode(&bak)?;
        }
        if marker.exists() {
            harden_owner_only_mode(&marker)?;
        }
        if json {
            println!("{}", json!({"status": "already_installed", "skill_path": path_display, "diff": ""}));
        } else {
            println!("Tako skill is already installed in {path_display}");
        }
        return Ok(());
    }

    let diff = unified_diff(&original_content, &new_content, &path_display);

    if diff_only {
        if json {
            println!("{}", json!({"status": "diff_only", "skill_path": path_display, "diff": diff}));
        } else {
            print!("{diff}");
        }
        return Ok(());
    }

    if !json {
        println!("Proposed skill installation for {path_display}:");
        println!("{diff}");
    }

    if !yes {
        print!("Install Tako skill into {path_display}? [y/N]: ");
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

    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| format!("cannot create directory {}: {e}", parent.display()))?;
    }

    let orig_mode = file_mode(&path);

    if path.exists() {
        harden_owner_only_mode(&path)?;
        if !bak.exists() {
            write_secure(&bak, original_content.as_bytes(), orig_mode)?;
            harden_owner_only_mode(&bak)?;
        }
    } else if !marker.exists() {
        write_secure(&marker, b"created by takoctl skills install\n", Some(0o600))?;
        harden_owner_only_mode(&marker)?;
    }

    write_secure(&path, new_content.as_bytes(), orig_mode)?;
    harden_owner_only_mode(&path)?;

    if json {
        println!("{}", json!({"status": "installed", "skill_path": path_display}));
    } else {
        println!("Installed Tako skill for {} into {path_display}", adapter.title);
    }
    Ok(())
}

pub fn uninstall(
    agent_query: &str,
    skill_override: Option<&str>,
    yes: bool,
    diff_only: bool,
    json: bool,
) -> Result<(), String> {
    let adapter = find_adapter(agent_query)
        .ok_or_else(|| format!("unknown agent '{agent_query}' (use 'takoctl skills list')"))?;

    let path = adapter.resolve_skill_path(skill_override);
    let path_display = path.display().to_string();
    let bak = backup_path(&path);
    let marker = new_marker_path(&path);

    validate_not_symlink(&path)?;
    validate_not_symlink(&bak)?;
    validate_not_symlink(&marker)?;

    if !path.exists() && !bak.exists() && !marker.exists() {
        if json {
            println!("{}", json!({"status": "not_installed", "skill_path": path_display}));
        } else {
            println!("Tako skill is not installed for {} ({path_display})", adapter.title);
        }
        return Ok(());
    }

    let original_content = if path.exists() {
        validate_not_symlink(&path)?;
        fs::read_to_string(&path).map_err(|e| format!("cannot read {path_display}: {e}"))?
    } else {
        String::new()
    };

    let target_content = if bak.exists() {
        validate_not_symlink(&bak)?;
        fs::read_to_string(&bak).map_err(|e| format!("cannot read backup {}: {e}", bak.display()))?
    } else {
        String::new()
    };

    let diff = unified_diff(&original_content, &target_content, &path_display);

    if diff_only {
        if json {
            println!("{}", json!({"status": "diff_only", "skill_path": path_display, "diff": diff}));
        } else {
            print!("{diff}");
        }
        return Ok(());
    }

    if !json {
        println!("Proposed uninstallation for {path_display}:");
        println!("{diff}");
    }

    if !yes {
        print!("Remove Tako skill from {path_display}? [y/N]: ");
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

    if bak.exists() {
        validate_not_symlink(&bak)?;
        validate_not_symlink(&path)?;
        let bak_mode = file_mode(&bak);
        write_secure(&path, target_content.as_bytes(), bak_mode)?;
        harden_owner_only_mode(&path)?;
        let _ = fs::remove_file(&bak);
    } else if marker.exists() || path.exists() {
        validate_not_symlink(&path)?;
        validate_not_symlink(&marker)?;
        let _ = fs::remove_file(&path);
        let _ = fs::remove_file(&marker);
    }

    if json {
        println!("{}", json!({"status": "uninstalled", "skill_path": path_display}));
    } else {
        println!("Uninstalled Tako skill for {} from {path_display}", adapter.title);
    }
    Ok(())
}
