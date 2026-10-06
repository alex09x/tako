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
fn test_review_subcommands_and_options_parsed_and_rendered() {
    // review open
    let opts_open = parse(&[
        "review".into(),
        "open".into(),
        "/tmp/my-worktree".into(),
        "--base".into(),
        "origin/main".into(),
        "--target-pane".into(),
        "pane-dest-123".into(),
    ])
    .unwrap();
    assert_eq!(opts_open.cmd, "review");
    assert_eq!(opts_open.args["subcommand"], "open");
    assert_eq!(opts_open.args["worktree"], "/tmp/my-worktree");
    assert_eq!(opts_open.args["base"], "origin/main");
    assert_eq!(opts_open.args["target_pane"], "pane-dest-123");

    // review status open
    let status_val = json!({
        "id": "pane-1",
        "open": true,
        "task": "feature-abc",
        "base": "main",
        "files_count": 3,
        "comments_count": 2,
        "target": "pane-agent-456"
    });
    let rep_status = render("review", &status_val);
    assert!(rep_status.contains("Diff review active on pane pane-1:"));
    assert!(rep_status.contains("Worktree/Task: feature-abc"));
    assert!(rep_status.contains("Changed files: 3"));
    assert!(rep_status.contains("Comments:      2"));
    assert!(rep_status.contains("Target pane:   pane-agent-456"));

    // review status closed
    let rep_status_closed = render("review", &json!({"id": "pane-1", "open": false}));
    assert_eq!(rep_status_closed, "No active diff review on pane pane-1.\n");

    // review files
    let opts_files = parse(&["review".into(), "files".into()]).unwrap();
    assert_eq!(opts_files.cmd, "review");
    assert_eq!(opts_files.args["subcommand"], "files");

    let files_val = json!({
        "id": "pane-1",
        "task": "feature-abc",
        "base": "main",
        "files": [
            { "path": "src/main.rs", "status": "modified", "insertions": 10, "deletions": 2 },
            { "path": "src/lib.rs", "status": "added", "insertions": 45, "deletions": 0 }
        ]
    });
    let rep_files = render("review", &files_val);
    assert!(rep_files.contains("Changed files in review 'feature-abc' against 'main' (2):"));
    assert!(rep_files.contains("M  src/main.rs (+10, -2)"));
    assert!(rep_files.contains("A  src/lib.rs (+45, -0)"));

    // review diff
    let opts_diff = parse(&["review".into(), "diff".into(), "src/main.rs".into()]).unwrap();
    assert_eq!(opts_diff.cmd, "review");
    assert_eq!(opts_diff.args["subcommand"], "diff");
    assert_eq!(opts_diff.args["file"], "src/main.rs");

    let patch_val = json!({
        "id": "pane-1",
        "task": "feature-abc",
        "patch": "--- a/src/main.rs\n+++ b/src/main.rs\n@@ -1 +1 @@\n-old\n+new\n"
    });
    let rep_diff = render("review", &patch_val);
    assert!(rep_diff.contains("--- a/src/main.rs"));
    assert!(rep_diff.contains("+new"));

    // review comment add
    let opts_add = parse(&[
        "review".into(),
        "comment".into(),
        "add".into(),
        "--file".into(),
        "src/main.rs".into(),
        "--line".into(),
        "42".into(),
        "Fix this typo please".into(),
    ])
    .unwrap();
    assert_eq!(opts_add.cmd, "review");
    assert_eq!(opts_add.args["subcommand"], "comment");
    assert_eq!(opts_add.args["action"], "add");
    assert_eq!(opts_add.args["file"], "src/main.rs");
    assert_eq!(opts_add.args["line"], 42);
    assert_eq!(opts_add.args["text"], "Fix this typo please");

    let rep_add = render(
        "review",
        &json!({
            "id": "pane-1",
            "comment_id": "c-123",
            "file": "src/main.rs",
            "line": 42
        }),
    );
    assert_eq!(rep_add, "Added comment c-123 on src/main.rs:42.\n");

    // review comment list
    let comments_val = json!({
        "id": "pane-1",
        "comments": [
            { "id": "c-1", "file": "src/main.rs", "line": 10, "text": "First comment" },
            { "id": "c-2", "file": "src/lib.rs", "line": 20, "text": "Second comment" }
        ]
    });
    let rep_comments = render("review", &comments_val);
    assert!(rep_comments.contains("Review comments (2):"));
    assert!(rep_comments.contains("[c-1] src/main.rs:10: First comment"));
    assert!(rep_comments.contains("[c-2] src/lib.rs:20: Second comment"));

    // review comment remove & clear
    let rep_remove = render("review", &json!({"id": "pane-1", "removed": true}));
    assert_eq!(rep_remove, "Removed review comment.\n");

    let rep_clear = render("review", &json!({"id": "pane-1", "cleared": true}));
    assert_eq!(rep_clear, "Cleared all review comments.\n");

    // review send
    let opts_send = parse(&[
        "review".into(),
        "send".into(),
        "--target-pane".into(),
        "pane-agent-1".into(),
    ])
    .unwrap();
    assert_eq!(opts_send.cmd, "review");
    assert_eq!(opts_send.args["subcommand"], "send");
    assert_eq!(opts_send.args["target_pane"], "pane-agent-1");

    let rep_send = render(
        "review",
        &json!({
            "id": "pane-rev",
            "target": "pane-agent-1",
            "sent": true,
            "message": "# Diff Review Feedback\n- src/main.rs:10: First comment"
        }),
    );
    assert!(
        rep_send.contains("Sent diff review feedback from pane pane-rev to pane pane-agent-1.")
    );
    assert!(rep_send.contains("# Diff Review Feedback"));

    // review close
    let opts_close = parse(&["review".into(), "close".into()]).unwrap();
    assert_eq!(opts_close.cmd, "review");
    assert_eq!(opts_close.args["subcommand"], "close");

    let rep_close = render("review", &json!({"id": "pane-1", "closed": true}));
    assert_eq!(rep_close, "Closed diff review on pane pane-1.\n");

    // sanitize_terminal_control and diff terminal-injection tests
    let raw_control = "hello\x1b]52;c;evil_copy\x07\x1b[2Jcleared\r\n\tworld\x7f\u{009b}c1";
    let sanitized = sanitize_terminal_control(raw_control);
    assert!(!sanitized.contains('\x1b'));
    assert!(!sanitized.contains('\x07'));
    assert!(!sanitized.contains('\r'));
    assert!(!sanitized.contains('\x7f'));
    assert!(!sanitized.contains('\u{009b}'));
    assert!(sanitized.contains("^[]52;c;evil_copy^G"));
    assert!(sanitized.contains("^[[2Jcleared^M\n\tworld^?\\u{009B}c1"));

    let evil_diff = json!({
        "id": "pane-1",
        "task": "evil-task\x1b[1m",
        "patch": "--- a/evil.txt\n+++ b/evil.txt\n@@ -0,0 +1,2 @@\n+\x1b]52;c;clipboard\x07\n+\x1b[2J\r\n"
    });
    let rep_evil = render("review", &evil_diff);
    assert!(!rep_evil.contains('\x1b'));
    assert!(!rep_evil.contains('\x07'));
    assert!(!rep_evil.contains('\r'));
    assert!(rep_evil.contains("^[]52;c;clipboard^G"));
    assert!(rep_evil.contains("^[[2J^M"));
}
