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
use serde_json::{json, Value};

#[test]
fn ask_command_parses_options_and_renders_json() {
    // Confirmation prompt
    let opts = parse(&args(&[
        "ask",
        "Deploy to production?",
        "--confirm",
        "--confirm-text",
        "Ship it",
        "--cancel-text",
        "Abort",
        "--title",
        "Deploy Prompt",
        "--target",
        "pane-1",
    ]))
    .unwrap();
    assert_eq!(opts.cmd, "ask");
    assert_eq!(opts.args["message"], "Deploy to production?");
    assert_eq!(opts.args["confirm"], true);
    assert_eq!(opts.args["confirm_text"], "Ship it");
    assert_eq!(opts.args["cancel_text"], "Abort");
    assert_eq!(opts.args["title"], "Deploy Prompt");
    assert_eq!(opts.args["target"], "pane-1");

    // Choice prompt with multiple flags
    let opts = parse(&args(&[
        "ask",
        "Select environment",
        "--choice",
        "dev",
        "--choice",
        "staging",
        "--choices",
        "prod,canary",
        "--timeout",
        "30s",
        "--default",
        "dev",
    ]))
    .unwrap();
    assert_eq!(opts.cmd, "ask");
    assert_eq!(opts.args["message"], "Select environment");
    assert_eq!(
        opts.args["choices"],
        json!(["dev", "staging", "prod", "canary"])
    );
    assert_eq!(opts.args["timeout"], 30.0);
    assert_eq!(opts.args["default"], "dev");
    assert_eq!(
        answer_limit(&opts),
        std::time::Duration::from_secs(30) + socket::TIMEOUT
    );

    // Text prompt
    let opts = parse(&args(&[
        "ask",
        "Enter commit message",
        "--text",
        "--placeholder",
        "feat: ...",
        "--timeout",
        "1m",
    ]))
    .unwrap();
    assert_eq!(opts.cmd, "ask");
    assert_eq!(opts.args["message"], "Enter commit message");
    assert_eq!(opts.args["placeholder"], "feat: ...");
    assert_eq!(opts.args["timeout"], 60.0);

    // Rendering prints JSON
    let result = json!({
        "answer": "Ship it",
        "confirmed": true,
        "type": "confirm",
        "id": "prompt-123"
    });
    let rendered = render("ask", &result);
    let parsed_rendered: Value = serde_json::from_str(&rendered).unwrap();
    assert_eq!(parsed_rendered["answer"], "Ship it");
    assert_eq!(parsed_rendered["type"], "confirm");
    assert!(rendered.ends_with('\n'));

    // Errors
    assert!(parse(&args(&["ask"])).is_err());
    assert!(parse(&args(&["ask", "one", "two"])).is_err());
}

#[test]
fn workspace_subcommands_and_options_parsed_and_rendered() {
    // Defaults to list
    let opts = parse(&args(&["workspace"])).unwrap();
    assert_eq!(opts.cmd, "workspace");
    assert_eq!(opts.args["action"], "list");

    let opts = parse(&args(&["workspace", "list"])).unwrap();
    assert_eq!(opts.cmd, "workspace");
    assert_eq!(opts.args["action"], "list");

    // Current
    let opts = parse(&args(&["workspace", "current"])).unwrap();
    assert_eq!(opts.args["action"], "current");

    // Switch
    let opts = parse(&args(&["workspace", "switch", "tako"])).unwrap();
    assert_eq!(opts.args["action"], "switch");
    assert_eq!(opts.args["name"], "tako");

    // Direct switch shorthand
    let opts = parse(&args(&["workspace", "tako"])).unwrap();
    assert_eq!(opts.args["action"], "switch");
    assert_eq!(opts.args["name"], "tako");

    // Create
    let opts = parse(&args(&[
        "workspace",
        "create",
        "frontend",
        "--root",
        "/src/frontend",
        "--color",
        "orange",
        "--icon",
        "globe",
    ]))
    .unwrap();
    assert_eq!(opts.args["action"], "create");
    assert_eq!(opts.args["name"], "frontend");
    assert_eq!(opts.args["root"], "/src/frontend");
    assert_eq!(opts.args["color"], "orange");
    assert_eq!(opts.args["icon"], "globe");

    // Delete
    let opts = parse(&args(&["workspace", "delete", "old-ws"])).unwrap();
    assert_eq!(opts.args["action"], "delete");
    assert_eq!(opts.args["name"], "old-ws");

    // Assign
    let opts = parse(&args(&[
        "workspace",
        "assign",
        "tab-xyz",
        "--workspace",
        "backend",
    ]))
    .unwrap();
    assert_eq!(opts.args["action"], "assign");
    assert_eq!(opts.args["tab"], "tab-xyz");
    assert_eq!(opts.args["workspace"], "backend");

    let opts = parse(&args(&["workspace", "assign", "--workspace", "backend"])).unwrap();
    assert_eq!(opts.args["action"], "assign");
    assert_eq!(opts.args["workspace"], "backend");
    assert!(opts.args.get("tab").is_none());

    // Render list
    let list_json = json!({
        "workspaces": [
            {
                "name": "Default",
                "is_active": true,
                "tabs": ["t1", "t2"],
                "attention_count": 0
            },
            {
                "name": "Backend",
                "is_active": false,
                "tabs": ["t3"],
                "attention_count": 2,
                "root_directory": "/Users/test/backend"
            }
        ]
    });
    let rendered = render("workspace", &list_json);
    assert!(rendered.contains("* Default (2 tabs)"));
    assert!(rendered.contains("Backend (1 tabs) [2 unread]  /Users/test/backend"));

    // Render current
    let cur_json = json!({
        "name": "Tako",
        "tabs": ["t1"],
        "attention_count": 0,
        "root_directory": "/Users/test/tako"
    });
    let rendered_cur = render("workspace", &cur_json);
    assert!(rendered_cur.contains("Tako (1 tabs)"));
    assert!(rendered_cur.contains("/Users/test/tako"));

    // Render deleted
    let del_json = json!({"deleted": "OldWs"});
    assert_eq!(render("workspace", &del_json), "deleted OldWs\n");

    // Render assign
    let assign_json = json!({"tab": "tab-1", "workspace": "Backend"});
    assert_eq!(
        render("workspace", &assign_json),
        "assigned tab-1 to Backend\n"
    );

    // Errors
    assert!(parse(&args(&["workspace", "create"])).is_err());
    assert!(parse(&args(&["workspace", "delete"])).is_err());
    assert!(parse(&args(&["workspace", "assign"])).is_err());
}

