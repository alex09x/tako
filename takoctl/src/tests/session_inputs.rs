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
fn test_resume_cli_parsing() {
    let opts = parse(&[
        "resume".into(),
        "set".into(),
        "--cwd".into(),
        "/Users/alex/project".into(),
        "--".into(),
        "claude".into(),
        "--resume".into(),
        "session-123".into(),
    ])
    .unwrap();
    assert_eq!(opts.cmd, "resume");
    assert_eq!(opts.args["action"], "set");
    assert_eq!(opts.args["cwd"], "/Users/alex/project");
    assert_eq!(
        opts.args["argv"],
        json!(["claude", "--resume", "session-123"])
    );

    let opts_show = parse(&["resume".into(), "show".into(), "pane-1".into()]).unwrap();
    assert_eq!(opts_show.cmd, "resume");
    assert_eq!(opts_show.args["action"], "show");
    assert_eq!(opts_show.args["target"], "pane-1");

    let opts_clear = parse(&["resume".into(), "clear".into()]).unwrap();
    assert_eq!(opts_clear.args["action"], "clear");

    let opts_approve = parse(&[
        "resume".into(),
        "approve".into(),
        "--prefix".into(),
        "claude".into(),
        "pane-1".into(),
    ])
    .unwrap();
    assert_eq!(opts_approve.args["action"], "approve");
    assert_eq!(opts_approve.args["prefix"], "claude");
    assert_eq!(opts_approve.args["target"], "pane-1");
}

#[test]
fn test_resume_report_rendering() {
    let show_json = json!({
        "id": "p-123",
        "has_resume": true,
        "argv": ["claude", "--resume", "abc"],
        "cwd": "/src/project",
        "is_imported": false,
        "approved": true,
        "recorded_at": "2026-10-05T02:00:00Z"
    });
    let rep = render("resume", &show_json);
    assert!(rep.contains("Pane: p-123"));
    assert!(rep.contains("Command: claude --resume abc"));
    assert!(rep.contains("Directory: /src/project"));
    assert!(rep.contains("Auto-run approved: yes"));

    let show_imported = json!({
        "id": "p-123",
        "has_resume": true,
        "argv": ["claude", "--resume", "abc"],
        "cwd": "/src/project",
        "is_imported": true,
        "approved": false,
        "recorded_at": "2026-10-05T02:00:00Z"
    });
    let rep_imported = render("resume", &show_imported);
    assert!(rep_imported.contains("Imported: yes (untrusted, auto-run disabled)"));

    let cleared_json = json!({
        "id": "p-123",
        "cleared": true
    });
    let rep_cleared = render("resume", &cleared_json);
    assert_eq!(rep_cleared, "Resume session cleared for pane p-123\n");
}

#[test]
fn test_input_subcommands_and_options_parsed_and_rendered() {
    let opts_lock = parse(&[
        "input".into(),
        "lock".into(),
        "--owner".into(),
        "agent-1".into(),
        "--target".into(),
        "pane-a".into(),
    ])
    .unwrap();
    assert_eq!(opts_lock.cmd, "input");
    assert_eq!(opts_lock.args["subcommand"], "lock");
    assert_eq!(opts_lock.args["owner"], "agent-1");
    assert_eq!(opts_lock.args["target"], "pane-a");

    let opts_to = parse(&["input".into(), "takeover".into()]).unwrap();
    assert_eq!(opts_to.args["subcommand"], "takeover");

    let opts_hb = parse(&["input".into(), "handback".into()]).unwrap();
    assert_eq!(opts_hb.args["subcommand"], "handback");

    let opts_st = parse(&["input".into()]).unwrap();
    assert_eq!(opts_st.args["subcommand"], "status");

    let opts_send = parse(&[
        "send".into(),
        "echo hi".into(),
        "--client".into(),
        "claude-worker".into(),
    ])
    .unwrap();
    assert_eq!(opts_send.cmd, "send");
    assert_eq!(opts_send.args["text"], "echo hi");
    assert_eq!(opts_send.args["client"], "claude-worker");

    let locked_val = json!({
        "id": "p-1",
        "locked": true,
        "owner": "agent-1",
        "last_client": "takoctl",
        "last_action": "send"
    });
    let rep_locked = render("input", &locked_val);
    assert!(rep_locked.contains("Pane p-1: locked (owner: agent-1)"));
    assert!(rep_locked.contains("Last activity mark: takoctl: send"));

    let log_val = json!({
        "id": "p-1",
        "entries": [
            {
                "client": "claude",
                "action": "type",
                "timestamp": "2026-10-05T02:00:00Z"
            }
        ]
    });
    let rep_log = render("input", &log_val);
    assert!(rep_log.contains("Automated input activity:"));
    assert!(rep_log.contains("[2026-10-05T02:00:00Z] claude: type"));
}

