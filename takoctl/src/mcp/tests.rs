/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::*;
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