#[test]
fn layout_subcommands_and_options_parsed_and_rendered() {
    // Layout save
    let opts = parse(&args(&["layout", "save", "my-layout.json"])).unwrap();
    assert_eq!(opts.cmd, "layout");
    assert_eq!(opts.args["action"], "save");
    assert!(
        opts.args["path"]
            .as_str()
            .unwrap()
            .ends_with("my-layout.json")
    );

    // Create temporary layout file for apply/approve/status tests
    let temp_dir = std::env::temp_dir();
    let temp_file = temp_dir.join(format!("tako_test_layout_{}.json", std::process::id()));
    let dummy_json =
        r#"{"version":1,"windows":[{"tabs":[{"root":{"cwd":"/tmp","command":["ls"]}}]}]}"#;
    std::fs::write(&temp_file, dummy_json).unwrap();
    let temp_path = temp_file.to_str().unwrap();

    // Layout apply
    let opts = parse(&args(&["layout", "apply", temp_path])).unwrap();
    assert_eq!(opts.cmd, "layout");
    assert_eq!(opts.args["action"], "apply");
    assert_eq!(opts.args["path"], temp_path);
    assert_eq!(opts.args["content"], dummy_json);
    assert_eq!(opts.args.get("approve"), None);

    // Layout apply with --approve
    let opts = parse(&args(&["layout", "apply", "--approve", temp_path])).unwrap();
    assert_eq!(opts.args["approve"], true);

    // Layout approve
    let opts = parse(&args(&["layout", "approve", temp_path])).unwrap();
    assert_eq!(opts.args["action"], "approve");
    assert_eq!(opts.args["path"], temp_path);
    assert_eq!(opts.args["content"], dummy_json);

    // Layout status
    let opts = parse(&args(&["layout", "status", temp_path])).unwrap();
    assert_eq!(opts.args["action"], "status");
    assert_eq!(opts.args["path"], temp_path);

    // Render save
    let save_json = json!({
        "saved": true,
        "path": "my-layout.json",
        "tabs": 2.0,
        "panes": 4.0
    });
    assert_eq!(
        render("layout", &save_json),
        "Saved layout to my-layout.json (2 tabs, 4 panes)\n"
    );

    // Render apply (trusted / programs started)
    let apply_trusted_json = json!({
        "applied": true,
        "path": "my-layout.json",
        "tabs": 1.0,
        "panes": 2.0,
        "programs_started": 2.0,
        "programs_suppressed": 0.0,
        "trusted": true
    });
    assert_eq!(
        render("layout", &apply_trusted_json),
        "Applied layout from my-layout.json (1 tab, 2 panes), 2 programs started\n"
    );

    // Render apply (untrusted / programs suppressed)
    let apply_untrusted_json = json!({
        "applied": true,
        "path": "my-layout.json",
        "tabs": 1.0,
        "panes": 2.0,
        "programs_started": 0.0,
        "programs_suppressed": 2.0,
        "trusted": false
    });
    assert_eq!(
        render("layout", &apply_untrusted_json),
        "Applied layout from my-layout.json (1 tab, 2 panes), 2 programs suppressed (untrusted layout)\n"
    );

    // Render approve
    let approve_json = json!({
        "approved": true,
        "path": "/path/to/layout.json",
        "sha256": "abcdef1234567890abcdef"
    });
    assert_eq!(
        render("layout", &approve_json),
        "Approved layout /path/to/layout.json (sha256: abcdef123456)\n"
    );

    // Render status
    let status_json = json!({
        "path": "/path/to/layout.json",
        "status": "trusted",
        "sha256": "abcdef1234567890abcdef"
    });
    assert_eq!(
        render("layout", &status_json),
        "Layout /path/to/layout.json: trusted (sha256: abcdef123456)\n"
    );

    // Clean up temp file
    let _ = std::fs::remove_file(temp_file);

    // Errors
    assert!(parse(&args(&["layout"])).is_err());
    assert!(parse(&args(&["layout", "save"])).is_err());
    assert!(parse(&args(&["layout", "apply"])).is_err());
    assert!(parse(&args(&["layout", "apply", "/nonexistent/file/path.json"])).is_err());
    assert!(parse(&args(&["layout", "approve"])).is_err());
    assert!(parse(&args(&["layout", "status"])).is_err());
}
