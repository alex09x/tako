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

use serde_json::{Map, Value, json};

use super::fs_util::resolve_home_path;

pub const ADAPTER_CLAUDE: &str = include_str!("../../adapters/claude.json");
pub const ADAPTER_GEMINI: &str = include_str!("../../adapters/gemini.json");
pub const ADAPTER_CODEX: &str = include_str!("../../adapters/codex.json");
pub const ADAPTER_AIDER: &str = include_str!("../../adapters/aider.json");

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
                let serialized = hooks_obj.to_string();
                serialized.contains("takoctl status") || serialized.contains("takoctl progress")
            } else {
                false
            }
        } else {
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
                        existing_hooks.insert(event.clone(), hook_val.clone());
                    }
                }
            }

            let mut out = serde_json::to_string_pretty(&root).map_err(|e| format!("serialization error: {e}"))?;
            out.push('\n');
            Ok(out)
        } else {
            let mut lines: Vec<String> = original.lines().map(String::from).collect();
            if let Some(template_obj) = self.hooks.as_object() {
                for (key, val) in template_obj {
                    let cmd_str = val.as_str().unwrap_or("");
                    let yaml_line = format!("{key}: \"{cmd_str}\"");
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
