//! Agent hook adapters and configuration management for `takoctl hooks`.
//!
//! Provides inspection, diffing, installation, and byte-identical uninstallation
//! of Tako lifecycle hooks into coding-agent tools (Claude Code, Gemini CLI, Codex, Aider).

use std::fs;
use std::io::{self, BufRead, Write};
use std::path::{Path, PathBuf};

use serde_json::{Map, Value, json};

pub const ADAPTER_CLAUDE: &str = include_str!("../adapters/claude.json");
pub const ADAPTER_GEMINI: &str = include_str!("../adapters/gemini.json");
pub const ADAPTER_CODEX: &str = include_str!("../adapters/codex.json");
pub const ADAPTER_AIDER: &str = include_str!("../adapters/aider.json");

#[derive(Debug, Clone)]
pub struct Adapter {
    pub name: String,
    pub title: String,
    pub aliases: Vec<String>,
    pub config_path: String,
    pub format: String,
    pub hook_field: String,
    pub hooks: Value,
}

impl Adapter {
    pub fn from_json_str(s: &str) -> Result<Self, String> {
        let v: Value = serde_json::from_str(s).map_err(|e| format!("invalid adapter JSON: {e}"))?;
        let name = v["name"].as_str().ok_or("missing adapter name")?.to_string();
        let title = v["title"].as_str().unwrap_or(&name).to_string();
        let aliases = v["aliases"]
            .as_array()
            .map(|arr| arr.iter().filter_map(Value::as_str).map(String::from).collect())
            .unwrap_or_default();
        let config_path = v["config_path"].as_str().ok_or("missing config_path")?.to_string();
        let format = v["format"].as_str().unwrap_or("json").to_string();
        let hook_field = v["hook_field"].as_str().unwrap_or("hooks").to_string();
        let hooks = v["hooks"].clone();

        Ok(Adapter {
            name,
            title,
            aliases,
            config_path,
            format,
            hook_field,
            hooks,
        })
    }

    pub fn matches(&self, query: &str) -> bool {
        let q = query.to_lowercase();
        self.name.to_lowercase() == q || self.aliases.iter().any(|a| a.to_lowercase() == q)
    }

    pub fn resolve_path(&self, override_path: Option<&str>) -> PathBuf {
        if let Some(p) = override_path {
            return PathBuf::from(p);
        }
        resolve_home_path(&self.config_path)
    }

    /// Checks whether Tako hooks are currently installed in the target file.
    pub fn is_installed(&self, path: &Path) -> bool {
        if !path.exists() {
            return false;
        }
        let content = match fs::read_to_string(path) {
            Ok(c) => c,
            Err(_) => return false,
        };

        if self.format == "json" {
            let val: Value = match serde_json::from_str(&content) {
                Ok(v) => v,
                Err(_) => return false,
            };
            if let Some(hooks_obj) = val.get(&self.hook_field) {
                // Check if any takoctl command is present
                let serialized = hooks_obj.to_string();
                serialized.contains("takoctl status") || serialized.contains("takoctl progress")
            } else {
                false
            }
        } else {
            // yaml / lines
            content.contains("takoctl status") || content.contains("takoctl progress")
        }
    }

    /// Injects Tako hooks into existing or empty content.
    pub fn apply_hooks(&self, original: &str) -> Result<String, String> {
        if self.format == "json" {
            let mut root: Value = if original.trim().is_empty() {
                json!({})
            } else {
                serde_json::from_str(original).map_err(|e| format!("cannot parse JSON: {e}"))?
            };

            let root_obj = root.as_object_mut().ok_or("JSON root must be an object")?;

            if let Some(template_obj) = self.hooks.as_object() {
                let hooks_entry = root_obj
                    .entry(self.hook_field.clone())
                    .or_insert_with(|| Value::Object(Map::new()));

                let existing_hooks = hooks_entry
                    .as_object_mut()
                    .ok_or_else(|| format!("'{}' field must be an object", self.hook_field))?;

                for (event, hook_val) in template_obj {
                    if let Some(new_arr) = hook_val.as_array() {
                        // Array of hook objects (e.g. Claude Code)
                        if let Some(existing_val) = existing_hooks.get_mut(event) {
                            if let Some(existing_arr) = existing_val.as_array_mut() {
                                for item in new_arr {
                                    let item_str = item.to_string();
                                    if !existing_arr.iter().any(|ex| ex.to_string() == item_str) {
                                        existing_arr.push(item.clone());
                                    }
                                }
                            } else {
                                existing_hooks.insert(event.clone(), hook_val.clone());
                            }
                        } else {
                            existing_hooks.insert(event.clone(), hook_val.clone());
                        }
                    } else {
                        // String or scalar hook command (e.g. Gemini, Codex)
                        existing_hooks.insert(event.clone(), hook_val.clone());
                    }
                }
            }

            let mut out = serde_json::to_string_pretty(&root).map_err(|e| format!("serialization error: {e}"))?;
            out.push('\n');
            Ok(out)
        } else {
            // YAML format (e.g. Aider)
            let mut lines: Vec<String> = original.lines().map(String::from).collect();
            if let Some(template_obj) = self.hooks.as_object() {
                for (key, val) in template_obj {
                    let cmd_str = val.as_str().unwrap_or("");
                    let yaml_line = format!("{key}: \"{cmd_str}\"");
                    // If key already exists, replace it; else append
                    if let Some(idx) = lines.iter().position(|l| l.trim_start().starts_with(&format!("{key}:"))) {
                        lines[idx] = yaml_line;
                    } else {
                        lines.push(yaml_line);
                    }
                }
            }
            let mut out = lines.join("\n");
            if !out.is_empty() {
                out.push('\n');
            }
            Ok(out)
        }
    }

