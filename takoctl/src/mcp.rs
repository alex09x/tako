/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

//! Stdio Model Context Protocol (MCP) server for Tako.
//!
//! Exposes Tako's terminal control and observation capabilities (tree, split, run,
//! wait, last, find, notify, status, progress, ask) to autonomous coding agents over
//! stdio JSON-RPC 2.0. Each tool is protected by the G1 capability scope model.

use std::collections::HashSet;
use std::io::{self, BufRead, Write};
use std::time::Duration;

use serde_json::{Map, Value, json};

use crate::socket::{self, Failure};

// MARK: - G1 Capability Model

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum CapabilityScope {
    Read,
    Input,
    Layout,
    Signal,
    Overlay,
}

impl CapabilityScope {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Read => "read",
            Self::Input => "input",
            Self::Layout => "layout",
            Self::Signal => "signal",
            Self::Overlay => "overlay",
        }
    }

    pub fn parse(s: &str) -> Result<Self, String> {
        match s.trim().to_lowercase().as_str() {
            "read" => Ok(Self::Read),
            "input" => Ok(Self::Input),
            "layout" => Ok(Self::Layout),
            "signal" => Ok(Self::Signal),
            "overlay" => Ok(Self::Overlay),
            other => Err(format!(
                "unknown capability scope '{other}'; valid scopes are read, input, layout, signal, overlay"
            )),
        }
    }
}

#[derive(Debug, Clone)]
pub struct Capabilities {
    scopes: HashSet<CapabilityScope>,
}

