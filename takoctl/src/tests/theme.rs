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
use serde_json::{Value, json};
use std::io::{self, Read};

fn parsed(tokens: &[&str]) -> Value {
    let mut argv = vec!["theme"];
    argv.extend(tokens);
    Value::Object(parse(&args(&argv)).unwrap().args)
}

#[test]
fn theme_actions_serialize() {
    for action in ["list", "fonts", "keys"] {
        assert_eq!(parsed(&[action]), json!({"action": action}));
    }
    assert_eq!(parsed(&[]), json!({"action": "list"}));
    for action in ["show", "delete", "create"] {
        assert_eq!(
            parsed(&[action, "Midnight"]),
            json!({"action": action, "name": "Midnight"})
        );
    }
    assert_eq!(
        parsed(&["rename", "Old", "New"]),
        json!({"action":"rename", "name":"Old", "new_name":"New"})
    );
    let expected = json!({"action":"create", "name":"New", "from_theme":"Old"});
    assert_eq!(parsed(&["copy", "Old", "New"]), expected);
    assert_eq!(parsed(&["create", "New", "--from", "Old"]), expected);
    let opts = parse(&args(&[
        "--json",
        "--client",
        "test",
        "theme",
        "create",
        "New",
        "--from",
        "Old",
        "--socket",
        "/tmp/theme-test.sock",
    ]))
    .unwrap();
    assert!(opts.json);
    assert_eq!(opts.socket.as_deref(), Some("/tmp/theme-test.sock"));
    assert_eq!(
        request(&opts, Some("origin".into())),
        json!({"cmd":"theme", "args":expected, "from":"origin", "client":"test"})
    );
}

#[test]
fn theme_scopes_defaults_and_aliases() {
    assert_eq!(
        parsed(&["current"]),
        json!({"action":"current", "scope":"pane"})
    );
    for action in ["apply", "reset", "current"] {
        let mut tokens = vec![action];
        if action == "apply" {
            tokens.push("Night");
        }
        for (flag, value, scope, key) in [
            ("--workspace", "work", "workspace", "workspace"),
            ("--target", "pane1", "pane", "target"),
            ("--pane", "pane1", "pane", "target"),
            ("--session", "pane1", "pane", "target"),
        ] {
            let mut scoped = tokens.clone();
            scoped.extend([flag, value]);
            let got = parsed(&scoped);
            assert_eq!(got["scope"], scope);
            assert_eq!(got[key], value);
            assert_eq!(got["action"], action);
            assert!(got.get("session").is_none());
        }
        tokens.push("--global");
        let got = parsed(&tokens);
        assert_eq!(got["scope"], "global");
        assert!(got.get("target").is_none());
        assert!(got.get("workspace").is_none());
    }
    let opts = parse(&args(&["--target", "p", "theme", "current"])).unwrap();
    assert_eq!(opts.args["target"], "p");
    assert_eq!(request(&opts, Some("origin".into()))["from"], "origin");
}

#[test]
fn theme_rejects_scope_conflicts_and_invalid_arguments() {
    for tokens in [
        vec!["apply", "Night"],
        vec!["reset"],
        vec!["apply", "Night", "--global", "--workspace", "w"],
        vec!["current", "--workspace", "w", "--session", "p"],
        vec!["reset", "--target", "p", "--pane", "p"],
        vec!["current", "--target", "p", "--session", "p"],
        vec!["current", "--global", "--global"],
        vec!["show", "Night", "--global"],
        vec!["list", "extra"],
        vec!["fonts", "extra"],
        vec!["keys", "extra"],
        vec!["show"],
        vec!["rename", "Old"],
        vec!["copy", "Old"],
        vec!["delete"],
        vec!["delete", "Night", "--force"],
        vec!["set", "Night"],
        vec!["set", "Night", "bad"],
        vec!["set", "Night", "=value"],
        vec!["set", "Night", " =value"],
        vec!["unset", "Night", ""],
        vec!["unset", "Night", "key=value"],
        vec!["unknown"],
        vec!["current", "--target"],
        vec!["current", "--workspace", ""],
        vec!["create", "Night", "--from"],
        vec!["set", "Night", "--from", "Old"],
        vec!["create", "Night", "--from", "Old", "--stdin"],
        vec!["create", "Night", "--from", "Old", "--from", "Other"],
    ] {
        let mut argv = vec!["theme"];
        argv.extend(tokens);
        assert!(parse(&args(&argv)).is_err(), "{argv:?}");
    }
}

#[test]
fn theme_settings_preserve_order_equals_spaces_and_arbitrary_keys() {
    let got = parsed(&[
        "set",
        "Night",
        "palette:7=#aabbcc",
        "font-family=My Font",
        "font-feature=+liga",
        "font-feature=-calt",
        "custom-shader=a=b c",
        "custom-shader=second",
        "future-key=",
        "background=#000000",
    ]);
    assert_eq!(
        got,
        json!({"action":"set", "name":"Night", "settings":[
            {"key":"palette:7","value":"#aabbcc"}, {"key":"font-family","value":"My Font"},
            {"key":"font-feature","value":"+liga"}, {"key":"font-feature","value":"-calt"},
            {"key":"custom-shader","value":"a=b c"}, {"key":"custom-shader","value":"second"},
            {"key":"future-key","value":""}, {"key":"background","value":"#000000"}
        ]})
    );
    assert_eq!(
        parsed(&["unset", "Night", "font-feature", "palette:7"]),
        json!({"action":"set","name":"Night","settings":[{"key":"font-feature","value":null},{"key":"palette:7","value":null}]})
    );
}

