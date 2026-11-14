/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::super::*;
use serde_json::json;

fn server(scopes: &str) -> McpServer {
    McpServer::new(
        "/tmp/test.sock".into(),
        Capabilities::parse(scopes).unwrap(),
        Some("pane-1".into()),
    )
}

#[test]
fn pane_window_and_config_tools_build_the_cli_requests() {
    let s = server("all");
    let req = s
        .build_socket_request("tako_pane", &json!({"action": "set", "state": "float"}))
        .unwrap();
    assert_eq!(req["cmd"], "pane");
    assert_eq!(
        req["args"],
        json!({"action": "set", "state": "floating", "target": "pane-1"})
    );
    let req = s.build_socket_request("tako_pane", &json!({})).unwrap();
    assert_eq!(req["args"]["action"], "state");
    let req = s
        .build_socket_request("tako_pane", &json!({"action": "move", "select": false}))
        .unwrap();
    assert_eq!(
        (&req["args"]["window"], &req["args"]["select"]),
        (&json!("new"), &json!(false))
    );
    let req = s
        .build_socket_request("tako_pane", &json!({"action": "move", "into": "pane-2"}))
        .unwrap();
    assert_eq!(
        (
            &req["args"]["into"],
            &req["args"]["split"],
            req["args"].get("window")
        ),
        (&json!("pane-2"), &json!("right"), None)
    );
    assert!(
        s.build_socket_request(
            "tako_pane",
            &json!({"action": "move", "into": "pane-2", "split": "sideways"})
        )
        .is_err()
    );
    assert!(
        s.build_socket_request("tako_pane", &json!({"action": "set"}))
            .is_err()
    );
    assert!(
        s.build_socket_request("tako_pane", &json!({"action": "set", "state": "sideways"}))
            .is_err()
    );

    let req = s
        .build_socket_request(
            "tako_window",
            &json!({"action": "new", "state": "maximized",
                                                     "frame": [0, 0, 900, 600], "cwd": "/tmp"}),
        )
        .unwrap();
    assert_eq!(req["cmd"], "window");
    assert_eq!(req["args"]["frame"], json!([0.0, 0.0, 900.0, 600.0]));
    assert_eq!(req["args"]["state"], "maximized");
    let req = s
        .build_socket_request(
            "tako_window",
            &json!({"action": "fullscreen", "fullscreen": "on", "window": "window-2"}),
        )
        .unwrap();
    assert_eq!(
        (&req["args"]["value"], &req["args"]["window"]),
        (&json!("on"), &json!("window-2"))
    );
    assert!(
        s.build_socket_request(
            "tako_window",
            &json!({"action": "frame", "frame": [0, 0, 10, 10]})
        )
        .is_err()
    );

    let req = s
        .build_socket_request(
            "tako_config",
            &json!({"action": "set", "settings": {"font-size": "15"}}),
        )
        .unwrap();
    assert_eq!(req["cmd"], "config");
    assert_eq!(
        req["args"]["settings"],
        json!([{"key": "font-size", "value": "15"}])
    );
    let req = s
        .build_socket_request("tako_config", &json!({"action": "get", "keys": ["theme"]}))
        .unwrap();
    assert_eq!(req["args"]["keys"], json!(["theme"]));
}

#[test]
fn writing_settings_needs_the_config_scope_by_name() {
    let tools: Vec<_> = tools::all_tools()
        .into_iter()
        .map(|t| (t.name, t.required_scopes))
        .collect();
    let scopes = |name: &str| tools.iter().find(|(n, _)| *n == name).unwrap().1;
    assert_eq!(scopes("tako_pane"), &[CapabilityScope::Layout]);
    assert_eq!(scopes("tako_window"), &[CapabilityScope::Layout]);
    assert_eq!(scopes("tako_config"), &[CapabilityScope::Config]);

    let defaults = server("read,layout,signal,input");
    let call = json!({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                      "params": {"name": "tako_config", "arguments": {"action": "set", "settings": {"theme": "x"}}}})
        .to_string();
    let resp = defaults.handle_message(&call).expect("response");
    let text = resp["result"]["content"][0]["text"].as_str().unwrap();
    assert!(
        text.contains("requires 'config' capability scope"),
        "{text}"
    );
    assert!(
        Capabilities::parse("config")
            .unwrap()
            .contains(CapabilityScope::Config)
    );
    assert!(Capabilities::all().contains(CapabilityScope::Config));
    // What `takoctl mcp` grants without --capabilities: everything else, not config.
    let fallback = Capabilities::default_set();
    assert!(!fallback.contains(CapabilityScope::Config));
    for scope in [
        CapabilityScope::Read,
        CapabilityScope::Input,
        CapabilityScope::Layout,
        CapabilityScope::Signal,
        CapabilityScope::Overlay,
    ] {
        assert!(fallback.contains(scope), "{scope:?}");
    }
    let resp = McpServer::new("/tmp/test.sock".into(), fallback, None)
        .handle_message(&call)
        .expect("response");
    let text = resp["result"]["content"][0]["text"].as_str().unwrap();
    assert!(
        text.contains("requires 'config' capability scope"),
        "{text}"
    );
}

#[test]
fn pane_frames_and_shortcuts_reach_the_socket() {
    let s = server("all");
    let req = s
        .build_socket_request(
            "tako_pane",
            &json!({"action": "frame", "frame": [10, 20, 640, 400]}),
        )
        .unwrap();
    assert_eq!(req["args"]["frame"], json!([10.0, 20.0, 640.0, 400.0]));
    let req = s
        .build_socket_request(
            "tako_config",
            &json!({"action": "shortcut",
            "shortcut": {"op": "set", "name": "new_tab", "trigger": "cmd+t", "force": true}}),
        )
        .unwrap();
    assert_eq!(
        (
            &req["args"]["action"],
            &req["args"]["op"],
            &req["args"]["name"],
            &req["args"]["trigger"],
            &req["args"]["force"]
        ),
        (
            &json!("shortcut"),
            &json!("set"),
            &json!("new_tab"),
            &json!("cmd+t"),
            &json!(true)
        )
    );
}

#[test]
fn malformed_config_arguments_are_refused_before_anything_is_sent() {
    let s = server("all");
    let bad = [
        json!({"action": "set", "settings": {"font-size": "14", "title": 123}}),
        json!({"action": "set", "settings": {"title": null}}),
        json!({"action": "set", "settings": ["title=x"]}),
        json!({"action": "unset", "keys": ["theme", 7]}),
        json!({"action": "unset", "keys": "theme"}),
        json!({"action": "shortcut", "shortcut": {"op": "set", "name": "new_tab", "trigger": 5}}),
        json!({"action": "shortcut", "shortcut": {"op": "set", "name": "new_tab", "trigger": "cmd+t", "force": "yes"}}),
    ];
    for args in bad {
        assert!(
            s.build_socket_request("tako_config", &args).is_err(),
            "{args}"
        );
        let call = json!({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                          "params": {"name": "tako_config", "arguments": args}})
        .to_string();
        let resp = s.handle_message(&call).expect("response");
        let text = resp["result"]["content"][0]["text"].as_str().unwrap();
        assert_eq!(resp["result"]["isError"], true, "{text}");
        assert!(
            !text.contains("socket"),
            "refused before any exchange: {text}"
        );
    }
}
