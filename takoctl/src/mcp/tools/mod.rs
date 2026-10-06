/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

pub mod control;
pub mod overlay;
pub mod review;

use serde_json::Value;

use crate::mcp::capabilities::CapabilityScope;

#[derive(Debug, Clone)]
pub struct McpTool {
    pub name: &'static str,
    pub description: &'static str,
    pub required_scopes: &'static [CapabilityScope],
    pub input_schema: Value,
}

pub fn all_tools() -> Vec<McpTool> {
    let mut all = Vec::new();
    all.extend(control::tools());
    all.extend(overlay::tools());
    all.extend(review::tools());
    all
}
