/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

// XTMODKEYS modifyOtherKeys: vim and others ask for level 2 (`CSI > 4 ; 2 m`)
// so ctrl, alt and shift combinations stop colliding with plain keys. The
// terminal remembers the level, reports it, carries it in checkpoints, and
// the key encoder follows it.

use tako_core::ffi::{FfiKey, FfiKeyEvent, TakoCore};
use tako_core::terminal::Terminal;

fn reply(term: &mut Terminal, bytes: &[u8]) -> String {
    term.feed(bytes);
    String::from_utf8(term.take_output()).unwrap()
}

#[test]
fn it_is_off_until_a_program_asks() {
    let mut term = Terminal::new(20, 4);
    assert_eq!(term.modes().modify_other_keys, 0);
    assert_eq!(reply(&mut term, b"\x1b[?4m"), "\x1b[>4;0m");
}

#[test]
fn level_two_is_remembered_and_reported() {
    let mut term = Terminal::new(20, 4);
    term.feed(b"\x1b[>4;2m");
    assert_eq!(term.modes().modify_other_keys, 2);
    assert_eq!(reply(&mut term, b"\x1b[?4m"), "\x1b[>4;2m");
    term.feed(b"\x1b[>4;1m");
    assert_eq!(reply(&mut term, b"\x1b[?4m"), "\x1b[>4;1m");
}

#[test]
fn a_level_above_two_is_taken_as_two() {
    let mut term = Terminal::new(20, 4);
    term.feed(b"\x1b[>4;9m");
    assert_eq!(term.modes().modify_other_keys, 2);
}

#[test]
fn leaving_out_the_value_or_every_parameter_turns_it_off() {
    let mut term = Terminal::new(20, 4);
    term.feed(b"\x1b[>4;2m\x1b[>4m");
    assert_eq!(term.modes().modify_other_keys, 0, "CSI > 4 m");
    term.feed(b"\x1b[>4;2m\x1b[>m");
    assert_eq!(term.modes().modify_other_keys, 0, "CSI > m");
}

#[test]
fn the_disable_form_turns_it_off() {
    let mut term = Terminal::new(20, 4);
    term.feed(b"\x1b[>4;2m\x1b[>4n");
    assert_eq!(term.modes().modify_other_keys, 0);
}

#[test]
fn another_resource_leaves_it_alone() {
    let mut term = Terminal::new(20, 4);
    term.feed(b"\x1b[>4;2m\x1b[>1;2m");
    assert_eq!(term.modes().modify_other_keys, 2);
}

#[test]
fn the_other_resources_report_what_the_encoder_always_does() {
    let mut term = Terminal::new(20, 4);
    assert_eq!(
        reply(&mut term, b"\x1b[?0m"),
        "\x1b[>0;0m",
        "modifyKeyboard"
    );
    assert_eq!(
        reply(&mut term, b"\x1b[?1m"),
        "\x1b[>1;2m",
        "modifyCursorKeys"
    );
    assert_eq!(
        reply(&mut term, b"\x1b[?2m"),
        "\x1b[>2;2m",
        "modifyFunctionKeys"
    );
    assert_eq!(
        reply(&mut term, b"\x1b[?3m"),
        "\x1b[>3;0m",
        "modifyKeypadKeys"
    );
    assert_eq!(reply(&mut term, b"\x1b[?9m"), "", "no such resource");
}

#[test]
fn a_reset_turns_it_off() {
    let mut term = Terminal::new(20, 4);
    term.feed(b"\x1b[>4;2m\x1bc");
    assert_eq!(term.modes().modify_other_keys, 0);
}

#[test]
fn a_checkpoint_carries_it() {
    let mut term = Terminal::new(20, 4);
    term.feed(b"\x1b[>4;2m");
    let restored =
        tako_core::terminal::checkpoint::import(&term.export_checkpoint().unwrap()).unwrap();
    assert_eq!(restored.modes().modify_other_keys, 2);

    let plain = Terminal::new(20, 4);
    let restored =
        tako_core::terminal::checkpoint::import(&plain.export_checkpoint().unwrap()).unwrap();
    assert_eq!(restored.modes().modify_other_keys, 0);
}

fn ctrl(letter: char) -> FfiKeyEvent {
    FfiKeyEvent {
        key: FfiKey::Character,
        text: String::new(),
        physical_text: letter.to_string(),
        unshifted_text: letter.to_string(),
        shift: false,
        alt: false,
        ctrl: true,
        super_key: false,
        press: true,
        repeat: false,
        composing: false,
    }
}

#[test]
fn the_key_encoder_follows_what_the_program_asked_for() {
    // ctrl+i has no C0 byte of its own (that would be Tab). Without
    // modifyOtherKeys it goes out in the fixterms form; at level 2, in
    // xterm's.
    let core = TakoCore::new(20, 4);
    assert_eq!(core.encode_key(ctrl('i')), b"\x1b[105;5u".to_vec());
    core.feed(b"\x1b[>4;2m".to_vec());
    assert_eq!(core.encode_key(ctrl('i')), b"\x1b[27;5;105~".to_vec());
    core.feed(b"\x1b[>4;1m".to_vec());
    assert_eq!(
        core.encode_key(ctrl('i')),
        b"\x1b[105;5u".to_vec(),
        "level 1 encodes like off"
    );
    // ctrl+c keeps its interrupt byte at every level.
    core.feed(b"\x1b[>4;2m".to_vec());
    assert_eq!(core.encode_key(ctrl('c')), vec![0x03]);
}
