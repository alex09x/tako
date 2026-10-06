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
