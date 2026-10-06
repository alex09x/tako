/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use serde_json::json;

use super::McpTool;
use crate::mcp::capabilities::CapabilityScope;

pub fn tools() -> Vec<McpTool> {
    vec![
        McpTool {
            name: "tako_overlay_open",
            description: "Display an interactive HTML, Markdown, unified diff, image, or PDF document in an overlay above or split beside a pane (using 'split' also requires 'layout' capability scope).",
            required_scopes: &[CapabilityScope::Overlay],
            input_schema: json!({
                "type": "object",
                "properties": {
                    "file": {
                        "type": "string",
                        "description": "Path to artifact or document file (e.g. .html, .md, .diff, image, .pdf)"
                    },
                    "split": {
                        "type": "string",
                        "enum": ["right", "left", "down", "up"],
                        "description": "Optional split direction to open overlay in a split pane beside target (requires 'layout' capability scope)"
                    },
                    "type": {
                        "type": "string",
                        "enum": ["html", "markdown", "image", "pdf", "diff"],
                        "description": "Optional explicit file type override"
                    },
                    "target": {
                        "type": "string",
                        "description": "Target pane ID (default: current pane)"
                    }
                },
                "required": ["file"]
            }),
        },
        McpTool {
            name: "tako_overlay_close",
            description: "Close an active artifact/document overlay on the current or specified pane.",
            required_scopes: &[CapabilityScope::Overlay],
            input_schema: json!({
                "type": "object",
                "properties": {
                    "target": {
                        "type": "string",
                        "description": "Target pane ID (default: current pane)"
                    }
                }
            }),
        },
        McpTool {
            name: "tako_overlay_status",
            description: "Inspect active artifact/document overlay state on the current or specified pane.",
            required_scopes: &[CapabilityScope::Overlay],
            input_schema: json!({
                "type": "object",
                "properties": {
                    "target": {
                        "type": "string",
                        "description": "Target pane ID (default: current pane)"
                    }
                }
            }),
        },
        McpTool {
            name: "tako_text",
            description: "Read text from the terminal pane, optionally styled with ANSI SGR color/attribute escape codes.",
            required_scopes: &[CapabilityScope::Read],
            input_schema: json!({
                "type": "object",
                "properties": {
                    "target": {
                        "type": "string",
                        "description": "Target pane ID (default: current pane)"
                    },
                    "lines": {
                        "type": "integer",
                        "description": "Maximum number of trailing lines to read"
                    },
                    "styled": {
                        "type": "boolean",
                        "description": "If true, preserve terminal colors and styling attributes as ANSI SGR escape sequences"
                    }
                }
            }),
        },
        McpTool {
            name: "tako_screenshot",
            description: "Capture the rendered pane as a PNG image.",
            required_scopes: &[CapabilityScope::Read],
            input_schema: json!({
                "type": "object",
                "properties": {
                    "target": {
                        "type": "string",
                        "description": "Target pane ID (default: current pane)"
                    }
                }
            }),
        },
    ]
}
