/*
 * tako — Terminal emulator core library
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::super::*;
use serde_json::json;

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