impl Capabilities {
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

// MARK: - Tool Definitions

#[derive(Debug, Clone)]
pub struct McpTool {
    pub name: &'static str,
    pub description: &'static str,
    pub required_scopes: &'static [CapabilityScope],
    pub input_schema: Value,
}

pub fn all_tools() -> Vec<McpTool> {
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

// MARK: - Server Implementation

pub struct McpServer {
    pub socket_path: String,
    pub capabilities: Capabilities,
    pub surface_id: Option<String>,
}

impl McpServer {
    pub fn new(socket_path: String, capabilities: Capabilities, surface_id: Option<String>) -> Self {
        Self {
            socket_path,
            capabilities,
            surface_id,
        }
    }

    /// Handles a single incoming JSON-RPC 2.0 message and produces a response if required.
    pub fn handle_message(&self, message_str: &str) -> Option<Value> {
        let msg: Value = match serde_json::from_str(message_str) {
            Ok(v) => v,
            Err(e) => {
                return Some(json!({
                    "jsonrpc": "2.0",
                    "id": Value::Null,
                    "error": {
                        "code": -32700,
                        "message": format!("Parse error: {e}")
                    }
                }));
            }
        };

        let method = match msg.get("method").and_then(Value::as_str) {
            Some(m) => m,
            None => {
                // If there's no method, could be a response or malformed
                return None;
            }
        };

        let id = msg.get("id").cloned();

        match method {
            "initialize" => {
                let id = id.unwrap_or_else(|| json!(1));
                Some(json!({
                    "jsonrpc": "2.0",
                    "id": id,
                    "result": {
                        "protocolVersion": "2024-11-05",
                        "capabilities": {
                            "tools": {}
                        },
                        "serverInfo": {
                            "name": "tako",
                            "version": env!("CARGO_PKG_VERSION")
                        }
                    }
                }))
            }
            "notifications/initialized" => {
                // Standard MCP client notification; no response needed
                None
            }
            "ping" => {
                let id = id.unwrap_or_else(|| json!(1));
                Some(json!({
                    "jsonrpc": "2.0",
                    "id": id,
                    "result": {}
                }))
            }
            "tools/list" => {
                let id = id.unwrap_or_else(|| json!(1));
                let tools_json: Vec<Value> = all_tools()
                    .into_iter()
                    .map(|t| {
                        let scopes_desc = if t.required_scopes.len() == 1 {
                            format!("'{}' capability scope", t.required_scopes[0].as_str())
                        } else {
                            let scopes_list = t
                                .required_scopes
                                .iter()
                                .map(|s| format!("'{}'", s.as_str()))
                                .collect::<Vec<_>>()
                                .join(" and ");
                            format!("{scopes_list} capability scopes")
                        };
                        json!({
                            "name": t.name,
                            "description": format!("{} [requires {}]", t.description, scopes_desc),
                            "inputSchema": t.input_schema
                        })
                    })
                    .collect();
                Some(json!({
                    "jsonrpc": "2.0",
                    "id": id,
                    "result": {
                        "tools": tools_json
                    }
                }))
            }
            "tools/call" => {
                let id = id.unwrap_or_else(|| json!(1));
                let params = msg.get("params").cloned().unwrap_or_else(|| json!({}));
                let tool_name = params.get("name").and_then(Value::as_str).unwrap_or("");
                let args = params.get("arguments").cloned().unwrap_or_else(|| json!({}));

                let res = self.execute_tool(tool_name, &args);
                Some(json!({
                    "jsonrpc": "2.0",
                    "id": id,
                    "result": res
                }))
            }
            other => {
                // Unknown method
                id.map(|req_id| {
                    json!({
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "error": {
                            "code": -32601,
                            "message": format!("Method not found: {other}")
                        }
                    })
                })
            }
        }
    }

    /// Checks capability scope and executes the tool against Tako's control socket.
    fn execute_tool(&self, name: &str, args: &Value) -> Value {
        let tools = all_tools();
        let tool = match tools.iter().find(|t| t.name == name) {
            Some(t) => t,
            None => {
                return json!({
                    "content": [
                        {
                            "type": "text",
                            "text": format!("Unknown tool '{name}'")
                        }
                    ],
                    "isError": true
                });
            }
        };

        // Determine required scopes for this invocation
        let mut required_scopes: Vec<CapabilityScope> = tool.required_scopes.to_vec();

        // tako_overlay_open with split creates a new pane, requiring 'layout' scope
        if name == "tako_overlay_open" {
            let requested_split = match args.get("split") {
                Some(Value::String(s)) => !s.trim().is_empty(),
                Some(Value::Null) | None => false,
                Some(_) => true,
            };
            if requested_split && !required_scopes.contains(&CapabilityScope::Layout) {
                required_scopes.push(CapabilityScope::Layout);
            }
        }

        // G1 Capability check
        for req_scope in required_scopes {
            if !self.capabilities.contains(req_scope) {
                return json!({
                    "content": [
                        {
                            "type": "text",
                            "text": format!(
                                "refusal: tool '{name}' requires '{}' capability scope (active scopes: [{}])",
                                req_scope.as_str(),
                                self.capabilities.formatted_scopes()
                            )
                        }
                    ],
                    "isError": true
                });
            }
        }

        // Build socket request
        let socket_req = match self.build_socket_request(name, args) {
            Ok(r) => r,
            Err(e) => {
                return json!({
                    "content": [
                        {
                            "type": "text",
                            "text": format!("Invalid tool arguments: {e}")
                        }
                    ],
                    "isError": true
                });
            }
        };

        // Determine timeout
        let timeout = self.determine_timeout(name, args);

        // Execute against socket
        match socket::exchange_within(&self.socket_path, &socket_req, timeout, socket::MAX_ANSWER_BYTES) {
            Ok(answer) => self.format_answer(name, &answer),
            Err(Failure { message, sent }) => {
                let note = if sent {
                    " (request sent, may have completed)"
                } else {
                    ""
                };
                json!({
                    "content": [
                        {
                            "type": "text",
                            "text": format!("Tako socket error: {message}{note}")
                        }
                    ],
                    "isError": true
                })
            }
        }
    }

    fn determine_timeout(&self, name: &str, args: &Value) -> Duration {
        if name == "tako_wait" || name == "tako_ask" || (name == "tako_run" && args.get("wait") == Some(&Value::Bool(true))) {
            if let Some(t_str) = args.get("timeout").and_then(Value::as_str) {
                if let Ok(sec) = parse_timeout_seconds(t_str) {
                    return Duration::from_secs_f64(sec) + socket::TIMEOUT;
                }
            }
            return Duration::from_secs(24 * 3600);
        }
        socket::TIMEOUT
    }

    fn build_socket_request(&self, name: &str, args: &Value) -> Result<Value, String> {
        let mut req_args = Map::new();

        // Default target to surface_id if present
        let target = args
            .get("target")
            .and_then(Value::as_str)
            .map(String::from)
            .or_else(|| self.surface_id.clone());

        if let Some(t) = target {
            req_args.insert("target".into(), Value::String(t));
        }

        let cmd = match name {
            "tako_tree" => "tree",
            "tako_split" => {
                let dir = args.get("direction").and_then(Value::as_str).unwrap_or("right");
                req_args.insert("direction".into(), Value::String(dir.into()));
                if let Some(child_of) = args.get("child_of").and_then(Value::as_str) {
                    req_args.insert("child_of".into(), Value::String(child_of.into()));
                }
                if let Some(label) = args.get("label").and_then(Value::as_str) {
                    req_args.insert("label".into(), Value::String(label.into()));
                }
                if let Some(cwd) = args.get("cwd").and_then(Value::as_str) {
                    req_args.insert("cwd".into(), Value::String(cwd.into()));
                }
                "split"
            }
            "tako_run" => {
                let program = args
                    .get("program")
                    .and_then(Value::as_str)
                    .ok_or_else(|| "missing required field 'program'".to_string())?;

                let mut argv = vec![Value::String(program.into())];
                if let Some(items) = args.get("args").and_then(Value::as_array) {
                    argv.extend(items.clone());
                }
                req_args.insert("argv".into(), Value::Array(argv));

                if let Some(split) = args.get("split").and_then(Value::as_str) {
                    req_args.insert("split".into(), Value::String(split.into()));
                }
                if let Some(cwd) = args.get("cwd").and_then(Value::as_str) {
                    req_args.insert("cwd".into(), Value::String(cwd.into()));
                }
                if let Some(wait) = args.get("wait").and_then(Value::as_bool) {
                    req_args.insert("wait".into(), Value::Bool(wait));
                }
                if let Some(timeout) = args.get("timeout").and_then(Value::as_str) {
                    let sec = parse_timeout_seconds(timeout)?;
                    req_args.insert("timeout".into(), Value::from(sec));
                }
                "run"
            }
            "tako_wait" => {
                if let Some(command) = args.get("command").and_then(Value::as_str) {
                    req_args.insert("command".into(), Value::String(command.into()));
                }
                if let Some(next) = args.get("next").and_then(Value::as_bool) {
                    req_args.insert("next".into(), Value::Bool(next));
                }
                if let Some(timeout) = args.get("timeout").and_then(Value::as_str) {
                    let sec = parse_timeout_seconds(timeout)?;
                    req_args.insert("timeout".into(), Value::from(sec));
                }
                if let Some(lines) = args.get("lines").and_then(Value::as_i64) {
                    req_args.insert("lines".into(), Value::from(lines));
                }
                "wait"
            }
            "tako_last" => {
                if let Some(lines) = args.get("lines").and_then(Value::as_i64) {
                    req_args.insert("lines".into(), Value::from(lines));
                }
                "last"
            }
            "tako_find" => {
                let query = args
                    .get("query")
                    .and_then(Value::as_str)
                    .ok_or_else(|| "missing required field 'query'".to_string())?;
                req_args.insert("query".into(), Value::String(query.into()));
                if let Some(limit) = args.get("limit").and_then(Value::as_i64) {
                    req_args.insert("limit".into(), Value::from(limit));
                }
                "find"
            }
            "tako_notify" => {
                let text = args
                    .get("text")
                    .and_then(Value::as_str)
                    .ok_or_else(|| "missing required field 'text'".to_string())?;
                req_args.insert("text".into(), Value::String(text.into()));
                if let Some(title) = args.get("title").and_then(Value::as_str) {
                    req_args.insert("title".into(), Value::String(title.into()));
                }
                "notify"
            }
            "tako_status" => {
                let status = args.get("status").and_then(Value::as_str).unwrap_or("get");
                if status == "clear" {
                    req_args.insert("action".into(), Value::String("clear".into()));
                } else if status == "get" {
                    req_args.insert("action".into(), Value::String("get".into()));
                } else {
                    req_args.insert("action".into(), Value::String("set".into()));
                    req_args.insert("status".into(), Value::String(status.into()));
                    if let Some(text) = args.get("text").and_then(Value::as_str) {
                        req_args.insert("text".into(), Value::String(text.into()));
                    }
                    if let Some(ttl) = args.get("ttl").and_then(Value::as_str) {
                        let sec = parse_timeout_seconds(ttl)?;
                        req_args.insert("ttl".into(), Value::from(sec));
                    }
                }
                "status"
            }
            "tako_progress" => {
                let state = args.get("state").and_then(Value::as_str).unwrap_or("get");
                let state_lower = state.to_lowercase();
                if let Ok(num) = state.parse::<u64>() {
                    req_args.insert("action".into(), Value::String("set".into()));
                    req_args.insert("value".into(), Value::from(num));
                } else {
                    match state_lower.as_str() {
                        "get" => {
                            req_args.insert("action".into(), Value::String("get".into()));
                        }
                        "clear" | "none" | "reset" => {
                            req_args.insert("action".into(), Value::String("clear".into()));
                        }
                        "indeterminate" | "error" | "pause" | "set" => {
                            req_args.insert("action".into(), Value::String(state_lower));
                        }
                        other => {
                            return Err(format!("unknown progress state '{other}'"));
                        }
                    }
                }
                "progress"
            }
            "tako_ask" => {
                let message = args
                    .get("message")
                    .and_then(Value::as_str)
                    .ok_or_else(|| "missing required field 'message'".to_string())?;
                req_args.insert("message".into(), Value::String(message.into()));

                if let Some(choices) = args.get("choices").and_then(Value::as_array) {
                    req_args.insert("choices".into(), Value::Array(choices.clone()));
                }
                if let Some(confirm) = args.get("confirm").and_then(Value::as_bool) {
                    req_args.insert("confirm".into(), Value::Bool(confirm));
                }
                if let Some(placeholder) = args.get("placeholder").and_then(Value::as_str) {
                    req_args.insert("placeholder".into(), Value::String(placeholder.into()));
                }
                if let Some(default_val) = args.get("default").and_then(Value::as_str) {
                    req_args.insert("default".into(), Value::String(default_val.into()));
                }
                if let Some(title) = args.get("title").and_then(Value::as_str) {
                    req_args.insert("title".into(), Value::String(title.into()));
                }
                if let Some(timeout) = args.get("timeout").and_then(Value::as_str) {
                    let sec = parse_timeout_seconds(timeout)?;
                    req_args.insert("timeout".into(), Value::from(sec));
                }
                "ask"
            }
            "tako_overlay_open" => {
                let file = args
                    .get("file")
                    .and_then(Value::as_str)
                    .ok_or_else(|| "missing required field 'file'".to_string())?;
                req_args.insert("subcommand".into(), Value::String("open".into()));
                req_args.insert("file".into(), Value::String(file.into()));
                if let Some(split) = args.get("split").and_then(Value::as_str) {
                    req_args.insert("split".into(), Value::String(split.into()));
                }
                if let Some(type_str) = args.get("type").and_then(Value::as_str) {
                    req_args.insert("type".into(), Value::String(type_str.into()));
                }
                "overlay"
            }
            "tako_overlay_close" => {
                req_args.insert("subcommand".into(), Value::String("close".into()));
                "overlay"
            }
            "tako_overlay_status" => {
                req_args.insert("subcommand".into(), Value::String("status".into()));
                "overlay"
            }
            "tako_text" => {
                if let Some(lines) = args.get("lines").and_then(Value::as_i64) {
                    req_args.insert("lines".into(), Value::from(lines));
                }
                if let Some(styled) = args.get("styled").and_then(Value::as_bool) {
                    req_args.insert("styled".into(), Value::Bool(styled));
                }
                "text"
            }
            "tako_screenshot" => "screenshot",
            "tako_review_open" => {
                let task = args
                    .get("task")
                    .or_else(|| args.get("worktree"))
                    .and_then(Value::as_str)
                    .ok_or_else(|| "missing required field 'task'".to_string())?;
                req_args.insert("subcommand".into(), Value::String("open".into()));
                req_args.insert("task".into(), Value::String(task.into()));
                if let Some(base) = args.get("base").and_then(Value::as_str) {
                    req_args.insert("base".into(), Value::String(base.into()));
                }
                if let Some(target_pane) = args.get("target_pane").and_then(Value::as_str) {
                    req_args.insert("target_pane".into(), Value::String(target_pane.into()));
                }
                "review"
            }
            "tako_review_close" => {
                req_args.insert("subcommand".into(), Value::String("close".into()));
                "review"
            }
            "tako_review_status" => {
                req_args.insert("subcommand".into(), Value::String("status".into()));
                "review"
            }
            "tako_review_diff" => {
                if let Some(true) = args.get("files_only").and_then(Value::as_bool) {
                    req_args.insert("subcommand".into(), Value::String("files".into()));
                } else {
                    req_args.insert("subcommand".into(), Value::String("diff".into()));
                    if let Some(file) = args.get("file").and_then(Value::as_str) {
                        req_args.insert("file".into(), Value::String(file.into()));
                    }
                }
                "review"
            }
            "tako_review_comment" => {
                req_args.insert("subcommand".into(), Value::String("comment".into()));
                let action = args.get("action").and_then(Value::as_str).unwrap_or("list");
                req_args.insert("action".into(), Value::String(action.into()));
                match action {
                    "add" => {
                        let file = args
                            .get("file")
                            .and_then(Value::as_str)
                            .ok_or_else(|| "missing required field 'file'".to_string())?;
                        let text = args
                            .get("text")
                            .and_then(Value::as_str)
                            .ok_or_else(|| "missing required field 'text'".to_string())?;
                        req_args.insert("file".into(), Value::String(file.into()));
                        req_args.insert("text".into(), Value::String(text.into()));
                        if let Some(line) = args.get("line").and_then(Value::as_i64) {
                            req_args.insert("line".into(), Value::from(line));
                        }
                    }
                    "remove" => {
                        let comment_id = args
                            .get("comment_id")
                            .or_else(|| args.get("id"))
                            .and_then(Value::as_str)
                            .ok_or_else(|| "missing required field 'comment_id'".to_string())?;
                        req_args.insert("comment_id".into(), Value::String(comment_id.into()));
                    }
                    "list" | "clear" => {}
                    other => return Err(format!("unknown review comment action '{other}'")),
                }
                "review"
            }
            "tako_review_send" => {
                req_args.insert("subcommand".into(), Value::String("send".into()));
                if let Some(target_pane) = args.get("target_pane").and_then(Value::as_str) {
                    req_args.insert("target_pane".into(), Value::String(target_pane.into()));
                }
                "review"
            }
            other => return Err(format!("unrecognized tool '{other}'")),
        };

        let mut req = Map::new();
        req.insert("cmd".into(), Value::String(cmd.into()));
        req.insert("args".into(), Value::Object(req_args));
        if let Some(s) = &self.surface_id {
            req.insert("from".into(), Value::String(s.clone()));
        }

        Ok(Value::Object(req))
    }

    fn format_answer(&self, name: &str, answer: &Value) -> Value {
        let is_ok = answer.get("ok").and_then(Value::as_bool).unwrap_or(true);
        if is_ok {
            if name == "tako_text" {
                let text = answer["result"]["text"].as_str().unwrap_or("").to_string();
                return json!({
                    "content": [
                        {
                            "type": "text",
                            "text": text
                        }
                    ],
                    "isError": false
                });
            }
            if name == "tako_screenshot" {
                if let Some(data) = answer["result"]["data"].as_str() {
                    let id = answer["result"]["id"].as_str().unwrap_or("");
                    let width = answer["result"]["width"].as_f64().unwrap_or(0.0) as u64;
                    let height = answer["result"]["height"].as_f64().unwrap_or(0.0) as u64;
                    return json!({
                        "content": [
                            {
                                "type": "image",
                                "data": data,
                                "mimeType": "image/png"
                            },
                            {
                                "type": "text",
                                "text": format!("Screenshot of pane {id} ({width}x{height} png)")
                            }
                        ],
                        "isError": false
                    });
                }
            }
            let text = if let Some(res) = answer.get("result") {
                serde_json::to_string_pretty(res).unwrap_or_else(|_| res.to_string())
            } else {
                serde_json::to_string_pretty(answer).unwrap_or_else(|_| answer.to_string())
            };
            json!({
                "content": [
                    {
                        "type": "text",
                        "text": text
                    }
                ],
                "isError": false
            })
        } else {
            let error_text = if let Some(err) = answer.get("error") {
                format!(
                    "{}: {}",
                    err.get("code").and_then(Value::as_str).unwrap_or("error"),
                    err.get("message").and_then(Value::as_str).unwrap_or("command failed")
                )
            } else {
                answer.to_string()
            };
            json!({
                "content": [
                    {
                        "type": "text",
                        "text": error_text
                    }
                ],
                "isError": true
            })
        }
    }

    /// Runs the stdio MCP server event loop until stdin closes.
    pub fn run_stdio(&self) -> io::Result<()> {
        let stdin = io::stdin();
        let mut stdout = io::stdout();

        for line_res in stdin.lock().lines() {
            let line = line_res?;
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }

            if let Some(response) = self.handle_message(trimmed) {
                let serialized = serde_json::to_string(&response)?;
                stdout.write_all(serialized.as_bytes())?;
                stdout.write_all(b"\n")?;
                stdout.flush()?;
            }
        }
        Ok(())
    }
}

fn parse_timeout_seconds(s: &str) -> Result<f64, String> {
    let s = s.trim();
    if let Some(rest) = s.strip_suffix("ms") {
        let ms: f64 = rest.trim().parse().map_err(|_| format!("invalid duration '{s}'"))?;
        return Ok(ms / 1000.0);
    }
    if let Some(rest) = s.strip_suffix('s') {
        let sec: f64 = rest.trim().parse().map_err(|_| format!("invalid duration '{s}'"))?;
        return Ok(sec);
    }
    if let Some(rest) = s.strip_suffix('m') {
        let m: f64 = rest.trim().parse().map_err(|_| format!("invalid duration '{s}'"))?;
        return Ok(m * 60.0);
    }
    if let Some(rest) = s.strip_suffix('h') {
        let h: f64 = rest.trim().parse().map_err(|_| format!("invalid duration '{s}'"))?;
        return Ok(h * 3600.0);
    }
    s.parse::<f64>().map_err(|_| format!("invalid duration '{s}'"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_mcp_capabilities_parsing_and_checking() {
        let caps = Capabilities::parse("read,signal").unwrap();
        assert!(caps.contains(CapabilityScope::Read));
        assert!(caps.contains(CapabilityScope::Signal));
        assert!(!caps.contains(CapabilityScope::Layout));
        assert!(!caps.contains(CapabilityScope::Input));

        let all = Capabilities::parse("all").unwrap();
        assert!(all.contains(CapabilityScope::Read));
        assert!(all.contains(CapabilityScope::Layout));
        assert!(all.contains(CapabilityScope::Input));
        assert!(all.contains(CapabilityScope::Signal));
    }

    #[test]
    fn test_mcp_initialize_and_tools_list() {
        let caps = Capabilities::all();
        let server = McpServer::new("/tmp/test.sock".into(), caps, Some("pane-123".into()));

        let init_msg = json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2024-11-05",
                "capabilities": {}
            }
        })
        .to_string();

        let resp = server.handle_message(&init_msg).expect("response");
        assert_eq!(resp["jsonrpc"], "2.0");
        assert_eq!(resp["id"], 1);
        assert_eq!(resp["result"]["serverInfo"]["name"], "tako");

        let list_msg = json!({
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/list"
        })
        .to_string();

        let list_resp = server.handle_message(&list_msg).expect("tools list response");
        let tools = list_resp["result"]["tools"].as_array().expect("tools array");
        assert!(tools.iter().any(|t| t["name"] == "tako_split"));
        assert!(tools.iter().any(|t| t["name"] == "tako_run"));
        assert!(tools.iter().any(|t| t["name"] == "tako_wait"));
        assert!(tools.iter().any(|t| t["name"] == "tako_status"));
    }