    /// Removes Tako hooks from content (fallback when backup is not available).
    pub fn remove_hooks(&self, content: &str) -> Result<String, String> {
        if self.format == "json" {
            let mut root: Value = serde_json::from_str(content).map_err(|e| format!("cannot parse JSON: {e}"))?;
            let root_obj = root.as_object_mut().ok_or("JSON root must be an object")?;

            if let Some(existing_hooks) = root_obj.get_mut(&self.hook_field).and_then(Value::as_object_mut) {
                if let Some(template_obj) = self.hooks.as_object() {
                    for (event, hook_val) in template_obj {
                        if hook_val.is_array() {
                            if let Some(arr) = existing_hooks.get_mut(event).and_then(Value::as_array_mut) {
                                arr.retain(|item| !item.to_string().contains("takoctl"));
                                if arr.is_empty() {
                                    existing_hooks.remove(event);
                                }
                            }
                        } else if let Some(val) = existing_hooks.get(event) {
                            if val.to_string().contains("takoctl") {
                                existing_hooks.remove(event);
                            }
                        }
                    }
                }

                if existing_hooks.is_empty() {
                    root_obj.remove(&self.hook_field);
                }
            }

            if root_obj.is_empty() {
                return Ok(String::new());
            }

            let mut out = serde_json::to_string_pretty(&root).map_err(|e| format!("serialization error: {e}"))?;
            out.push('\n');
            Ok(out)
        } else {
            let mut lines: Vec<String> = content.lines().map(String::from).collect();
            lines.retain(|l| !l.contains("takoctl"));
            let mut out = lines.join("\n");
            if !out.is_empty() {
                out.push('\n');
            }
            Ok(out)
        }
    }
}

pub fn all_adapters() -> Vec<Adapter> {
    vec![
        Adapter::from_json_str(ADAPTER_CLAUDE).expect("valid claude adapter"),
        Adapter::from_json_str(ADAPTER_GEMINI).expect("valid gemini adapter"),
        Adapter::from_json_str(ADAPTER_CODEX).expect("valid codex adapter"),
        Adapter::from_json_str(ADAPTER_AIDER).expect("valid aider adapter"),
    ]
}

pub fn find_adapter(query: &str) -> Option<Adapter> {
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

/// Writes bytes to a file with explicit permission mode (on Unix).
/// If `mode` is None, defaults to 0o600 (owner read/write only).
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

/// Enforces owner-only permissions (0600 on Unix, no group/other access) on a file.
/// Fails closed if the file is a symlink, not a regular file, or if permissions cannot be tightened.
fn harden_owner_only_mode(path: &Path) -> Result<(), String> {
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
        // Verify owner-only permissions: no group or other access (current_mode & 0o077 == 0)
        // and owner has at least read/write (0o600).
        if current_mode & 0o077 != 0 || current_mode & 0o600 != 0o600 {
            let hardened_mode = (current_mode & 0o700) | 0o600;
            let perms = fs::Permissions::from_mode(hardened_mode);
            fs::set_permissions(path, perms).map_err(|e| {
                format!("failed to harden permissions on {}: {e}", path.display())
            })?;

            // Fail-closed verification: confirm mode was actually tightened
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


// MARK: - Unified Diff Helper

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

    // Simple robust diff: find common prefix and suffix
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

    // Context lines before
    for line in &old_lines[context_before..prefix] {
        out += &format!(" {line}\n");
    }

    // Deletions
    for line in &old_lines[prefix..old_mid_end] {
        out += &format!("-{line}\n");
    }

    // Insertions
    for line in &new_lines[prefix..new_mid_end] {
        out += &format!("+{line}\n");
    }

    // Context lines after
    let after_end = (old_mid_end + 3).min(old_lines.len());
    for line in &old_lines[old_mid_end..after_end] {
        out += &format!(" {line}\n");
    }

    out
}

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
        .map_err(|e| format!("cannot read {path_display}: {e}"))?;

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

// MARK: - Unit Tests

#[cfg(test)]
mod tests {
    use super::*;

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
}


