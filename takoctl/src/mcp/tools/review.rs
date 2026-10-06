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
            name: "tako_review_open",
            description: "Open a read-only diff review pane for a worktree or task against its base branch.",
            required_scopes: &[CapabilityScope::Read],
            input_schema: json!({
                "type": "object",
                "properties": {
                    "task": {
                        "type": "string",
                        "description": "Task name or worktree path to review (C4)"
                    },
                    "base": {
                        "type": "string",
                        "description": "Base branch to diff against (default: main)"
                    },
                    "target": {
                        "type": "string",
                        "description": "Target pane ID where review pane is displayed (default: current pane)"
                    },
                    "target_pane": {
                        "type": "string",
                        "description": "Destination pane ID to receive feedback comments when sent"
                    }
                },
                "required": ["task"]
            }),
        },
        McpTool {
            name: "tako_review_close",
            description: "Close active diff review pane on target pane.",
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
        McpTool {
            name: "tako_review_status",
            description: "Inspect active diff review session status, changed files count, and pending comments count.",
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
        McpTool {
            name: "tako_review_diff",
            description: "Inspect unified diff or changed files list in a diff review session.",
            required_scopes: &[CapabilityScope::Read],
            input_schema: json!({
                "type": "object",
                "properties": {
                    "target": {
                        "type": "string",
                        "description": "Target pane ID (default: current pane)"
                    },
                    "file": {
                        "type": "string",
                        "description": "Optional specific file path to view its unified diff"
                    },
                    "files_only": {
                        "type": "boolean",
                        "description": "If true, list changed files with addition/deletion counts instead of full diff patch"
                    }
                }
            }),
        },
        McpTool {
            name: "tako_review_comment",
            description: "Manage local comments on lines in a diff review session (add, list, remove, clear).",
            required_scopes: &[CapabilityScope::Read],
            input_schema: json!({
                "type": "object",
                "properties": {
                    "target": {
                        "type": "string",
                        "description": "Target pane ID (default: current pane)"
                    },
                    "action": {
                        "type": "string",
                        "enum": ["add", "list", "remove", "clear"],
                        "description": "Comment action: 'add', 'list', 'remove', or 'clear' (default: 'list')"
                    },
                    "file": {
                        "type": "string",
                        "description": "File path for the comment (required for add)"
                    },
                    "line": {
                        "type": "integer",
                        "description": "Line number for the comment (for add, default: 1)"
                    },
                    "text": {
                        "type": "string",
                        "description": "Comment body text (required for add)"
                    },
                    "comment_id": {
                        "type": "string",
                        "description": "Comment ID to remove (required for remove)"
                    }
                }
            }),
        },
        McpTool {
            name: "tako_review_send",
            description: "Send all collected diff review comments as batched plain-text feedback to the target terminal pane (requires 'input' capability scope).",
            required_scopes: &[CapabilityScope::Input],
            input_schema: json!({
                "type": "object",
                "properties": {
                    "target": {
                        "type": "string",
                        "description": "Review pane ID containing the comments (default: current pane)"
                    },
                    "target_pane": {
                        "type": "string",
                        "description": "Destination terminal pane ID to receive the feedback (default: recorded target pane)"
                    }
                }
            }),
        },
    ]
}
