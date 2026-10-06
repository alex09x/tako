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
use std::path::{Path, PathBuf};

use super::fs_util::resolve_home_path;

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
        #[cfg(unix)]
        {
            if let Ok(meta) = fs::symlink_metadata(path) {
                if meta.file_type().is_symlink() || !meta.is_file() {
                    return false;
                }
            }
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