    #[test]
    fn test_mcp_capability_scope_refusal() {
        let signal_only = Capabilities::parse("signal").unwrap();
        let server = McpServer::new("/tmp/test.sock".into(), signal_only, Some("pane-123".into()));

        // Call a tool requiring layout scope
        let call_split = json!({
            "jsonrpc": "2.0",
            "id": 10,
            "method": "tools/call",
            "params": {
                "name": "tako_split",
                "arguments": {
                    "direction": "right"
                }
            }
        })
        .to_string();

        let resp = server.handle_message(&call_split).expect("response");
        assert_eq!(resp["result"]["isError"], true);
        let text = resp["result"]["content"][0]["text"].as_str().unwrap();
        assert!(text.contains("refusal: tool 'tako_split' requires 'layout' capability scope"));
        assert!(text.contains("active scopes: [signal]"));
    }

    #[test]
    fn test_mcp_run_requires_input_and_layout() {
        let run_msg = json!({
            "jsonrpc": "2.0",
            "id": 20,
            "method": "tools/call",
            "params": {
                "name": "tako_run",
                "arguments": {
                    "program": "ls",
                    "args": ["-la"]
                }
            }
        })
        .to_string();

        // 1. Layout-only server refuses tako_run because input is missing
        let layout_only = Capabilities::parse("layout").unwrap();
        let server_layout = McpServer::new("/tmp/test.sock".into(), layout_only, Some("pane-1".into()));
        let resp = server_layout.handle_message(&run_msg).expect("response");
        assert_eq!(resp["result"]["isError"], true);
        let text = resp["result"]["content"][0]["text"].as_str().unwrap();
        assert!(text.contains("refusal: tool 'tako_run' requires 'input' capability scope"));
        assert!(text.contains("active scopes: [layout]"));

        // 2. Input-only server refuses tako_run because layout is missing
        let input_only = Capabilities::parse("input").unwrap();
        let server_input = McpServer::new("/tmp/test.sock".into(), input_only, Some("pane-1".into()));
        let resp2 = server_input.handle_message(&run_msg).expect("response");
        assert_eq!(resp2["result"]["isError"], true);
        let text2 = resp2["result"]["content"][0]["text"].as_str().unwrap();
        assert!(text2.contains("refusal: tool 'tako_run' requires 'layout' capability scope"));
        assert!(text2.contains("active scopes: [input]"));

        // 3. Layout + Input server accepts capability check (and proceeds to socket connection)
        let layout_input = Capabilities::parse("layout,input").unwrap();
        let server_both = McpServer::new("/tmp/test.sock".into(), layout_input, Some("pane-1".into()));
        let resp3 = server_both.handle_message(&run_msg).expect("response");
        assert_eq!(resp3["result"]["isError"], true);
        let text3 = resp3["result"]["content"][0]["text"].as_str().unwrap();
        assert!(!text3.contains("refusal:"));
        assert!(text3.contains("Tako socket error:"));
    }

