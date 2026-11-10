/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::super::*;
use super::args;
use serde_json::json;

fn ok(argv: &[&str]) -> Options {
    parse(&args(argv)).unwrap_or_else(|e| panic!("{argv:?}: {e}"))
}

fn err(argv: &[&str]) -> String {
    match parse(&args(argv)) {
        Ok(opts) => panic!("{argv:?} parsed: {:?}", opts.args),
        Err(e) => e,
    }
}

#[test]
fn pane_actions_and_states() {
    let opts = ok(&["pane"]);
    assert_eq!(
        (opts.cmd.as_str(), &opts.args["action"]),
        ("pane", &json!("state"))
    );
    for action in [
        "float",
        "dock",
        "maximize",
        "unmaximize",
        "minimize",
        "restore",
        "state",
    ] {
        assert_eq!(
            ok(&["pane", action, "--target", "abc"]).args["action"],
            action
        );
    }
    assert_eq!(ok(&["pane", "get"]).args["action"], "state");
    assert_eq!(ok(&["pane", "tile"]).args["action"], "dock");

    let set = ok(&["pane", "set", "Float", "--no-select"]);
    assert_eq!(set.args["action"], "set");
    assert_eq!(set.args["state"], "floating");
    assert_eq!(set.args["select"], false);
    assert_eq!(
        ok(&["pane", "set", "--state", "shelf"]).args["state"],
        "minimized"
    );

    assert!(err(&["pane", "set"]).contains("needs a state"));
    assert!(err(&["pane", "set", "sideways"]).contains("unknown pane state"));
    assert!(err(&["pane", "set", "tiled", "--state", "floating"]).contains("once"));
    assert!(err(&["pane", "float", "--state", "floating"]).contains("does not take --state"));
    assert!(err(&["pane", "spin"]).contains("unknown pane action"));
    assert!(err(&["pane", "float", "extra"]).contains("unexpected argument"));

    let moved = ok(&["pane", "move"]);
    assert_eq!(
        (&moved.args["action"], &moved.args["window"]),
        (&json!("move"), &json!("new"))
    );
    assert!(err(&["pane", "move", "--window", "window-1"]).contains("--window new"));
}

#[test]
fn panes_open_in_a_state_only_where_one_is_created() {
    assert_eq!(
        ok(&["tab-new", "--state", "maximized"]).args["state"],
        "maximized"
    );
    assert_eq!(
        ok(&["split", "down", "--state", "float"]).args["state"],
        "floating"
    );
    let run = ok(&["run", "--state", "minimized", "--", "top"]);
    assert_eq!(run.args["state"], "minimized");
    // run resolves the program on PATH; the state rides along untouched.
    assert!(
        run.args["argv"][0].as_str().unwrap().ends_with("top"),
        "{:?}",
        run.args["argv"]
    );
    assert!(err(&["send", "hi", "--state", "floating"]).contains("send does not take --state"));
    assert!(err(&["tab-new", "--state", "upside-down"]).contains("unknown pane state"));
}

#[test]
fn window_actions_frames_and_fullscreen() {
    assert_eq!(ok(&["window"]).args["action"], "list");
    let new = ok(&[
        "window",
        "new",
        "--cwd",
        "/tmp",
        "--state",
        "floating",
        "--frame",
        "10,20,800,600",
    ]);
    assert_eq!(new.args["action"], "new");
    assert_eq!(new.args["frame"], json!([10.0, 20.0, 800.0, 600.0]));
    assert_eq!(new.args["state"], "floating");

    let frame = ok(&[
        "window", "frame", "--window", "window-1", "--", "-100", "0", "800", "600",
    ]);
    assert_eq!(frame.args["frame"], json!([-100.0, 0.0, 800.0, 600.0]));
    assert_eq!(frame.args["window"], "window-1");
    assert!(
        ok(&["window", "frame"]).args.get("frame").is_none(),
        "no numbers only reads it"
    );
    assert!(err(&["window", "frame", "1", "2", "3"]).contains("four numbers"));
    assert!(err(&["window", "frame", "--frame", "0,0,50,50"]).contains("at least 100 x 60"));
    assert!(err(&["window", "frame", "--frame", "a,0,500,500"]).contains("not a number"));
    assert!(
        err(&["window", "minimize", "--frame", "0,0,500,500"]).contains("does not take a frame")
    );
    assert!(err(&["window", "focus", "--state", "floating"]).contains("does not take --state"));

    assert_eq!(ok(&["window", "fullscreen"]).args["value"], "toggle");
    assert_eq!(ok(&["window", "fullscreen", "OFF"]).args["value"], "off");
    assert!(err(&["window", "fullscreen", "maybe"]).contains("on, off or toggle"));
    assert_eq!(ok(&["window", "unminimize"]).args["action"], "restore");
    let close = ok(&["window", "close", "--force"]);
    assert_eq!(
        (&close.args["action"], &close.args["force"]),
        (&json!("close"), &json!(true))
    );
    assert!(err(&["window", "explode"]).contains("unknown window action"));
    assert!(err(&["tree", "--frame", "0,0,500,500"]).contains("does not take --frame"));
}