#[test]
fn test_activity_subcommands_and_options_parsed_and_rendered() {
    let opts = parse(&["activity".into()]).unwrap();
    assert_eq!(opts.cmd, "activity");
    assert_eq!(opts.args["action"], "get");

    let opts_clear = parse(&["activity".into(), "clear".into(), "pane-x".into()]).unwrap();
    assert_eq!(opts_clear.cmd, "activity");
    assert_eq!(opts_clear.args["action"], "clear");
    assert_eq!(opts_clear.args["target"], "pane-x");

    let opts_clear_flag = parse(&["activity".into(), "--clear".into()]).unwrap();
    assert_eq!(opts_clear_flag.cmd, "activity");
    assert_eq!(opts_clear_flag.args["action"], "clear");

    let opts_exp = parse(&["activity".into(), "--export".into(), "/tmp/act.json".into()]).unwrap();
    assert_eq!(opts_exp.cmd, "activity");
    assert_eq!(opts_exp.args["action"], "export");
    assert_eq!(opts_exp.args["export"], "/tmp/act.json");

    let log_val = json!({
        "id": "p-1",
        "entries": [
            {
                "client": "claude",
                "action": "type",
                "timestamp": "2026-10-05T02:00:00Z"
            },
            {
                "client": "takoctl",
                "action": "split",
                "timestamp": "2026-10-05T02:01:00Z"
            }
        ]
    });
    let rep_log = render("activity", &log_val);
    assert!(rep_log.contains("Automated activity log for pane p-1 (2 entries):"));
    assert!(rep_log.contains("[2026-10-05T02:00:00Z] claude: type"));
    assert!(rep_log.contains("[2026-10-05T02:01:00Z] takoctl: split"));

    let cleared_val = json!({"id": "p-1", "cleared": true});
    assert_eq!(render("activity", &cleared_val), "Activity log cleared for pane p-1.\n");

    let exp_val = json!({"id": "p-1", "exported": "/tmp/act.json"});
    assert_eq!(render("activity", &exp_val), "Exported activity log for pane p-1 to /tmp/act.json\n");
}

#[test]
fn test_broadcast_subcommands_and_options_parsed_and_rendered() {
    let opts_start = parse(&[
        "broadcast".into(),
        "start".into(),
        "--panes".into(),
        "p1,p2,p3".into(),
    ])
    .unwrap();
    assert_eq!(opts_start.cmd, "broadcast");
    assert_eq!(opts_start.args["subcommand"], "start");
    assert_eq!(opts_start.args["panes"], "p1,p2,p3");

    let opts_stop = parse(&["broadcast".into(), "stop".into()]).unwrap();
    assert_eq!(opts_stop.cmd, "broadcast");
    assert_eq!(opts_stop.args["subcommand"], "stop");

    let opts_st = parse(&["broadcast".into()]).unwrap();
    assert_eq!(opts_st.cmd, "broadcast");
    assert_eq!(opts_st.args["subcommand"], "status");

    let active_val = json!({
        "active": true,
        "leader": "p1",
        "count": 3,
        "panes": ["p1", "p2", "p3"]
    });
    let rep_active = render("broadcast", &active_val);
    assert!(rep_active.contains("Broadcast active across 3 panes (leader: p1):"));
    assert!(rep_active.contains("* p1 (leader)"));
    assert!(rep_active.contains("p2"));
    assert!(rep_active.contains("p3"));

    let inactive_val = json!({
        "active": false
    });
    let rep_inactive = render("broadcast", &inactive_val);
    assert_eq!(rep_inactive, "Broadcast input is inactive.\n");
}

#[test]
fn test_session_subcommands_and_options_parsed_and_rendered() {
    // 1. Export
    let opts_exp = parse(&[
        "session".into(),
        "export".into(),
        "/tmp/test_session.json".into(),
        "--window".into(),
        "win-1".into(),
    ])
    .unwrap();
    assert_eq!(opts_exp.cmd, "session");
    assert_eq!(opts_exp.args["action"], "export");
    assert_eq!(opts_exp.args["path"], "/tmp/test_session.json");
    assert_eq!(opts_exp.args["window"], "win-1");

    let exp_val = json!({
        "exported": true,
        "path": "/tmp/test_session.json",
        "windows": 2,
        "panes": 4,
        "resumes": 1,
        "format_version": 1
    });
    let rep_exp = render("session", &exp_val);
    assert!(rep_exp.contains(
        "Exported session to /tmp/test_session.json (2 windows, 4 panes), 1 resume binding"
    ));

    // 2. Import
    let opts_imp = parse(&[
        "session".into(),
        "import".into(),
        "/tmp/test_session.json".into(),
    ])
    .unwrap();
    assert_eq!(opts_imp.cmd, "session");
    assert_eq!(opts_imp.args["action"], "import");
    assert_eq!(opts_imp.args["path"], "/tmp/test_session.json");

    let imp_val = json!({
        "imported": true,
        "path": "/tmp/test_session.json",
        "windows": 2
    });
    let rep_imp = render("session", &imp_val);
    assert!(
        rep_imp.contains("Imported session from /tmp/test_session.json (2 windows created)")
    );
    assert!(
        rep_imp.contains(
            "Untrusted session: control sequences dropped, nothing runs automatically"
        )
    );

    // 3. Info
    let opts_info = parse(&[
        "session".into(),
        "info".into(),
        "/tmp/test_session.json".into(),
    ])
    .unwrap();
    assert_eq!(opts_info.cmd, "session");
    assert_eq!(opts_info.args["action"], "info");
    assert_eq!(opts_info.args["path"], "/tmp/test_session.json");

    let info_val = json!({
        "format_version": 1,
        "tako_version": "0.1.7",
        "exported_at": "2026-10-05T03:00:00Z",
        "windows": 2,
        "panes": 3,
        "resumes": 1
    });
    let rep_info = render("session", &info_val);
    assert!(
        rep_info.contains(
            "Session file (format v1, exported by Tako 0.1.7 at 2026-10-05T03:00:00Z):"
        )
    );
    assert!(rep_info.contains("2 windows, 3 panes, 1 resume record"));
}