    #[test]
    fn test_mcp_build_socket_request() {
        let caps = Capabilities::all();
        let server = McpServer::new("/tmp/test.sock".into(), caps, Some("surface-abc".into()));

        let split_args = json!({
            "direction": "down",
            "child_of": "self",
            "label": "subagent-1"
        });
        let req = server.build_socket_request("tako_split", &split_args).unwrap();
        assert_eq!(req["cmd"], "split");
        assert_eq!(req["from"], "surface-abc");
        assert_eq!(req["args"]["direction"], "down");
        assert_eq!(req["args"]["child_of"], "self");
        assert_eq!(req["args"]["label"], "subagent-1");
        assert_eq!(req["args"]["target"], "surface-abc");

        let status_args = json!({
            "status": "working",
            "text": "Compiling",
            "ttl": "30s"
        });
        let req2 = server.build_socket_request("tako_status", &status_args).unwrap();
        assert_eq!(req2["cmd"], "status");
        assert_eq!(req2["args"]["action"], "set");
        assert_eq!(req2["args"]["status"], "working");
        assert_eq!(req2["args"]["text"], "Compiling");
        assert_eq!(req2["args"]["ttl"], 30.0);
    }

    #[test]
    fn test_mcp_overlay_tools_and_scoping() {
        // 1. Verify tools/list contains overlay tools
        let caps = Capabilities::all();
        let server = McpServer::new("/tmp/test.sock".into(), caps, Some("surface-abc".into()));
        let list_msg = json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/list"
        }).to_string();
        let list_resp = server.handle_message(&list_msg).expect("response");
        let tools = list_resp["result"]["tools"].as_array().expect("tools array");
        assert!(tools.iter().any(|t| t["name"] == "tako_overlay_open"));
        assert!(tools.iter().any(|t| t["name"] == "tako_overlay_close"));
        assert!(tools.iter().any(|t| t["name"] == "tako_overlay_status"));

        // 2. Overlay tool requires 'overlay' scope
        let call_overlay = json!({
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": {
                "name": "tako_overlay_open",
                "arguments": {
                    "file": "/tmp/test.md"
                }
            }
        }).to_string();

        let read_layout = Capabilities::parse("read,layout").unwrap();
        let server_no_overlay = McpServer::new("/tmp/test.sock".into(), read_layout, Some("surface-abc".into()));
        let resp = server_no_overlay.handle_message(&call_overlay).expect("response");
        assert_eq!(resp["result"]["isError"], true);
        let text = resp["result"]["content"][0]["text"].as_str().unwrap();
        assert!(text.contains("refusal: tool 'tako_overlay_open' requires 'overlay' capability scope"));
        assert!(text.contains("active scopes: [layout, read]"));

        // 3. build_socket_request for overlay tools
        let open_args = json!({
            "file": "/tmp/doc.html",
            "split": "right",
            "type": "html"
        });
        let req_open = server.build_socket_request("tako_overlay_open", &open_args).unwrap();
        assert_eq!(req_open["cmd"], "overlay");
        assert_eq!(req_open["args"]["subcommand"], "open");
        assert_eq!(req_open["args"]["file"], "/tmp/doc.html");
        assert_eq!(req_open["args"]["split"], "right");
        assert_eq!(req_open["args"]["type"], "html");

        let close_args = json!({});
        let req_close = server.build_socket_request("tako_overlay_close", &close_args).unwrap();
        assert_eq!(req_close["cmd"], "overlay");
        assert_eq!(req_close["args"]["subcommand"], "close");

        let status_args = json!({});
        let req_status = server.build_socket_request("tako_overlay_status", &status_args).unwrap();
        assert_eq!(req_status["cmd"], "overlay");
        assert_eq!(req_status["args"]["subcommand"], "status");
    }

    #[test]
    fn test_mcp_overlay_split_requires_layout() {
        let overlay_only = Capabilities::parse("overlay").unwrap();
        let server_overlay = McpServer::new("/tmp/test.sock".into(), overlay_only, Some("pane-1".into()));

        // 1. Overlay-only can open overlay without split (passes capability check, fails on test socket)
        let open_no_split = json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {
                "name": "tako_overlay_open",
                "arguments": {
                    "file": "/tmp/test.md"
                }
            }
        })
        .to_string();

        let resp1 = server_overlay.handle_message(&open_no_split).expect("response");
        assert_eq!(resp1["result"]["isError"], true);
        let text1 = resp1["result"]["content"][0]["text"].as_str().unwrap();
        assert!(!text1.contains("refusal:"));
        assert!(text1.contains("Tako socket error:"));

        // 2. Overlay-only is refused when requesting split because layout capability is required
        let open_with_split = json!({
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": {
                "name": "tako_overlay_open",
                "arguments": {
                    "file": "/tmp/test.md",
                    "split": "right"
                }
            }
        })
        .to_string();

        let resp2 = server_overlay.handle_message(&open_with_split).expect("response");
        assert_eq!(resp2["result"]["isError"], true);
        let text2 = resp2["result"]["content"][0]["text"].as_str().unwrap();
        assert!(text2.contains("refusal: tool 'tako_overlay_open' requires 'layout' capability scope"));
        assert!(text2.contains("active scopes: [overlay]"));

        // 3. Server with both overlay and layout accepts open with split (passes capability check, fails on test socket)
        let both_caps = Capabilities::parse("overlay,layout").unwrap();
        let server_both = McpServer::new("/tmp/test.sock".into(), both_caps, Some("pane-1".into()));
        let resp3 = server_both.handle_message(&open_with_split).expect("response");
        assert_eq!(resp3["result"]["isError"], true);
        let text3 = resp3["result"]["content"][0]["text"].as_str().unwrap();
        assert!(!text3.contains("refusal:"));
        assert!(text3.contains("Tako socket error:"));
    }

    #[test]
    fn test_mcp_text_and_screenshot() {
        let tools = all_tools();
        let tool_text = tools.iter().find(|t| t.name == "tako_text").expect("tako_text tool");
        let tool_ss = tools.iter().find(|t| t.name == "tako_screenshot").expect("tako_screenshot tool");
        assert_eq!(tool_text.required_scopes, &[CapabilityScope::Read]);
        assert_eq!(tool_ss.required_scopes, &[CapabilityScope::Read]);

        // 1. Refusal with non-read scope
        let signal_only = Capabilities::parse("signal").unwrap();
        let server_signal = McpServer::new("/tmp/test.sock".into(), signal_only, Some("pane-1".into()));

        let text_call = json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {
                "name": "tako_text",
                "arguments": {
                    "lines": 10,
                    "styled": true
                }
            }
        }).to_string();
        let resp_text = server_signal.handle_message(&text_call).expect("response");
        assert_eq!(resp_text["result"]["isError"], true);
        let err_text = resp_text["result"]["content"][0]["text"].as_str().unwrap();
        assert!(err_text.contains("refusal: tool 'tako_text' requires 'read' capability scope"));

        let ss_call = json!({
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": {
                "name": "tako_screenshot",
                "arguments": {}
            }
        }).to_string();
        let resp_ss = server_signal.handle_message(&ss_call).expect("response");
        assert_eq!(resp_ss["result"]["isError"], true);
        let err_ss = resp_ss["result"]["content"][0]["text"].as_str().unwrap();
        assert!(err_ss.contains("refusal: tool 'tako_screenshot' requires 'read' capability scope"));

        // 2. build_socket_request
        let read_caps = Capabilities::parse("read").unwrap();
        let server_read = McpServer::new("/tmp/test.sock".into(), read_caps, Some("pane-1".into()));

        let req_text = server_read.build_socket_request("tako_text", &json!({"lines": 25, "styled": true})).unwrap();
        assert_eq!(req_text["cmd"], "text");
        assert_eq!(req_text["args"]["lines"], 25);
        assert_eq!(req_text["args"]["styled"], true);
        assert_eq!(req_text["args"]["target"], "pane-1");

        let req_ss = server_read.build_socket_request("tako_screenshot", &json!({"target": "custom-pane"})).unwrap();
        assert_eq!(req_ss["cmd"], "screenshot");
        assert_eq!(req_ss["args"]["target"], "custom-pane");

        // 3. format_answer
        let answer_text = json!({
            "ok": true,
            "result": {
                "text": "\u{1b}[38;2;255;0;0mHello\u{1b}[0m"
            }
        });
        let fmt_text = server_read.format_answer("tako_text", &answer_text);
        assert_eq!(fmt_text["isError"], false);
        assert_eq!(fmt_text["content"][0]["text"], "\u{1b}[38;2;255;0;0mHello\u{1b}[0m");

        let answer_ss = json!({
            "ok": true,
            "result": {
                "id": "pane-1",
                "width": 640,
                "height": 480,
                "format": "png",
                "data": "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVR4nGNiAAAABgADNjd8qAAAAABJRU5ErkJggg=="
            }
        });
        let fmt_ss = server_read.format_answer("tako_screenshot", &answer_ss);
        assert_eq!(fmt_ss["isError"], false);
        assert_eq!(fmt_ss["content"][0]["type"], "image");
        assert_eq!(fmt_ss["content"][0]["data"], "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVR4nGNiAAAABgADNjd8qAAAAABJRU5ErkJggg==");
        assert_eq!(fmt_ss["content"][0]["mimeType"], "image/png");
        assert!(fmt_ss["content"][1]["text"].as_str().unwrap().contains("640x480 png"));
    }

    #[test]
    fn test_mcp_review_tools_scopes_and_requests() {
        let tools = all_tools();
        let open_tool = tools.iter().find(|t| t.name == "tako_review_open").expect("open tool");
        let close_tool = tools.iter().find(|t| t.name == "tako_review_close").expect("close tool");
        let status_tool = tools.iter().find(|t| t.name == "tako_review_status").expect("status tool");
        let diff_tool = tools.iter().find(|t| t.name == "tako_review_diff").expect("diff tool");
        let comment_tool = tools.iter().find(|t| t.name == "tako_review_comment").expect("comment tool");
        let send_tool = tools.iter().find(|t| t.name == "tako_review_send").expect("send tool");

        assert_eq!(open_tool.required_scopes, &[CapabilityScope::Read]);
        assert_eq!(close_tool.required_scopes, &[CapabilityScope::Read]);
        assert_eq!(status_tool.required_scopes, &[CapabilityScope::Read]);
        assert_eq!(diff_tool.required_scopes, &[CapabilityScope::Read]);
        assert_eq!(comment_tool.required_scopes, &[CapabilityScope::Read]);
        assert_eq!(send_tool.required_scopes, &[CapabilityScope::Input]);

        // 1. Capability checks: Read-only server vs Input-only server
        let read_server = McpServer::new(
            "/tmp/test.sock".into(),
            Capabilities::parse("read").unwrap(),
            Some("pane-rev".into()),
        );

        // Read server can call tako_review_diff (fails at socket, not refused)
        let diff_call = json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {
                "name": "tako_review_diff",
                "arguments": { "file": "src/main.rs" }
            }
        }).to_string();
        let resp_diff = read_server.handle_message(&diff_call).expect("response");
        assert_eq!(resp_diff["result"]["isError"], true);
        let err_diff = resp_diff["result"]["content"][0]["text"].as_str().unwrap();
        assert!(!err_diff.contains("refusal:"));
        assert!(err_diff.contains("Tako socket error:"));

        // Read server is refused on tako_review_send because it requires Input scope
        let send_call = json!({
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": {
                "name": "tako_review_send",
                "arguments": { "target_pane": "pane-agent-1" }
            }
        }).to_string();
        let resp_send = read_server.handle_message(&send_call).expect("response");
        assert_eq!(resp_send["result"]["isError"], true);
        let err_send = resp_send["result"]["content"][0]["text"].as_str().unwrap();
        assert!(err_send.contains("refusal: tool 'tako_review_send' requires 'input' capability scope"));
        assert!(err_send.contains("active scopes: [read]"));

        // 2. build_socket_request tests
        let req_open = read_server
            .build_socket_request(
                "tako_review_open",
                &json!({
                    "task": "task-feature-x",
                    "base": "origin/main",
                    "target_pane": "pane-dest-99"
                }),
            )
            .unwrap();
        assert_eq!(req_open["cmd"], "review");
        assert_eq!(req_open["args"]["subcommand"], "open");
        assert_eq!(req_open["args"]["task"], "task-feature-x");
        assert_eq!(req_open["args"]["base"], "origin/main");
        assert_eq!(req_open["args"]["target_pane"], "pane-dest-99");
        assert_eq!(req_open["args"]["target"], "pane-rev");

        let req_files = read_server
            .build_socket_request(
                "tako_review_diff",
                &json!({ "files_only": true }),
            )
            .unwrap();
        assert_eq!(req_files["cmd"], "review");
        assert_eq!(req_files["args"]["subcommand"], "files");

        let req_comment_add = read_server
            .build_socket_request(
                "tako_review_comment",
                &json!({
                    "action": "add",
                    "file": "src/main.rs",
                    "line": 42,
                    "text": "Check bounds here"
                }),
            )
            .unwrap();
        assert_eq!(req_comment_add["cmd"], "review");
        assert_eq!(req_comment_add["args"]["subcommand"], "comment");
        assert_eq!(req_comment_add["args"]["action"], "add");
        assert_eq!(req_comment_add["args"]["file"], "src/main.rs");
        assert_eq!(req_comment_add["args"]["line"], 42);
        assert_eq!(req_comment_add["args"]["text"], "Check bounds here");

        let req_comment_rm = read_server
            .build_socket_request(
                "tako_review_comment",
                &json!({
                    "action": "remove",
                    "comment_id": "c-uuid-123"
                }),
            )
            .unwrap();
        assert_eq!(req_comment_rm["args"]["action"], "remove");
        assert_eq!(req_comment_rm["args"]["comment_id"], "c-uuid-123");

        let req_send = read_server
            .build_socket_request(
                "tako_review_send",
                &json!({ "target_pane": "pane-agent-1" }),
            )
            .unwrap();
        assert_eq!(req_send["cmd"], "review");
        assert_eq!(req_send["args"]["subcommand"], "send");
        assert_eq!(req_send["args"]["target_pane"], "pane-agent-1");
    }
}

