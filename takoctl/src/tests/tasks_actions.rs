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
fn action_subcommands_and_options_parsed_and_rendered() {
    // Action list
    let opts = parse(&args(&["action", "list"])).unwrap();
    assert_eq!(opts.cmd, "action");
    assert_eq!(opts.args["action"], "list");

    // Action list with path
    let opts = parse(&args(&["action", "list", "/path/to/project"])).unwrap();
    assert_eq!(opts.cmd, "action");
    assert_eq!(opts.args["action"], "list");
    assert_eq!(opts.args["path"], "/path/to/project");

    // Action run
    let opts = parse(&args(&["action", "run", "build"])).unwrap();
    assert_eq!(opts.cmd, "action");
    assert_eq!(opts.args["action"], "run");
    assert_eq!(opts.args["id"], "build");
    assert_eq!(opts.args.get("approve"), None);

    // Action run with --approve and --path
    let opts = parse(&args(&[
        "action",
        "run",
        "--approve",
        "--path",
        "/my/proj",
        "test",
    ]))
    .unwrap();
    assert_eq!(opts.cmd, "action");
    assert_eq!(opts.args["action"], "run");
    assert_eq!(opts.args["id"], "test");
    assert_eq!(opts.args["approve"], true);
    assert_eq!(opts.args["path"], "/my/proj");

    // Action approve
    let opts = parse(&args(&["action", "approve", "/path/to/project"])).unwrap();
    assert_eq!(opts.cmd, "action");
    assert_eq!(opts.args["action"], "approve");
    assert_eq!(opts.args["path"], "/path/to/project");

    // Action status
    let opts = parse(&args(&["action", "status", "/path/to/project"])).unwrap();
    assert_eq!(opts.cmd, "action");
    assert_eq!(opts.args["action"], "status");
    assert_eq!(opts.args["path"], "/path/to/project");

    // Render list
    let list_json = json!({
        "project": "/Users/user/project",
        "status": "trusted",
        "actions": [
            {
                "id": "build",
                "title": "Build Project",
                "target": "split",
                "command": ["cargo", "build"]
            },
            {
                "id": "test",
                "title": "Run Tests",
                "target": "new-tab",
                "command": ["cargo", "test"]
            }
        ]
    });
    assert_eq!(
        render("action", &list_json),
        "Project actions for /Users/user/project [trusted]:\n  * build (split): Build Project\n      $ cargo build\n  * test (new-tab): Run Tests\n      $ cargo test\n"
    );

    // Render run
    let run_json = json!({
        "ran": true,
        "id": "build",
        "title": "Build Project",
        "target": "split",
        "cwd": "/Users/user/project"
    });
    assert_eq!(
        render("action", &run_json),
        "Ran action 'Build Project' (build) in split (cwd: /Users/user/project)\n"
    );

    // Render approve
    let approve_json = json!({
        "approved": true,
        "path": "/path/to/.tako/actions.json",
        "sha256": "1234567890abcdef"
    });
    assert_eq!(
        render("action", &approve_json),
        "Approved project actions at /path/to/.tako/actions.json (sha256: 1234567890ab)\n"
    );

    // Render status
    let status_json = json!({
        "path": "/path/to/.tako/actions.json",
        "status": "trusted",
        "sha256": "1234567890abcdef",
        "actions_count": 2.0
    });
    assert_eq!(
        render("action", &status_json),
        "Project actions /path/to/.tako/actions.json: trusted (sha256: 1234567890ab, 2 actions)\n"
    );

    // Errors
    assert!(parse(&args(&["action", "run"])).is_err());
    assert!(parse(&args(&["action", "unknown_sub"])).is_err());
}

