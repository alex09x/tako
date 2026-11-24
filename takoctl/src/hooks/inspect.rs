/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use serde_json::{Value, json};

use super::adapter::{all_adapters, find_adapter};

fn effective_installed(a: &super::adapter::Adapter, p: &std::path::Path) -> bool {
    if a.uses_native_osc7501() {
        a.is_installed(p) || super::osc7501_migration::has_legacy_artifacts(a, p)
    } else {
        a.is_installed(p)
    }
}

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
                    "installed": effective_installed(a, &p),
                    "native_osc7501": a.uses_native_osc7501(),
                })
            })
            .collect();
        println!(
            "{}",
            serde_json::to_string_pretty(&items).unwrap_or_default()
        );
        return Ok(());
    }

    println!(
        "{:<12} {:<24} {:<16} {:<30}",
        "AGENT", "NAME", "STATUS", "CONFIG FILE"
    );
    println!("{:-<12} {:-<24} {:-<16} {:-<30}", "", "", "", "");
    for a in &adapters {
        let p = a.resolve_path(None);
        let status = if a.uses_native_osc7501() {
            if effective_installed(a, &p) {
                "legacy hooks"
            } else {
                "native (7501)"
            }
        } else if a.is_installed(&p) {
            "installed"
        } else {
            "not installed"
        };
        println!(
            "{:<12} {:<24} {:<16} {:<30}",
            a.name,
            a.title,
            status,
            p.display()
        );
    }
    Ok(())
}

pub fn status(agent_query: Option<&str>, json: bool) -> Result<(), String> {
    let adapters = if let Some(q) = agent_query {
        let a = find_adapter(q)
            .ok_or_else(|| format!("unknown agent '{q}' (use 'takoctl hooks list')"))?;
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
                    "installed": effective_installed(a, &p),
                    "native_osc7501": a.uses_native_osc7501(),
                    "file_exists": p.exists(),
                })
            })
            .collect();
        println!(
            "{}",
            serde_json::to_string_pretty(&items).unwrap_or_default()
        );
        return Ok(());
    }

    for a in &adapters {
        let p = a.resolve_path(None);
        let installed = effective_installed(a, &p);
        println!("{} ({})", a.title, a.name);
        println!("  Config:    {}", p.display());
        let label = if a.uses_native_osc7501() {
            if installed {
                "native OSC 7501 (legacy hooks still present)"
            } else {
                "native OSC 7501 (built-in, no hooks needed)"
            }
        } else if installed {
            "installed"
        } else {
            "not installed"
        };
        println!("  Status:    {label}");
        println!("  File exists: {}", if p.exists() { "yes" } else { "no" });
    }
    Ok(())
}
