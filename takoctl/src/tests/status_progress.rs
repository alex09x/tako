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

    // tab
    let opts = parse(&args(&["status", "tab"])).unwrap();
    assert_eq!(
        request(&opts, None),
        json!({"cmd": "status", "args": {"action": "tab"}})
    );

    // tab alias
    let opts = parse(&args(&["tab", "status"])).unwrap();
    assert_eq!(
        request(&opts, None),
        json!({"cmd": "status", "args": {"action": "tab"}})
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
        "tab": {
            "title": "agy ~",
            "index": 0,
            "selected": true,
            "dot": "ember",
            "color": "orange",
            "hex": "#f4581c",
            "state": "working",
            "style": "pill",
            "panes": 1
        }
    });
    assert_eq!(
        status_report(&result),
        "working (compiling) [TTL: 4m 58s] [unread]  [tab 0 \"agy ~\": dot=orange (ember), active]\n"
    );

    let simple = json!({
        "status": "idle",
        "unread": false,
    });
    assert_eq!(status_report(&simple), "idle\n");

    let tab_result = json!({
        "action": "tab",
        "status": "working",
        "text": "Thinking...",
        "tab": {
            "title": "agy ~",
            "index": 0,
            "selected": true,
            "dot": "ember",
            "color": "orange",
            "hex": "#f4581c",
            "state": "working",
            "style": "pill",
            "panes": 1,
            "progress": {
                "state": "indeterminate"
            }
        }
    });
    assert_eq!(
        tab_status_report(&tab_result),
        "tab 0 \"agy ~\" (active): dot orange (ember, #f4581c), state working (Thinking...) [progress: indeterminate]\n"
    );
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

#[test]
fn render_dispatches_status_tab_and_restored_commands() {
    use crate::reports::render;

    // status (normal)
    let status_val = json!({
        "status": "working",
        "tab": { "title": "t1", "dot": "ember", "color": "orange", "hex": "#f4581c", "state": "working" }
    });
    let status_out = render("status", &status_val);
    assert!(status_out.contains("working"));

    // status (tab)
    let tab_val = json!({
        "action": "tab",
        "title": "t1",
        "dot": "ember",
        "color": "orange",
        "hex": "#f4581c",
        "state": "working"
    });
    let tab_out = render("status", &tab_val);
    assert!(tab_out.contains("dot orange (ember, #f4581c)"));

    // progress
    let prog_val = json!({
        "state": "normal",
        "progress": 50
    });
    let prog_out = render("progress", &prog_val);
    assert!(prog_out.contains("50%"));

    // run with state (command_report)
    let cmd_val = json!({
        "state": "running",
        "command": {
            "ref": "c1",
            "running": true,
            "input": "cargo build"
        }
    });
    let run_out = render("run", &cmd_val);
    assert!(run_out.contains("cargo build"));

    // wait
    let wait_out = render("wait", &cmd_val);
    assert!(wait_out.contains("cargo build"));

    // last
    let last_out = render("last", &cmd_val);
    assert!(last_out.contains("cargo build"));
}

/// Sessions UI 5a in the terminal: a quiet program reads `live` with what its
/// tab shows, not `idle`, and a failure carries its exit code.
#[test]
fn a_quiet_program_reads_live_and_a_failure_its_exit_code() {
    let pane = |id: &str, status: &str, extra: serde_json::Value| {
        let mut p =
            json!({"id": id, "cwd": "/tmp", "title": id, "status": status, "focused": false});
        p.as_object_mut()
            .unwrap()
            .extend(extra.as_object().unwrap().clone());
        p
    };
    let tree = json!({"windows": [{"id": "w", "tabs": [
        {"id": "t1", "index": 1, "title": "ram11", "layout": {"pane": "ssh"},
         "panes": [pane("ssh", "idle", json!({"live": {"program": "ssh", "detail": "alex@ram11",
            "flowing": true, "linesPerSecond": 38, "rate": "38/s", "summary": "ssh alex@ram11 · 38/s"}}))]},
        {"id": "t2", "index": 2, "title": "log", "layout": {"pane": "tail"},
         "panes": [pane("tail", "idle", json!({"live": {"program": "tail", "flowing": false,
            "quiet": "quiet 4m", "summary": "tail · quiet 4m"}}))]},
        {"id": "t3", "index": 3, "title": "dev", "layout": {"pane": "npm"},
         "panes": [pane("npm", "error", json!({"exitCode": 1}))]},
        {"id": "t4", "index": 4, "title": "~", "layout": {"pane": "sh"},
         "panes": [pane("sh", "idle", json!({}))]},
    ]}]});
    let out = render("tree", &tree);
    assert!(out.contains("[live ssh alex@ram11 · 38/s]"), "{out}");
    assert!(out.contains("[live tail · quiet 4m]"), "{out}");
    assert!(out.contains("[error · exit 1]"), "{out}");
    assert!(out.contains("sh  /tmp  sh  [idle]"), "{out}");

    let status = json!({"status": "idle", "unread": false,
        "live": {"program": "tail", "flowing": false, "summary": "tail · quiet 4m"}});
    assert_eq!(status_report(&status), "live tail · quiet 4m\n");
    let failed = json!({"status": "error", "unread": true, "exitCode": 255});
    assert_eq!(status_report(&failed), "error · exit 255 [unread]\n");

    let tab = json!({"action": "tab", "status": "idle", "tab": {
        "title": "ram11", "index": 1, "selected": false, "dot": "dim", "color": "gray",
        "hex": "#8a7f76", "state": "live", "style": "pill", "panes": 1, "progress": null,
        "live": {"program": "ssh", "flowing": true, "rate": "38/s", "summary": "ssh · 38/s"}}});
    assert_eq!(
        tab_status_report(&tab),
        "tab 1 \"ram11\" (inactive): dot gray (dim, #8a7f76), state live · ssh · 38/s\n"
    );
}

/// `--pane` names the pane as `--target` does: `status tab --pane ID` used
/// to report the current pane's tab instead. `events` keeps it as a filter.
#[test]
fn pane_names_the_target_except_for_events() {
    let opts = parse(&args(&["status", "tab", "--pane", "fd5c"])).unwrap();
    assert_eq!(opts.args["target"], "fd5c");
    assert!(opts.args.get("pane").is_none());

    let err = parse(&args(&["status", "--pane", "a", "--target", "b"])).unwrap_err();
    assert!(err.contains("--pane and --target"), "{err}");

    let events = parse(&args(&["events", "--pane", "1234"])).unwrap();
    assert_eq!(events.args["pane"], "1234");
    assert!(events.args.get("target").is_none());
}
