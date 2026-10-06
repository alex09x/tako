/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use std::collections::HashSet;

// MARK: - G1 Capability Model

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum CapabilityScope {
    Read,
    Input,
    Layout,
    Signal,
    Overlay,
    Approval,
}

impl CapabilityScope {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Read => "read",
            Self::Input => "input",
            Self::Layout => "layout",
            Self::Signal => "signal",
            Self::Overlay => "overlay",
            Self::Approval => "approval",
        }
    }

    pub fn parse(s: &str) -> Result<Self, String> {
        match s.trim().to_lowercase().as_str() {
            "read" => Ok(Self::Read),
            "input" => Ok(Self::Input),
            "layout" => Ok(Self::Layout),
            "signal" => Ok(Self::Signal),
            "overlay" => Ok(Self::Overlay),
            "approval" => Ok(Self::Approval),
            other => Err(format!(
                "unknown capability scope '{other}'; valid scopes are read, input, layout, signal, overlay, approval"
            )),
        }
    }
}

#[derive(Debug, Clone)]
pub struct Capabilities {
    pub(crate) scopes: HashSet<CapabilityScope>,
}

impl Capabilities {
    pub fn scopes(&self) -> &HashSet<CapabilityScope> {
        &self.scopes
    }

    pub fn all() -> Self {
        let mut scopes = HashSet::new();
        scopes.insert(CapabilityScope::Read);
        scopes.insert(CapabilityScope::Input);
        scopes.insert(CapabilityScope::Layout);
        scopes.insert(CapabilityScope::Signal);
        scopes.insert(CapabilityScope::Overlay);
        Self { scopes }
    }

    pub fn parse(s: &str) -> Result<Self, String> {
        let mut scopes = HashSet::new();
        for part in s.split(',') {
            let part = part.trim();
            if part.is_empty() {
                continue;
            }
            if part.eq_ignore_ascii_case("all") {
                return Ok(Self::all());
            }
            scopes.insert(CapabilityScope::parse(part)?);
        }
        if scopes.is_empty() {
            return Err("capabilities list cannot be empty".into());
        }
        Ok(Self { scopes })
    }

    pub fn contains(&self, scope: CapabilityScope) -> bool {
        self.scopes.contains(&scope)
    }

    pub fn formatted_scopes(&self) -> String {
        let mut items: Vec<&'static str> = self.scopes.iter().map(|s| s.as_str()).collect();
        items.sort();
        items.join(", ")
    }
}
