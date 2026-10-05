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

use std::fs;
use std::io::{self, BufRead, Write};
use std::path::{Path, PathBuf};

use serde_json::{Value, json};

pub const TAKO_SKILL_MD: &str = include_str!("../skills/tako/SKILL.md");

#[derive(Debug, Clone)]
pub struct SkillAdapter {
    pub name: &'static str,
    pub title: &'static str,
    pub aliases: &'static [&'static str],
    pub skill_path: &'static str,
    #[allow(dead_code)]
    pub mcp_config_path: Option<&'static str>,
}

impl SkillAdapter {
    pub fn matches(&self, query: &str) -> bool {
        let q = query.to_lowercase();
        self.name.to_lowercase() == q || self.aliases.iter().any(|a| a.to_lowercase() == q)
    }

    pub fn resolve_skill_path(&self, override_path: Option<&str>) -> PathBuf {
        if let Some(p) = override_path {
            return PathBuf::from(p);
        }
        resolve_home_path(self.skill_path)
    }

    #[allow(dead_code)]
    pub fn resolve_mcp_path(&self) -> Option<PathBuf> {
        self.mcp_config_path.map(resolve_home_path)
    }

    pub fn is_installed(&self, path: &Path) -> bool {
        if !path.exists() {
            return false;
        }
        match fs::read_to_string(path) {
            Ok(content) => content.contains("Tako Terminal Integration") || content.contains("name: tako"),
            Err(_) => false,
        }
    }
}

pub fn all_adapters() -> Vec<SkillAdapter> {
    vec![
        SkillAdapter {
            name: "claude",
            title: "Claude Code",
            aliases: &["claude-code", "anthropic"],
            skill_path: "~/.claude/skills/tako/SKILL.md",
            mcp_config_path: Some("~/.claude.json"),
        },
        SkillAdapter {
            name: "gemini",
            title: "Gemini CLI / Antigravity",
            aliases: &["antigravity", "google"],
            skill_path: "~/.gemini/config/skills/tako/SKILL.md",
            mcp_config_path: Some("~/.gemini/antigravity-cli/mcp/tako.json"),
        },
        SkillAdapter {
            name: "codex",
            title: "Codex CLI",
            aliases: &["openai"],
            skill_path: "~/.codex/skills/tako/SKILL.md",
            mcp_config_path: None,
        },
        SkillAdapter {
            name: "aider",
            title: "Aider",
            aliases: &["aider-chat"],
            skill_path: "~/.aider/skills/tako/SKILL.md",
            mcp_config_path: None,
        },
    ]
}

pub fn find_adapter(query: &str) -> Option<SkillAdapter> {
    all_adapters().into_iter().find(|a| a.matches(query))
}

fn resolve_home_path(raw: &str) -> PathBuf {
    if let Some(stripped) = raw.strip_prefix("~/") {
        if let Ok(home) = std::env::var("HOME") {
            return PathBuf::from(home).join(stripped);
        }
    }
    PathBuf::from(raw)
}

fn backup_path(path: &Path) -> PathBuf {
    let mut s = path.as_os_str().to_os_string();
    s.push(".tako-bak");
    PathBuf::from(s)
}

fn new_marker_path(path: &Path) -> PathBuf {
    let mut s = path.as_os_str().to_os_string();
    s.push(".tako-new");
    PathBuf::from(s)
}

#[cfg(unix)]
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};

fn file_mode(path: &Path) -> Option<u32> {
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

fn write_secure(path: &Path, content: &[u8], mode: Option<u32>) -> Result<(), String> {
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

fn harden_owner_only_mode(path: &Path) -> Result<(), String> {
    #[cfg(unix)]
    {
        let meta = fs::symlink_metadata(path)
            .map_err(|e| format!("cannot inspect metadata on {}: {e}", path.display()))?;
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
            fs::set_permissions(path, perms)
                .map_err(|e| format!("failed to harden permissions on {}: {e}", path.display()))?;

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

    let original_content = if path.exists() {
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

    if !path.exists() && !bak.exists() && !marker.exists() {
        if json {
            println!("{}", json!({"status": "not_installed", "skill_path": path_display}));
        } else {
            println!("Tako skill is not installed for {} ({path_display})", adapter.title);
        }
        return Ok(());
    }

    let original_content = if path.exists() {
        fs::read_to_string(&path).map_err(|e| format!("cannot read {path_display}: {e}"))?
    } else {
        String::new()
    };

    let target_content = if bak.exists() {
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
        let bak_mode = file_mode(&bak);
        write_secure(&path, target_content.as_bytes(), bak_mode)?;
        harden_owner_only_mode(&path)?;
        let _ = fs::remove_file(&bak);
    } else if marker.exists() || path.exists() {
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

#[cfg(test)]
mod tests {
    use super::*;

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
        assert!(new_marker_path(&skill_file).exists());

        // Uninstall
        uninstall("claude", Some(&skill_str), true, false, true).expect("uninstall succeeds");
        assert!(!skill_file.exists());
        assert!(!new_marker_path(&skill_file).exists());

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
        assert!(backup_path(&skill_file).exists());
        let installed = fs::read_to_string(&skill_file).expect("read installed");
        assert!(installed.contains("Tako Terminal Integration"));

        // Uninstall restores exact original content
        uninstall("gemini", Some(&skill_str), true, false, true).expect("uninstall succeeds");
        assert!(skill_file.exists());
        let restored = fs::read_to_string(&skill_file).expect("read restored");
        assert_eq!(restored, existing);
        assert!(!backup_path(&skill_file).exists());

        // Clean up
        let _ = fs::remove_dir_all(&temp_dir);
    }
}
