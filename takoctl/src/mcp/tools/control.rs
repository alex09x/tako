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
            name: "tako_tree",
            description: "Inspect windows, tabs, and panes in Tako with their current working directory, titles, and status.",
            required_scopes: &[CapabilityScope::Read],
            input_schema: json!({
                "type": "object",
                "properties": {}
            }),
        },
        McpTool {
            name: "tako_split",
            description: "Split the current or specified pane horizontally or vertically, optionally linking as a child subagent pane.",
            required_scopes: &[CapabilityScope::Layout],
            input_schema: json!({
                "type": "object",
                "properties": {
                    "direction": {
                        "type": "string",
                        "enum": ["right", "left", "down", "up"],
                        "description": "Split direction: right, left, down, or up (default: right)"
                    },
                    "target": {
                        "type": "string",
                        "description": "Target pane ID or 'self' (default: current pane)"
                    },
                    "child_of": {
                        "type": "string",
                        "description": "Link the new pane as a child of this pane ID (or 'self')"
                    },
                    "label": {
                        "type": "string",
                        "description": "Label for child pane (e.g. subagent or task name)"
                    },
                    "cwd": {
                        "type": "string",
                        "description": "Initial working directory for the new split pane"
                    }
                }
            }),
        },
        McpTool {
            name: "tako_run",
            description: "Run a program directly (as an argument vector, no shell injection) in a new split or tab, optionally waiting for completion.",
            required_scopes: &[CapabilityScope::Layout, CapabilityScope::Input],
            input_schema: json!({
                "type": "object",
                "properties": {
                    "program": {
                        "type": "string",
                        "description": "Executable program path or command name to resolve on PATH"
                    },
                    "args": {
                        "type": "array",
                        "items": { "type": "string" },
                        "description": "Command-line arguments to pass directly to the program"
                    },
                    "split": {
                        "type": "string",
                        "enum": ["right", "left", "down", "up"],
                        "description": "Split direction, or omit to launch in a new tab"
                    },
                    "cwd": {
                        "type": "string",
                        "description": "Working directory for the program"
                    },
                    "wait": {
                        "type": "boolean",
                        "description": "If true, wait for the program to exit and return exit status and output"
                    },
                    "timeout": {
                        "type": "string",
                        "description": "Timeout when wait is true (e.g. '30s', '120s', '5m')"
                    }
                },
                "required": ["program"]
            }),
        },
        McpTool {
            name: "tako_wait",
            description: "Wait for a pane's running command or background program to finish through Tako's OSC 133 integration without scraping screen text.",
            required_scopes: &[CapabilityScope::Read],
            input_schema: json!({
                "type": "object",
                "properties": {
                    "target": {
                        "type": "string",
                        "description": "Target pane ID to wait on (default: current pane)"
                    },
                    "command": {
                        "type": "string",
                        "description": "Specific command reference (ID@EPOCH) to wait for"
                    },
                    "next": {
                        "type": "boolean",
                        "description": "Wait for the next command to finish"
                    },
                    "timeout": {
                        "type": "string",
                        "description": "Timeout duration (e.g. '60s', '2m')"
                    },
                    "lines": {
                        "type": "integer",
                        "description": "Maximum number of trailing output lines to return"
                    }
                }
            }),
        },
        McpTool {
            name: "tako_last",
            description: "Retrieve structured details of the last command run in a pane, including exit code, directory, duration, and output.",
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
                        "description": "Maximum number of trailing output lines to return"
                    }
                }
            }),
        },
        McpTool {
            name: "tako_find",
            description: "Search text across all open tabs and panes in Tako.",
            required_scopes: &[CapabilityScope::Read],
            input_schema: json!({
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": "Text query to search for"
                    },
                    "limit": {
                        "type": "integer",
                        "description": "Maximum number of search results to return"
                    }
                },
                "required": ["query"]
            }),
        },
        McpTool {
            name: "tako_notify",
            description: "Post a desktop notification linked to the pane; clicking it brings the pane forward.",
            required_scopes: &[CapabilityScope::Signal],
            input_schema: json!({
                "type": "object",
                "properties": {
                    "text": {
                        "type": "string",
                        "description": "Notification message body"
                    },
                    "title": {
                        "type": "string",
                        "description": "Notification title (default: Tako)"
                    },
                    "target": {
                        "type": "string",
                        "description": "Target pane ID (default: current pane)"
                    }
                },
                "required": ["text"]
            }),
        },
        McpTool {
            name: "tako_status",
            description: "Set or clear the pane's status indicator and badge text (working, needs_approval, waiting_for_input, done, error).",
            required_scopes: &[CapabilityScope::Signal],
            input_schema: json!({
                "type": "object",
                "properties": {
                    "status": {
                        "type": "string",
                        "description": "Status value: 'working', 'needs_approval', 'waiting_for_input', 'done', 'error', 'idle', or 'clear'"
                    },
                    "text": {
                        "type": "string",
                        "description": "Short explanatory status text (truncated to 128 chars)"
                    },
                    "ttl": {
                        "type": "string",
                        "description": "Time-to-live duration for the status (e.g. '30s', '10m')"
                    },
                    "target": {
                        "type": "string",
                        "description": "Target pane ID (default: current pane)"
                    }
                }
            }),
        },
        McpTool {
            name: "tako_progress",
            description: "Set or clear the pane's progress bar (0-100 percentage, indeterminate, pause, error, or clear).",
            required_scopes: &[CapabilityScope::Signal],
            input_schema: json!({
                "type": "object",
                "properties": {
                    "state": {
                        "type": "string",
                        "description": "Progress state: '0'-'100', 'indeterminate', 'pause', 'error', 'clear', or 'get'"
                    },
                    "target": {
                        "type": "string",
                        "description": "Target pane ID (default: current pane)"
                    }
                }
            }),
        },
        McpTool {
            name: "tako_ask",
            description: "Prompt the user with an interactive question, choice selection, or confirmation modal in Tako UI, returning their answer.",
            required_scopes: &[CapabilityScope::Signal],
            input_schema: json!({
                "type": "object",
                "properties": {
                    "message": {
                        "type": "string",
                        "description": "Question message or prompt to display to the user"
                    },
                    "choices": {
                        "type": "array",
                        "items": { "type": "string" },
                        "description": "List of choice options for the user to select from"
                    },
                    "confirm": {
                        "type": "boolean",
                        "description": "If true, prompts for a Yes/No confirmation"
                    },
                    "placeholder": {
                        "type": "string",
                        "description": "Placeholder text for text input"
                    },
                    "default": {
                        "type": "string",
                        "description": "Default answer value if prompt times out"
                    },
                    "timeout": {
                        "type": "string",
                        "description": "Timeout duration (e.g. '30s', '2m')"
                    },
                    "title": {
                        "type": "string",
                        "description": "Optional title for the prompt modal"
                    },
                    "target": {
                        "type": "string",
                        "description": "Target pane ID (default: current pane)"
                    }
                },
                "required": ["message"]
            }),
        },
    ]
}
