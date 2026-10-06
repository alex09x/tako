/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use std::io::{self, BufRead, Write};
use std::time::Duration;

use serde_json::{Value, json};

use super::capabilities::{Capabilities, CapabilityScope};
use super::request;
use super::response;
use super::tools::all_tools;
use crate::socket::{self, Failure};

pub struct McpServer {
    pub socket_path: String,
    pub capabilities: Capabilities,
    pub surface_id: Option<String>,
    pub token: Option<String>,
}

impl McpServer {
    pub fn new(socket_path: String, capabilities: Capabilities, surface_id: Option<String>) -> Self {
        Self {
            socket_path,
            capabilities,
            surface_id,
            token: None,
        }
    }

    pub fn with_token(mut self, token: Option<String>) -> Self {
        self.token = token;
        self
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
            "notifications/initialized" => None,
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

    pub fn determine_timeout(&self, name: &str, args: &Value) -> Duration {
        request::determine_timeout(name, args)
    }

    pub fn build_socket_request(&self, name: &str, args: &Value) -> Result<Value, String> {
        request::build_socket_request(
            &self.capabilities,
            self.surface_id.as_deref(),
            self.token.as_deref(),
            name,
            args,
        )
    }

    pub fn format_answer(&self, name: &str, answer: &Value) -> Value {
        response::format_answer(name, answer)
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