#[test]
fn config_reads_and_writes_settings() {
    let list = ok(&["config", "--filter", "font"]);
    assert_eq!(
        (&list.args["action"], &list.args["filter"]),
        (&json!("list"), &json!("font"))
    );
    let get = ok(&["config", "get", "font-size", "theme"]);
    assert_eq!(get.args["keys"], json!(["font-size", "theme"]));
    let set = ok(&[
        "config",
        "set",
        "font-size=14",
        "theme = Dracula",
        "title=a=b",
    ]);
    assert_eq!(
        set.args["settings"],
        json!([
            {"key": "font-size", "value": "14"},
            {"key": "theme", "value": "Dracula"},
            {"key": "title", "value": "a=b"},
        ])
    );
    assert_eq!(
        ok(&["config", "add", "keybind=cmd+k=clear_screen"]).args["settings"][0]["value"],
        "cmd+k=clear_screen"
    );
    assert_eq!(
        ok(&["config", "unset", "theme"]).args["keys"],
        json!(["theme"])
    );
    assert_eq!(ok(&["config", "path"]).args["action"], "path");
    assert_eq!(ok(&["config", "reload"]).args["action"], "reload");

    assert!(err(&["config", "set"]).contains("needs KEY=VALUE"));
    assert!(err(&["config", "set", "font-size"]).contains("expected KEY=VALUE"));
    assert!(err(&["config", "set", "=14"]).contains("cannot be empty"));
    assert!(err(&["config", "get"]).contains("at least one setting"));
    assert!(err(&["config", "unset", "theme=x"]).contains("not KEY=VALUE"));
    assert!(
        err(&["config", "get", "theme", "--filter", "x"]).contains("--filter is for config list")
    );
    assert!(err(&["config", "wipe"]).contains("unknown config action"));
}

#[test]
fn pane_window_and_config_answers_read_as_lines() {
    let pane = json!({"id": "p1", "state": "minimized", "restoresTo": "maximized", "shown": false});
    assert_eq!(
        render("pane", &pane),
        "p1  minimized (restores to maximized)  [tab not shown]\n"
    );
    assert_eq!(
        render("pane", &json!({"id": "p1", "window": "window-9"})),
        "p1 moved to window-9\n"
    );

    let window = json!({"id": "window-1", "tabs": 2, "minimized": false, "fullscreen": true, "key": true,
                        "frame": {"x": 0, "y": 25.4, "width": 1280, "height": 800}});
    assert_eq!(
        render("window", &json!({"windows": [window.clone()]})),
        "window-1  2 tabs  1280x800 at 0,25  fullscreen  key\n"
    );
    assert_eq!(
        render("window", &window),
        "window-1  2 tabs  1280x800 at 0,25  fullscreen  key\n"
    );
    assert_eq!(
        render("window", &json!({"id": "p2", "window": "window-2"})),
        "p2\n"
    );
    assert_eq!(
        render(
            "window",
            &json!({"window": "window-2", "state": "cancelled"})
        ),
        "cancelled\n"
    );

    let config = json!({"settings": [
        {"key": "font-size", "set": true, "value": "14"},
        {"key": "theme", "set": false, "value": "TakoCore"},
        {"key": "title", "set": false, "value": null},
        {"key": "keybind", "set": true, "values": ["cmd+k=clear_screen", "cmd+j=jump"]},
        {"key": "palette", "set": false, "values": []},
    ], "errors": ["unknown configuration key: nope"]});
    assert_eq!(
        render("config", &config),
        "font-size = 14\n# theme = TakoCore (default)\n# title (not set)\n\
         keybind = cmd+k=clear_screen\nkeybind = cmd+j=jump\n# palette (not set)\n\
         error: unknown configuration key: nope\n"
    );
    assert_eq!(
        render("config", &json!({"path": "/x/config"})),
        "/x/config\n"
    );
    assert_eq!(
        render("config", &json!({"reloaded": true, "errors": []})),
        "reloaded\n"
    );
}