#[test]
fn task_subcommands_and_options_parsed_and_rendered() {
    // Task list
    let opts = parse(&args(&["task", "list"])).unwrap();
    assert_eq!(opts.cmd, "task");
    assert_eq!(opts.args["action"], "list");

    // Task list with path
    let opts = parse(&args(&["task", "list", "/my/repo"])).unwrap();
    assert_eq!(opts.cmd, "task");
    assert_eq!(opts.args["action"], "list");
    assert_eq!(opts.args["path"], "/my/repo");

    // Task create
    let opts = parse(&args(&[
        "task",
        "create",
        "agent-feature",
        "--branch",
        "feat/agent-ui",
        "--base",
        "main",
        "--target",
        "workspace",
        "--command",
        "cargo test",
        "--path",
        "/my/repo",
    ]))
    .unwrap();
    assert_eq!(opts.cmd, "task");
    assert_eq!(opts.args["action"], "create");
    assert_eq!(opts.args["name"], "agent-feature");
    assert_eq!(opts.args["branch"], "feat/agent-ui");
    assert_eq!(opts.args["base"], "main");
    assert_eq!(opts.args["target"], "workspace");
    assert_eq!(opts.args["command"], "cargo test");
    assert_eq!(opts.args["path"], "/my/repo");

    // Task status
    let opts = parse(&args(&[
        "task",
        "status",
        "agent-feature",
        "--path",
        "/my/repo",
    ]))
    .unwrap();
    assert_eq!(opts.cmd, "task");
    assert_eq!(opts.args["action"], "status");
    assert_eq!(opts.args["name"], "agent-feature");
    assert_eq!(opts.args["path"], "/my/repo");

    // Task finish with --archive and --editor
    let opts = parse(&args(&[
        "task",
        "finish",
        "agent-feature",
        "--archive",
        "--editor",
    ]))
    .unwrap();
    assert_eq!(opts.cmd, "task");
    assert_eq!(opts.args["action"], "finish");
    assert_eq!(opts.args["name"], "agent-feature");
    assert_eq!(opts.args["archive"], true);
    assert_eq!(opts.args["editor"], true);

    // Render list
    let list_json = json!({
        "tasks": [
            {
                "name": "feat-1",
                "branch": "task/feat-1",
                "status": "running",
                "worktree": "/path/to/worktree",
                "ahead": 1.0,
                "behind": 0.0,
                "changed_files": 2.0
            }
        ]
    });
    assert_eq!(
        render("task", &list_json),
        "Worktree tasks:\n  * feat-1 (task/feat-1): [running] (worktree: /path/to/worktree)\n      ahead: 1, behind: 0, 2 changed files\n"
    );

    // Render create
    let create_json = json!({
        "created": true,
        "name": "feat-1",
        "branch": "task/feat-1",
        "base": "main",
        "target": "tab",
        "worktree": "/path/to/worktree"
    });
    assert_eq!(
        render("task", &create_json),
        "Created worktree task 'feat-1' on branch task/feat-1 (base: main, target: tab)\n  Worktree: /path/to/worktree\n"
    );

    // Render finish (archived)
    let finish_json = json!({
        "finished": true,
        "name": "feat-1",
        "archived": true,
        "opened_in_editor": false,
        "worktree": "/path/to/worktree"
    });
    assert_eq!(
        render("task", &finish_json),
        "Archived worktree task 'feat-1' (removed worktree at /path/to/worktree)\n"
    );

    // Render finish (editor)
    let finish_editor_json = json!({
        "finished": true,
        "name": "feat-1",
        "archived": false,
        "opened_in_editor": true,
        "worktree": "/path/to/worktree"
    });
    assert_eq!(
        render("task", &finish_editor_json),
        "Finished worktree task 'feat-1' (opened in editor at /path/to/worktree)\n"
    );

    // Render status
    let status_json = json!({
        "name": "feat-1",
        "branch": "task/feat-1",
        "status": "running",
        "worktree": "/path/to/worktree",
        "ahead": 0.0,
        "behind": 0.0,
        "changed_files": 0.0
    });
    assert_eq!(
        render("task", &status_json),
        "Worktree task 'feat-1' (task/feat-1): [running]\n  Worktree: /path/to/worktree\n  ahead: 0, behind: 0, clean\n"
    );

    // Errors
    assert!(parse(&args(&["task", "create"])).is_err());
    assert!(parse(&args(&["task", "status"])).is_err());
    assert!(parse(&args(&["task", "finish"])).is_err());
    assert!(parse(&args(&["task", "unknown_sub"])).is_err());
}