struct BrokenReader;
impl Read for BrokenReader {
    fn read(&mut self, _: &mut [u8]) -> io::Result<usize> {
        Err(io::Error::other("injected read failure"))
    }
}

#[test]
fn theme_stdin_loading_and_failures() {
    for action in ["create", "set"] {
        let opts = cli::theme::parse_with_reader(
            &args(&["theme", action, "Night", "--stdin"]),
            0,
            &mut "font-family = My Font\n".as_bytes(),
        )
        .unwrap();
        assert_eq!(opts.args["config"], "font-family = My Font\n");
        assert!(!opts.args.contains_key("stdin"));
        assert!(!opts.args.contains_key("settings"));
    }
    let argv = args(&["theme", "create", "Night", "--stdin"]);
    assert!(
        cli::theme::parse_with_reader(&argv, 0, &mut BrokenReader)
            .unwrap_err()
            .contains("injected read failure")
    );
    assert!(
        cli::theme::parse_with_reader(&argv, 0, &mut &[0xff][..])
            .unwrap_err()
            .contains("UTF-8")
    );
    assert!(
        cli::theme::parse_with_reader(&argv, 0, &mut &vec![b'a'; (1 << 20) + 1][..])
            .unwrap_err()
            .contains("limit")
    );
    // Within the raw bound, but too large after JSON escaping.
    assert!(
        cli::theme::parse_with_reader(&argv, 0, &mut &vec![b'\n'; 1 << 19][..])
            .unwrap_err()
            .contains("request limit")
    );
    let empty = cli::theme::parse_with_reader(&argv, 0, &mut io::empty()).unwrap();
    assert_eq!(empty.args["config"], "");
}

#[test]
fn theme_file_loading_and_conflicts_before_io() {
    let path = std::env::temp_dir().join(format!(
        "tako-theme-{}-{}.conf",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let file = path.to_str().unwrap();
    std::fs::write(&path, "palette = 7=#abcdef\n").unwrap();
    for action in ["create", "set"] {
        let got = parsed(&[action, "Night", "--file", file]);
        assert_eq!(got["config"], "palette = 7=#abcdef\n");
        assert!(got.get("file").is_none());
    }
    std::fs::write(&path, [0xff]).unwrap();
    assert!(
        parse(&args(&["theme", "set", "Night", "--file", file]))
            .unwrap_err()
            .contains("UTF-8")
    );
    std::fs::remove_file(&path).unwrap();
    assert!(
        parse(&args(&["theme", "create", "Night", "--file", file]))
            .unwrap_err()
            .contains("cannot read theme file")
    );
    for tail in [
        vec!["--file", file, "--stdin"],
        vec!["--file", file, "--from", "Old"],
        vec!["--stdin", "key=value"],
        vec!["--file", file, "key=value"],
    ] {
        let mut argv = vec!["theme", "set", "Night"];
        argv.extend(tail);
        let error = cli::theme::parse_with_reader(&args(&argv), 0, &mut BrokenReader).unwrap_err();
        assert!(!error.contains("cannot read"), "{error}");
    }
}

#[test]
fn theme_json_and_human_rendering() {
    let response = json!({"ok":true,"result":{"name":"Night", "config":"font-family = My Font\nbackground = #000000", "is_user":true,"path":"/themes/Night"}});
    assert_eq!(
        reports::theme::answer(false, &response),
        "font-family = My Font\nbackground = #000000"
    );
    assert_eq!(
        serde_json::from_str::<Value>(&reports::theme::answer(true, &response)).unwrap(),
        response
    );
    let error = json!({"ok":false,"error":{"code":"referenced","message":"in use"}});
    assert_eq!(
        serde_json::from_str::<Value>(&reports::theme::answer(true, &error)).unwrap(),
        error
    );
    let current = json!({"scope":"workspace","scope_id":"w", "theme":null,"effective_config":"font-size = 14\nfont-feature = +liga\n", "overrides":{}});
    assert_eq!(
        render("theme", &current),
        "# workspace w: inherit\nfont-size = 14\nfont-feature = +liga\n"
    );
    assert_eq!(
        render(
            "theme",
            &json!({"themes":[{"name":"Night","is_user":true,"path":"/themes/Night"},{"name":"Day","is_user":false}]})
        ),
        "Night (user)  /themes/Night\nDay (builtin)\n"
    );
    assert_eq!(
        render("theme", &json!({"fonts":["My Font","Other Font"]})),
        "My Font\nOther Font\n"
    );
    assert_eq!(
        render("theme", &json!({"keys":["font-feature","palette"]})),
        "font-feature\npalette\n"
    );
    assert_eq!(
        render(
            "theme",
            &json!({"action":"apply","name":"Night","scope":"global"})
        ),
        "apply Night (global)\n"
    );
}