#[test]
fn the_tree_says_when_a_pane_is_off_the_grid() {
    let tree = json!({"windows": [{"id": "w", "tabs": [{"id": "t", "panes": [
        {"id": "a", "cwd": "/", "title": "x", "state": "tiled"},
        {"id": "b", "cwd": "/", "title": "y", "state": "floating"},
    ]}]}]});
    let out = render("tree", &tree);
    assert!(out.contains(" a  /  x\n"), "{out}");
    assert!(out.contains(" b  /  y  <floating>\n"), "{out}");
}

#[test]
fn usage_names_every_new_command() {
    for line in [
        "pane set STATE",
        "window new",
        "window fullscreen",
        "config set KEY=VALUE",
        "--state STATE",
    ] {
        assert!(USAGE.contains(line), "{line}");
    }
}

#[test]
fn pane_frames_and_shortcuts_parse() {
    let frame = ok(&[
        "pane", "frame", "--target", "p", "--", "-10", "20", "600", "400",
    ]);
    assert_eq!(frame.args["action"], "frame");
    assert_eq!(frame.args["frame"], json!([-10.0, 20.0, 600.0, 400.0]));
    assert_eq!(
        ok(&["pane", "frame", "--frame", "0,0,600,400"]).args["frame"][2],
        600.0
    );
    assert!(ok(&["pane", "frame"]).args.get("frame").is_none());
    assert!(err(&["pane", "float", "--frame", "0,0,600,400"]).contains("does not take a frame"));
    assert!(err(&["pane", "frame", "1", "2"]).contains("four numbers"));

    let list = ok(&["config", "shortcut"]);
    assert_eq!(
        (&list.args["action"], &list.args["op"]),
        (&json!("shortcut"), &json!("list"))
    );
    let set = ok(&[
        "config",
        "shortcut",
        "set",
        "goto_tab:3",
        "cmd+3",
        "--force",
    ]);
    assert_eq!(
        (
            &set.args["op"],
            &set.args["name"],
            &set.args["trigger"],
            &set.args["force"]
        ),
        (
            &json!("set"),
            &json!("goto_tab:3"),
            &json!("cmd+3"),
            &json!(true)
        )
    );
    assert_eq!(
        ok(&["config", "shortcut", "unset", "new_tab"]).args["name"],
        "new_tab"
    );
    assert_eq!(ok(&["config", "shortcuts", "reset"]).args["op"], "reset");
    assert!(err(&["config", "shortcut", "set", "new_tab"]).contains("ACTION and a TRIGGER"));
    assert!(err(&["config", "shortcut", "unset"]).contains("needs an ACTION"));
    assert!(err(&["config", "shortcut", "reset", "--force"]).contains("--force is for"));
    assert!(err(&["config", "shortcut", "set", "a", "b", "c"]).contains("unexpected argument"));
    assert!(err(&["config", "shortcut", "bind"]).contains("unknown shortcut action"));
}

#[test]
fn pane_frames_and_shortcuts_render() {
    let pane = json!({"id": "p1", "state": "floating", "frame": {"x": 12, "y": 30, "width": 600, "height": 400}});
    assert_eq!(render("pane", &pane), "p1  floating  600x400 at 12,30\n");
    let shortcuts = json!({"shortcuts": [
        {"action": "new_tab", "trigger": "cmd+t", "custom": false, "title": "New Tab"},
        {"action": "goto_tab:3", "trigger": "ctrl+3", "custom": true, "title": "Switch to Tab 3"},
        {"action": "quit", "trigger": null, "custom": false, "title": "Quit Tako"},
    ], "errors": []});
    let out = render("config", &shortcuts);
    let lines: Vec<&str> = out.lines().collect();
    assert_eq!(lines.len(), 3, "{out}");
    assert!(
        lines[0].starts_with(" new_tab")
            && lines[0].contains("cmd+t")
            && lines[0].ends_with("New Tab")
    );
    assert!(lines[1].starts_with("*goto_tab:3") && lines[1].contains("ctrl+3"));
    assert!(lines[2].contains(" - "), "{out}");
}
