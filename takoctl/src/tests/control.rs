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
fn control_capabilities_and_scopes_parsing() {
    // 1. Parsing --scope and --client
    let opts1 = parse(&[
        "text".into(),
        "--scope".into(),
        "read,input".into(),
        "--client".into(),
        "agent-alpha".into(),
    ])
    .unwrap();
    assert_eq!(opts1.client.as_deref(), Some("agent-alpha"));
    assert_eq!(opts1.scopes, Some(vec!["read".into(), "input".into()]));
    let req1 = request(&opts1, None);
    assert_eq!(req1["client"], "agent-alpha");
    assert_eq!(req1["scopes"], json!(["read", "input"]));

    // 2. Parsing --scopes with spaces and uppercase
    let opts2 = parse(&[
        "notify".into(),
        "hello".into(),
        "--scopes".into(),
        "Signal, Layout".into(),
    ])
    .unwrap();
    assert_eq!(opts2.scopes, Some(vec!["signal".into(), "layout".into()]));

    // 3. Unknown scope fails
    let bad_scope = parse(&[
        "notify".into(),
        "hello".into(),
        "--scope".into(),
        "invalid_scope".into(),
    ]);
    assert!(bad_scope.is_err());
    assert!(bad_scope
        .unwrap_err()
        .contains("unknown capability scope 'invalid_scope'"));

    // 4. Input automation subcommands
    let allow_opts = parse(&["input".into(), "allow-automation".into()]).unwrap();
    assert_eq!(allow_opts.args["subcommand"], "allow-automation");

    let disallow_opts = parse(&["input".into(), "disallow-automation".into()]).unwrap();
    assert_eq!(disallow_opts.args["subcommand"], "disallow-automation");

    let confirm_opts = parse(&["input".into(), "confirm-automation".into()]).unwrap();
    assert_eq!(confirm_opts.args["subcommand"], "confirm-automation");

    // 5. Input report formatting
    let allow_report = input_report(&json!({
        "id": "pane-1",
        "automation_may_type": true
    }));
    assert_eq!(allow_report, "Automation typing allowed for pane pane-1.\n");

    let disallow_report = input_report(&json!({
        "id": "pane-1",
        "automation_may_type": false
    }));
    assert_eq!(
        disallow_report,
        "Automation typing disallowed for pane pane-1.\n"
    );

    let confirm_report = input_report(&json!({
        "id": "pane-1",
        "confirmed": true
    }));
    assert_eq!(
        confirm_report,
        "One-time automation typing confirmed for pane pane-1.\n"
    );

    let status_report = input_report(&json!({
        "id": "pane-1",
        "locked": false,
        "owner": "human",
        "automation_may_type": true,
        "creator_client": "agent-alpha"
    }));
    assert!(status_report.contains("Pane pane-1: unlocked (owner: human)"));
    assert!(status_report.contains("Automation may type: yes"));
    assert!(status_report.contains("Creator client: agent-alpha"));

    // 6. Token parsing and grant subcommands
    let token_opts = parse(&[
        "text".into(),
        "--token".into(),
        "secret_token_123".into(),
        "--scope".into(),
        "read,approval".into(),
    ])
    .unwrap();
    assert_eq!(token_opts.token.as_deref(), Some("secret_token_123"));
    assert_eq!(token_opts.scopes, Some(vec!["read".into(), "approval".into()]));
    let req_tok = request(&token_opts, None);
    assert_eq!(req_tok["token"], "secret_token_123");
    assert_eq!(req_tok["scopes"], json!(["read", "approval"]));

    let grant_create = parse(&[
        "grant".into(),
        "create".into(),
        "--client".into(),
        "subagent-2".into(),
        "--scope".into(),
        "signal".into(),
    ])
    .unwrap();
    assert_eq!(grant_create.args["subcommand"], "create");
    assert_eq!(grant_create.args["client"], "subagent-2");
    assert_eq!(grant_create.args["scopes"], json!(["signal"]));

    let grant_revoke = parse(&[
        "grant".into(),
        "revoke".into(),
        "token_to_remove".into(),
    ])
    .unwrap();
    assert_eq!(grant_revoke.args["subcommand"], "revoke");
    assert_eq!(grant_revoke.args["token"], "token_to_remove");

    let grant_list = parse(&["grant".into(), "list".into()]).unwrap();
    assert_eq!(grant_list.args["subcommand"], "list");

    let rep_create = grant_report(&json!({
        "token": "tok_xyz",
        "client": "subagent-2",
        "scopes": ["signal"]
    }));
    assert!(rep_create.contains("token: tok_xyz"));
    assert!(rep_create.contains("client: subagent-2"));
    assert!(rep_create.contains("scopes: [signal]"));

    let grant_req_default = parse(&["grant".into(), "request".into()]).unwrap();
    assert_eq!(grant_req_default.args["subcommand"], "request");
    assert_eq!(grant_req_default.args["client"], "takoctl");

    let grant_req_custom = parse(&[
        "grant".into(),
        "request".into(),
        "--client".into(),
        "my-agent".into(),
        "--scope".into(),
        "read,layout".into(),
        "--desc".into(),
        "Test description".into(),
    ])
    .unwrap();
    assert_eq!(grant_req_custom.args["subcommand"], "request");
    assert_eq!(grant_req_custom.args["client"], "my-agent");
    assert_eq!(grant_req_custom.args["scopes"], json!(["read", "layout"]));
    assert_eq!(grant_req_custom.args["description"], "Test description");

    let rep_req = grant_report(&json!({
        "token": "tok_bootstrap",
        "client": "my-agent",
        "scopes": ["layout", "read"]
    }));
    assert!(rep_req.contains("token: tok_bootstrap"));
    assert!(rep_req.contains("client: my-agent"));
    assert!(rep_req.contains("scopes: [layout, read]"));
}