#[test]
fn subagent_panes_and_hierarchy_options_and_rendering() {
    // Split with defaults and subagent flags
    let opts = parse(&args(&["split", "--child-of", "self", "--label", "worker"])).unwrap();
    assert_eq!(opts.cmd, "split");
    assert_eq!(opts.args["direction"], "right");
    assert_eq!(opts.args["child_of"], "self");
    assert_eq!(opts.args["label"], "worker");

    // Split with explicit direction and parent pane
    let opts = parse(&args(&["split", "down", "--child-of", "pane-abc"])).unwrap();
    assert_eq!(opts.cmd, "split");
    assert_eq!(opts.args["direction"], "down");
    assert_eq!(opts.args["child_of"], "pane-abc");

    // Collapse and expand parsing
    let opts = parse(&args(&["collapse"])).unwrap();
    assert_eq!(opts.cmd, "collapse");
    assert!(opts.args.get("target").is_none());

    let opts = parse(&args(&["collapse", "parent-pane"])).unwrap();
    assert_eq!(opts.cmd, "collapse");
    assert_eq!(opts.args["target"], "parent-pane");

    let opts = parse(&args(&["expand"])).unwrap();
    assert_eq!(opts.cmd, "expand");
    assert!(opts.args.get("target").is_none());

    let opts = parse(&args(&["expand", "parent-pane"])).unwrap();
    assert_eq!(opts.cmd, "expand");
    assert_eq!(opts.args["target"], "parent-pane");

    // Hierarchy tree rendering
    let tree_json = json!({
        "windows": [
            {
                "id": "w1",
                "tabs": [
                    {
                        "index": 1.0,
                        "title": "Agent Workspace",
                        "selected": true,
                        "panes": [
                            {
                                "id": "p-parent",
                                "cwd": "/src",
                                "title": "main",
                                "focused": true,
                                "children": ["p-child1", "p-child2"],
                                "childrenStatus": "2 subagents running"
                            },
                            {
                                "id": "p-child1",
                                "cwd": "/src",
                                "title": "bash",
                                "parent": "p-parent",
                                "label": "worker"
                            },
                            {
                                "id": "p-child2",
                                "cwd": "/src",
                                "title": "bash",
                                "parent": "p-parent",
                                "label": "researcher"
                            }
                        ]
                    }
                ]
            }
        ]
    });

    let rendered = render("tree", &tree_json);
    assert_eq!(
        rendered,
        "window w1\n  tab 1  \"Agent Workspace\"  (shown)\n    *p-parent  /src  main  (2 subagents running)\n       p-child1  /src  bash  [worker]\n       p-child2  /src  bash  [researcher]\n"
    );

    // Collapsed parent hides children in tree
    let collapsed_tree_json = json!({
        "windows": [
            {
                "id": "w1",
                "tabs": [
                    {
                        "index": 1.0,
                        "title": "Agent Workspace",
                        "panes": [
                            {
                                "id": "p-parent",
                                "cwd": "/src",
                                "title": "main",
                                "children": ["p-child1"],
                                "childrenStatus": "1 subagent running",
                                "collapsed": true
                            },
                            {
                                "id": "p-child1",
                                "cwd": "/src",
                                "title": "bash",
                                "parent": "p-parent",
                                "label": "worker"
                            }
                        ]
                    }
                ]
            }
        ]
    });

    let rendered_collapsed = render("tree", &collapsed_tree_json);
    assert_eq!(
        rendered_collapsed,
        "window w1\n  tab 1  \"Agent Workspace\"\n     p-parent  /src  main  (1 subagent running)  [collapsed]\n"
    );
}
