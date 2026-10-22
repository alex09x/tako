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
fn format_duration_handles_all_ranges() {
    assert_eq!(format_duration(0.0005), "<1ms");
    assert_eq!(format_duration(0.05), "50ms");
    assert_eq!(format_duration(0.999), "999ms");
    assert_eq!(format_duration(1.23), "1.2s");
    assert_eq!(format_duration(9.94), "9.9s");
    assert_eq!(format_duration(15.2), "15s");
    assert_eq!(format_duration(65.0), "1m 05s");
    assert_eq!(format_duration(125.0), "2m 05s");
}

#[test]
fn history_command_parsing_and_report() {
    let opts = parse(&[
        "history".into(),
        "git".into(),
        "--limit".into(),
        "20".into(),
    ])
    .unwrap();
    assert_eq!(opts.cmd, "history");
    assert_eq!(opts.args["query"], "git");
    assert_eq!(opts.args["limit"], 20);

    let history_val = json!({
        "entries": [
            {
                "command": "git commit -m \"feat\"",
                "cwd": "/Users/alex09x/tako",
                "exit_code": 0,
                "duration": 1.25
            },
            {
                "command": "cargo test\x1b[2J",
                "cwd": "/tmp\r",
                "exit_code": 1,
                "duration": 0.05
            }
        ]
    });

    let rep = render("history", &history_val);
    assert!(rep.contains("$ git commit -m \"feat\"   (/Users/alex09x/tako)   exit 0   (1.2s)"));
    assert!(rep.contains("$ cargo test^[[2J   (/tmp^M)   exit 1   (50ms)"));
    assert!(!rep.contains('\x1b'));
    assert!(!rep.contains('\r'));

    // Test limit validation bounds
    assert!(parse(&["history".into(), "--limit".into(), "-1".into()]).is_err());
    assert!(parse(&["history".into(), "--limit".into(), "10000".into()]).is_err());
    assert!(parse(&["history".into(), "--limit".into(), "abc".into()]).is_err());
    let valid_zero = parse(&["history".into(), "--limit".into(), "0".into()]).unwrap();
    assert_eq!(valid_zero.args["limit"], 0);
    let valid_max = parse(&["history".into(), "--limit".into(), "5000".into()]).unwrap();
    assert_eq!(valid_max.args["limit"], 5000);
}

#[test]
fn command_report_includes_duration() {
    let cmd_val = json!({
        "command": {
            "input": "echo hello",
            "cwd": "/Users/alex09x",
            "running": false,
            "exitCode": 0,
            "ref": "1@1",
            "duration": 0.42
        },
        "output": "hello\n"
    });
    let rep = command_report(&cmd_val);
    assert!(rep.contains("$ echo hello   (/Users/alex09x)   exit 0   (420ms)   [1@1]"));
    assert!(rep.contains("hello\n"));
}

#[test]
fn triggers_cli_and_report_tests() {
    // 1. Parsing commands
    let list_opts = parse(&["triggers".into(), "list".into()]).unwrap();
    assert_eq!(list_opts.args["subcommand"], "list");

    let add_opts = parse(&[
        "triggers".into(),
        "add".into(),
        "error:.*".into(),
        "--action".into(),
        "both".into(),
        "--color".into(),
        "red".into(),
        "--style".into(),
        "box".into(),
        "--title".into(),
        "Build Error".into(),
        "--all-focus".into(),
    ]).unwrap();
    assert_eq!(add_opts.args["subcommand"], "add");
    assert_eq!(add_opts.args["pattern"], "error:.*");
    assert_eq!(add_opts.args["action"], "both");
    assert_eq!(add_opts.args["color"], "red");
    assert_eq!(add_opts.args["style"], "box");
    assert_eq!(add_opts.args["title"], "Build Error");
    assert_eq!(add_opts.args["only_unfocused"], false);

    let rm_opts = parse(&["triggers".into(), "remove".into(), "abc-123".into()]).unwrap();
    assert_eq!(rm_opts.args["subcommand"], "remove");
    assert_eq!(rm_opts.args["id"], "abc-123");

    let clear_opts = parse(&["triggers".into(), "clear".into()]).unwrap();
    assert_eq!(clear_opts.args["subcommand"], "clear");

    // 2. Render report with control sanitization
    let list_val = json!({
        "triggers": [
            {
                "id": "1111-2222",
                "pattern": "error:\x1b[31m.*",
                "action": "both",
                "color": "red",
                "style": "box",
                "is_dynamic": true,
                "title": "Alert\r\n"
            },
            {
                "id": "3333-4444",
                "pattern": "warning:.*",
                "action": "highlight",
                "color": "yellow",
                "style": "underline",
                "is_dynamic": false
            }
        ]
    });

    let rep = render("triggers", &list_val);
    assert!(rep.contains("1111-2222"));
    assert!(rep.contains("\"error:^[[31m.*\""));
    assert!(rep.contains("[dynamic]"));
    assert!(rep.contains("title=\"Alert^M\n\""));
    assert!(!rep.contains('\x1b'));
    assert!(!rep.contains('\r'));
    assert!(rep.contains("3333-4444"));
    assert!(rep.contains("[config]"));
}

#[test]
fn control_client_name_and_input_report() {
    let opts1 = parse(&[
        "text".into(),
        "--client".into(),
        "agent-alpha".into(),
    ])
    .unwrap();
    assert_eq!(opts1.client.as_deref(), Some("agent-alpha"));
    let req1 = request(&opts1, None);
    assert_eq!(req1["client"], "agent-alpha");
    assert!(req1.get("scopes").is_none() && req1.get("token").is_none());

    let status_report = input_report(&json!({
        "id": "pane-1",
        "locked": false,
        "owner": "human",
        "creator_client": "agent-alpha"
    }));
    assert!(status_report.contains("Pane pane-1: unlocked (owner: human)"));
    assert!(status_report.contains("Creator client: agent-alpha"));
}
