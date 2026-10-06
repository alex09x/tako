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

    fn args(s: &[&str]) -> Vec<String> {
        s.iter().map(|a| a.to_string()).collect()
    }

    #[test]
    fn options_and_target_reach_the_request() {
        let opts = parse(&args(&["tree", "--target", "ab12", "--json"])).unwrap();
        assert!(opts.json);
        let req = request(&opts, Some("1111".into()));
        assert_eq!(
            req,
            json!({"cmd": "tree", "args": {"target": "ab12"}, "from": "1111"})
        );
        // Outside a pane there is no "from".
        assert!(request(&opts, None).get("from").is_none());
        assert!(request(&opts, Some(String::new())).get("from").is_none());
    }

    #[test]
    fn text_commands_take_exactly_one_argument() {
        let opts = parse(&args(&["send", "ls -la", "--target", "ab", "--no-enter"])).unwrap();
        assert_eq!(
            request(&opts, None),
            json!({"cmd": "send", "args": {"text": "ls -la", "target": "ab", "enter": false}})
        );
        let opts = parse(&args(&["key", "ctrl+c"])).unwrap();
        assert_eq!(opts.args["key"], "ctrl+c");
        let opts = parse(&args(&["type", "--", "--not-an-option"])).unwrap();
        assert_eq!(opts.args["text"], "--not-an-option");
        let opts = parse(&args(&["text", "--lines", "3"])).unwrap();
        assert_eq!(opts.args["lines"], 3);
        assert!(parse(&args(&["send"])).is_err());
        assert!(parse(&args(&["send", "a", "b"])).is_err());
        assert!(parse(&args(&["text", "x"])).is_err());
        assert!(parse(&args(&["text", "--lines", "many"])).is_err());
    }

    #[test]
    fn run_and_wait_take_their_options() {
        let opts = parse(&args(&[
            "run",
            "--split",
            "down",
            "--wait",
            "--timeout",
            "90",
            "--lines",
            "5",
            "--",
            "/bin/echo",
            "a b",
            "--not-ours",
        ]))
        .unwrap();
        let req = request(&opts, None);
        assert_eq!(
            req["args"]["argv"],
            json!(["/bin/echo", "a b", "--not-ours"])
        );
        assert_eq!(req["args"]["split"], "down");
        assert_eq!(req["args"]["wait"], true);
        assert!(req["args"]["path"].is_string());
        assert_eq!(
            answer_limit(&opts),
            std::time::Duration::from_secs(90) + socket::TIMEOUT
        );
        // A bare name is found on PATH; an unknown one is a usage error.
        assert_eq!(resolve("sh", "/nope:/bin"), Some("/bin/sh".into()));
        assert_eq!(resolve("./x", "/bin"), Some("./x".into()));
        assert!(resolve("definitely-not-a-program-xyz", "/bin:/usr/bin").is_none());
        assert!(parse(&args(&["run", "ls"])).is_err());
        let opts = parse(&args(&["wait", "--command", "12@3"])).unwrap();
        assert_eq!(opts.args["command"], "12@3");
        let opts = parse(&args(&["wait", "--next"])).unwrap();
        assert_eq!(opts.args["next"], true);
        assert_eq!(
            answer_limit(&opts),
            std::time::Duration::from_secs(24 * 3600)
        );
        assert_eq!(
            answer_limit(&parse(&args(&["run", "--", "/bin/ls"])).unwrap()),
            socket::TIMEOUT
        );
        assert!(parse(&args(&["run"])).is_err());
        assert!(parse(&args(&["wait", "--timeout", "-1"])).is_err());
        assert!(parse(&args(&["wait", "--timeout", "1e300"])).is_err());
        assert!(parse(&args(&["last", "x"])).is_err());
    }

    #[test]
    fn a_command_reads_as_its_line_status_and_output() {
        let result = json!({"command": {"input": "make", "cwd": "/src", "running": false,
            "finished": true, "exitCode": 2}, "output": "error: x", "more": true, "state": "finished"});
        assert_eq!(
            command_report(&result),
            "$ make   (/src)   exit 2\n...\nerror: x\n"
        );
        let result = json!({"command": {"ref": "7@1", "input": "make", "running": false, "finished": true,
            "abandoned": false, "exitCode": 0}, "output": "", "incomplete": true});
        assert_eq!(
            command_report(&result),
            "$ make   exit 0   [7@1]\n(some of its output was written over or is no longer kept)\n"
        );
        let result = json!({"process": {"argv": ["/bin/ls", "/nope"], "running": false, "exitCode": 1},
            "output": "ls: /nope: No such file", "state": "finished"});
        assert_eq!(
            command_report(&result),
            "/bin/ls /nope   exit 1\nls: /nope: No such file\n"
        );
        let result = json!({"command": {"input": "sleep 9", "running": true}, "output": "", "state": "timeout"});
        assert_eq!(
            command_report(&result),
            "$ sleep 9   still running (timed out waiting)\n"
        );
        assert!(command_report(&json!({"command": null})).starts_with("no command"));
    }

    #[test]
    fn notify_takes_its_text_and_a_title() {
        let opts = parse(&args(&["notify", "build done", "--title", "CI"])).unwrap();
        assert_eq!(
            request(&opts, None),
            json!({"cmd": "notify", "args": {"text": "build done", "title": "CI"}})
        );
        assert!(parse(&args(&["notify"])).is_err());
    }

    #[test]
    fn find_groups_matches_by_pane_and_command() {
        let result = json!({"matches": [
            {"id": "aaaaaaaa-1", "place": "tako -- tab 1 of 2", "pane": null, "line": "error: one",
             "command": {"input": "make", "status": "✗ exit 2", "cwd": "/src"}},
            {"id": "aaaaaaaa-1", "place": "tako -- tab 1 of 2", "pane": null, "line": "error: two",
             "command": {"input": "make", "status": "✗ exit 2", "cwd": "/src"}},
            {"id": "bbbbbbbb-2", "place": "logs", "pane": "pane 2 of 2", "line": "kernel error"}],
            "more": true});
        assert_eq!(
            find_report(&result),
            "\
aaaaaaaa  tako -- tab 1 of 2
  $ make   ✗ exit 2   /src
    error: one
    error: two
bbbbbbbb  logs -- pane 2 of 2
    kernel error
... more matches (--limit N)
"
        );
        assert_eq!(
            find_report(&json!({"matches": [], "more": false})),
            "no matches\n"
        );
        let opts = parse(&args(&["find", "panic", "--limit", "5"])).unwrap();
        assert_eq!(
            request(&opts, None),
            json!({"cmd": "find", "args": {"text": "panic", "limit": 5}})
        );
    }

    #[test]
    fn a_dialog_reads_with_its_buttons_and_the_chosen_one() {
        let result = json!({"dialogs": [{"window": "window-1", "title": "Close Terminal?",
            "text": "A process is running.", "buttons": ["Cancel", "Close"], "selected": "Close"}]});
        assert_eq!(
            dialog_report(&result),
            "window-1  Close Terminal?\n  A process is running.\n  buttons: Cancel  [Close]\n"
        );
        assert_eq!(
            dialog_report(&json!({"dialogs": []})),
            "no question is up\n"
        );
        let opts = parse(&args(&["dialog", "--press", "Later"])).unwrap();
        assert_eq!(
            request(&opts, None),
            json!({"cmd": "dialog", "args": {"press": "Later"}})
        );
    }

    #[test]
    fn usage_errors_are_refused() {
        assert!(parse(&args(&[])).is_err());
        assert!(parse(&args(&["frobnicate"])).is_err());
        assert!(parse(&args(&["tree", "--target"])).is_err());
        assert!(parse(&args(&["tree", "--nope"])).is_err());
        assert!(parse(&args(&["tree", "extra"])).is_err());
    }

    #[test]
    fn a_tree_with_splits_reads_as_nested_splits() {
        let result = json!({"windows": [{"id": "w1", "tabs": [{"id": "t1", "index": 1, "title": "build",
            "selected": true,
            "layout": {"split": "right", "ratio": 0.5, "children": [
                {"pane": "p1"},
                {"split": "down", "ratio": 0.3, "children": [{"pane": "p2"}, {"pane": "p3"}]}]},
            "panes": [
                {"id": "p1", "cwd": "/src", "title": "zsh", "focused": true},
                {"id": "p2", "cwd": "/tmp", "title": "", "focused": false},
                {"id": "p3", "cwd": null, "title": "top", "focused": false}]}]}]});
        let want = [
            "window w1",
            "  tab 1  \"build\"  (shown)",
            "    split right 50%",
            "      *p1  /src  zsh",
            "      split down 30%",
            "         p2  /tmp  ",
            "         p3  -  top",
            "",
        ]
        .join("\n");
        assert_eq!(render("tree", &result), want);
    }

    #[test]
    fn a_tree_reads_as_an_outline() {
        let result = json!({"windows": [{"id": "w1", "tabs": [{"id": "t1", "panes": [
            {"id": "p1", "cwd": "/src", "title": "zsh", "focused": true},
            {"id": "p2", "cwd": null, "title": "", "focused": false}]}]}]});
        assert_eq!(
            render("tree", &result),
            "window w1\n  tab t1\n    *p1  /src  zsh\n     p2  -  \n"
        );
    }

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

    #[test]
    fn test_skills_subcommands_and_options() {
        let opts_default = parse(&["skills".into()]).unwrap();
        assert_eq!(opts_default.cmd, "skills");
        assert_eq!(opts_default.args["action"], "list");

        let opts_list = parse(&["skills".into(), "list".into()]).unwrap();
        assert_eq!(opts_list.cmd, "skills");
        assert_eq!(opts_list.args["action"], "list");

        let opts_status = parse(&["skills".into(), "status".into(), "claude".into()]).unwrap();
        assert_eq!(opts_status.cmd, "skills");
        assert_eq!(opts_status.args["action"], "status");
        assert_eq!(opts_status.args["agent"], "claude");

        let opts_install = parse(&[
            "skills".into(),
            "install".into(),
            "gemini".into(),
            "--yes".into(),
            "--diff-only".into(),
            "--skill-path".into(),
            "/tmp/custom/SKILL.md".into(),
        ])
        .unwrap();
        assert_eq!(opts_install.cmd, "skills");
        assert_eq!(opts_install.args["action"], "install");
        assert_eq!(opts_install.args["agent"], "gemini");
        assert_eq!(opts_install.args["yes"], true);
        assert_eq!(opts_install.args["diff_only"], true);
        assert_eq!(opts_install.args["skill_path"], "/tmp/custom/SKILL.md");

        let opts_uninstall = parse(&["skills".into(), "uninstall".into(), "aider".into()]).unwrap();
        assert_eq!(opts_uninstall.cmd, "skills");
        assert_eq!(opts_uninstall.args["action"], "uninstall");
        assert_eq!(opts_uninstall.args["agent"], "aider");
    }

    #[test]
    fn test_mcp_command_and_capabilities_option() {
        let opts_mcp = parse(&["mcp".into()]).unwrap();
        assert_eq!(opts_mcp.cmd, "mcp");
        assert!(!opts_mcp.args.contains_key("capabilities"));

        let opts_scoped =
            parse(&["mcp".into(), "--capabilities".into(), "read,signal".into()]).unwrap();
        assert_eq!(opts_scoped.cmd, "mcp");
        assert_eq!(opts_scoped.args["capabilities"], "read,signal");
    }

    #[test]
    fn test_overlay_subcommands_and_options_parsed_and_rendered() {
        // 1. Open
        let opts_open = parse(&[
            "overlay".into(),
            "open".into(),
            "/tmp/artifact.md".into(),
            "--split".into(),
            "right".into(),
            "--type".into(),
            "markdown".into(),
        ])
        .unwrap();
        assert_eq!(opts_open.cmd, "overlay");
        assert_eq!(opts_open.args["subcommand"], "open");
        assert_eq!(opts_open.args["file"], "/tmp/artifact.md");
        assert_eq!(opts_open.args["split"], "right");
        assert_eq!(opts_open.args["type"], "markdown");

        let open_val = json!({
            "id": "pane-1",
            "target": "pane-0",
            "open": true,
            "file": "/tmp/artifact.md",
            "title": "artifact.md",
            "type": "markdown",
            "sandboxed": "/tmp",
            "split": "right"
        });
        let rep_open = render("overlay", &open_val);
        assert!(rep_open.contains("Overlay active on pane pane-1 (split right):"));
        assert!(rep_open.contains("File: /tmp/artifact.md"));
        assert!(rep_open.contains("Type: markdown"));
        assert!(rep_open.contains("Sandboxed: /tmp"));

        // 2. Close
        let opts_close = parse(&["overlay".into(), "close".into()]).unwrap();
        assert_eq!(opts_close.cmd, "overlay");
        assert_eq!(opts_close.args["subcommand"], "close");

        let rep_closed = render("overlay", &json!({"id": "pane-1", "closed": true}));
        assert_eq!(rep_closed, "Closed overlay for pane pane-1.\n");

        let rep_not_closed = render("overlay", &json!({"id": "pane-1", "closed": false}));
        assert_eq!(
            rep_not_closed,
            "No active overlay to close on pane pane-1.\n"
        );

        // 3. Status
        let opts_st = parse(&["overlay".into()]).unwrap();
        assert_eq!(opts_st.cmd, "overlay");
        assert_eq!(opts_st.args["subcommand"], "status");

        let rep_st_inactive = render("overlay", &json!({"id": "pane-1", "open": false}));
        assert_eq!(rep_st_inactive, "No overlay active on pane pane-1.\n");

        // 4. Reload
        let opts_reload = parse(&["overlay".into(), "reload".into()]).unwrap();
        assert_eq!(opts_reload.cmd, "overlay");
        assert_eq!(opts_reload.args["subcommand"], "reload");

        let rep_reload = render("overlay", &json!({"id": "pane-1", "reloaded": true}));
        assert_eq!(rep_reload, "Reloaded overlay for pane pane-1.\n");
    }

    #[test]
    fn test_text_styled_and_screenshot_options() {
        // 1. Text with --styled and --lines
        let opts_text = parse(&[
            "text".into(),
            "--lines".into(),
            "50".into(),
            "--styled".into(),
        ])
        .unwrap();
        assert_eq!(opts_text.cmd, "text");
        assert_eq!(opts_text.args["lines"], 50);
        assert_eq!(opts_text.args["styled"], true);

        // 2. Screenshot with positional path
        let opts_ss1 = parse(&["screenshot".into(), "/tmp/screen.png".into()]).unwrap();
        assert_eq!(opts_ss1.cmd, "screenshot");
        assert_eq!(opts_ss1.args["out"], "/tmp/screen.png");

        // 3. Screenshot with --out flag
        let opts_ss2 =
            parse(&["screenshot".into(), "--out".into(), "/tmp/out.png".into()]).unwrap();
        assert_eq!(opts_ss2.cmd, "screenshot");
        assert_eq!(opts_ss2.args["out"], "/tmp/out.png");

        // 4. Render screenshot
        let ss_val = json!({
            "id": "pane-1",
            "width": 800,
            "height": 600,
            "format": "png",
            "data": "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVR4nGNiAAAABgADNjd8qAAAAABJRU5ErkJggg=="
        });
        let rep_ss = render("screenshot", &ss_val);
        assert_eq!(rep_ss, "screenshot of pane pane-1 (800x600 png)\n");

        // 5. Base64 decode verification
        let bytes = decode_base64("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVR4nGNiAAAABgADNjd8qAAAAABJRU5ErkJggg==").unwrap();
        assert_eq!(
            &bytes[0..8],
            &[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        );
    }

    #[test]
    fn test_write_exclusive_temp_screenshot() {
        let fake_png = vec![0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
        let path = write_exclusive_temp_file("testpane", &fake_png).unwrap();
        assert!(path.exists());
        let file_name = path.file_name().unwrap().to_str().unwrap();
        assert!(file_name.starts_with("tako-screenshot-testpane-"));
        assert!(file_name.ends_with(".png"));

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let metadata = std::fs::metadata(&path).unwrap();
            let mode = metadata.permissions().mode() & 0o777;
            assert_eq!(mode, 0o600);
        }

        let read_bytes = std::fs::read(&path).unwrap();
        assert_eq!(read_bytes, fake_png);

        let _ = std::fs::remove_file(&path);
    }

    #[test]
    #[cfg(unix)]
    fn test_screenshot_temp_refuses_symlink_overwrite() {
        use std::os::unix::fs::{OpenOptionsExt, symlink};
        let temp_dir = std::env::temp_dir();
        let target_file = temp_dir.join(format!("test-target-{}.txt", random_hex(8)));
        std::fs::write(&target_file, b"secret original data").unwrap();

        let link_path = temp_dir.join(format!("test-link-{}.png", random_hex(8)));
        symlink(&target_file, &link_path).unwrap();

        // Attempting to exclusively create a file at link_path must fail
        let mut opts = std::fs::OpenOptions::new();
        opts.write(true).create_new(true);
        opts.custom_flags(libc::O_NOFOLLOW);
        let res = opts.open(&link_path);
        assert!(res.is_err(), "exclusive open must refuse existing symlink");

        // Target content must remain untouched
        let content = std::fs::read_to_string(&target_file).unwrap();
        assert_eq!(content, "secret original data");

        let _ = std::fs::remove_file(&link_path);
        let _ = std::fs::remove_file(&target_file);
    }

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
