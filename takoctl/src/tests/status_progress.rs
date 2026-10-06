/*
 * tako — Terminal emulator core library
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::args;
use super::super::*;
use serde_json::json;

#[test]
fn status_command_parses_get_set_clear_and_options() {
    // get (default)
    let opts = parse(&args(&["status"])).unwrap();
    assert_eq!(
        request(&opts, None),
        json!({"cmd": "status", "args": {"action": "get"}})
    );

    // get (explicit)
    let opts = parse(&args(&["status", "get"])).unwrap();
    assert_eq!(
        request(&opts, None),
        json!({"cmd": "status", "args": {"action": "get"}})
    );

    // set
    let opts = parse(&args(&[
        "status",
        "set",
        "working",
        "--text",
        "compiling",
        "--ttl",
        "10m",
    ]))
    .unwrap();
    assert_eq!(
        request(&opts, None),
        json!({
            "cmd": "status",
            "args": {
                "action": "set",
                "status": "working",
                "text": "compiling",
                "ttl": 600.0,
            }
        })
    );

    // clear
    let opts = parse(&args(&["status", "clear"])).unwrap();
    assert_eq!(
        request(&opts, None),
        json!({"cmd": "status", "args": {"action": "clear"}})
    );

    // errors
    assert!(parse(&args(&["status", "set"])).is_err());
    assert!(parse(&args(&["status", "unknown_action"])).is_err());
    assert!(parse(&args(&["status", "--ttl", "invalid"])).is_err());
}

#[test]
fn status_report_renders_human_output() {
    let result = json!({
        "status": "working",
        "text": "compiling",
        "ttl": 298.5,
        "unread": true,
    });
    assert_eq!(
        status_report(&result),
        "working (compiling) [TTL: 4m 58s] [unread]\n"
    );

    let simple = json!({
        "status": "idle",
        "unread": false,
    });
    assert_eq!(status_report(&simple), "idle\n");
}

#[test]
fn progress_command_parses_get_set_error_pause_indeterminate_clear() {
    // get (default)
    let opts = parse(&args(&["progress"])).unwrap();
    assert_eq!(
        request(&opts, None),
        json!({"cmd": "progress", "args": {"action": "get"}})
    );

    // get (explicit)
    let opts = parse(&args(&["progress", "get"])).unwrap();
    assert_eq!(
        request(&opts, None),
        json!({"cmd": "progress", "args": {"action": "get"}})
    );

    // number directly (e.g. 45)
    let opts = parse(&args(&["progress", "45"])).unwrap();
    assert_eq!(
        request(&opts, None),
        json!({"cmd": "progress", "args": {"action": "set", "value": 45}})
    );

    // set / normal with value
    let opts = parse(&args(&["progress", "set", "60"])).unwrap();
    assert_eq!(
        request(&opts, None),
        json!({"cmd": "progress", "args": {"action": "set", "value": 60}})
    );

    // indeterminate
    let opts = parse(&args(&["progress", "indeterminate"])).unwrap();
    assert_eq!(
        request(&opts, None),
        json!({"cmd": "progress", "args": {"action": "indeterminate"}})
    );

    // error with and without value
    let opts = parse(&args(&["progress", "error"])).unwrap();
    assert_eq!(
        request(&opts, None),
        json!({"cmd": "progress", "args": {"action": "error"}})
    );

    let opts = parse(&args(&["progress", "error", "100"])).unwrap();
    assert_eq!(
        request(&opts, None),
        json!({"cmd": "progress", "args": {"action": "error", "value": 100}})
    );

    // pause with and without value
    let opts = parse(&args(&["progress", "pause"])).unwrap();
    assert_eq!(
        request(&opts, None),
        json!({"cmd": "progress", "args": {"action": "pause"}})
    );

    let opts = parse(&args(&["progress", "pause", "75"])).unwrap();
    assert_eq!(
        request(&opts, None),
        json!({"cmd": "progress", "args": {"action": "pause", "value": 75}})
    );

    // clear
    let opts = parse(&args(&["progress", "clear"])).unwrap();
    assert_eq!(
        request(&opts, None),
        json!({"cmd": "progress", "args": {"action": "clear"}})
    );

    // errors
    assert!(parse(&args(&["progress", "101"])).is_err());
    assert!(parse(&args(&["progress", "error", "150"])).is_err());
    assert!(parse(&args(&["progress", "unknown_state"])).is_err());
}

#[test]
fn progress_report_renders_human_output() {
    let normal = json!({
        "state": "normal",
        "progress": 42.0,
    });
    assert_eq!(progress_report(&normal), "normal (42%)\n");

    let err = json!({
        "state": "error",
        "progress": 99.0,
    });
    assert_eq!(progress_report(&err), "error (99%)\n");

    let indet = json!({
        "state": "indeterminate",
    });
    assert_eq!(progress_report(&indet), "indeterminate\n");

    let clear = json!({
        "state": "none",
    });
    assert_eq!(progress_report(&clear), "none\n");
}

#[test]
fn hooks_command_parses_list_status_install_uninstall_and_flags() {
    // list (default)
    let opts = parse(&args(&["hooks"])).unwrap();
    assert_eq!(opts.cmd, "hooks");
    assert_eq!(opts.args["action"], "list");

    // list (explicit)
    let opts = parse(&args(&["hooks", "list"])).unwrap();
    assert_eq!(opts.cmd, "hooks");
    assert_eq!(opts.args["action"], "list");

    // status all
    let opts = parse(&args(&["hooks", "status"])).unwrap();
    assert_eq!(opts.args["action"], "status");
    assert!(opts.args.get("agent").is_none());

    // status specific agent
    let opts = parse(&args(&["hooks", "status", "claude"])).unwrap();
    assert_eq!(opts.args["action"], "status");
    assert_eq!(opts.args["agent"], "claude");

    // install with flags
    let opts = parse(&args(&[
        "hooks",
        "install",
        "gemini",
        "--yes",
        "--diff-only",
        "--config",
        "/tmp/test.json",
    ]))
    .unwrap();
    assert_eq!(opts.args["action"], "install");
    assert_eq!(opts.args["agent"], "gemini");
    assert_eq!(opts.args["yes"], true);
    assert_eq!(opts.args["diff_only"], true);
    assert_eq!(opts.args["config"], "/tmp/test.json");

    // uninstall with -y
    let opts = parse(&args(&["hooks", "uninstall", "codex", "-y"])).unwrap();
    assert_eq!(opts.args["action"], "uninstall");
    assert_eq!(opts.args["agent"], "codex");
    assert_eq!(opts.args["yes"], true);

    // errors
    assert!(parse(&args(&["hooks", "install"])).is_err());
    assert!(parse(&args(&["hooks", "uninstall"])).is_err());
    assert!(parse(&args(&["hooks", "invalid_action"])).is_err());
}

#[test]
fn events_command_parses_filters_and_cursor() {
    let opts = parse(&args(&["events"])).unwrap();
    assert_eq!(opts.cmd, "events");
    assert!(opts.args.is_empty());

    let opts = parse(&args(&[
        "events",
        "--pane",
        "1234",
        "--tab",
        "5678",
        "--workspace",
        "my-ws",
        "--type",
        "command_start,command_end",
        "--cursor",
        "42",
        "--json",
    ]))
    .unwrap();
    assert_eq!(opts.cmd, "events");
    assert_eq!(opts.args["pane"], "1234");
    assert_eq!(opts.args["tab"], "5678");
    assert_eq!(opts.args["workspace"], "my-ws");
    assert_eq!(opts.args["type"], "command_start,command_end");
    assert_eq!(opts.args["cursor"], 42);
    assert!(opts.json);

    // Disallows positional arguments
    assert!(parse(&args(&["events", "unexpected"])).is_err());
    assert!(parse(&args(&["events", "--cursor", "not_a_number"])).is_err());
}
