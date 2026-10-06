/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::common::*;

/// Upstream test: "kitty: plain text"
#[test]
fn kitty_plain_text() {
    let ev = make_key_event_full(
        Key::Char('a'),
        Mods::empty(),
        true,
        false,
        None,
        Some("abcd"),
        false,
    );
    assert_eq!(encode(ev, cfg(1)), b"abcd");
}

/// Upstream test: "kitty: repeat with just disambiguate"
#[test]
fn kitty_repeat_with_just_disambiguate() {
    let ev = make_key_event(Key::Char('a'), Mods::empty(), true, true, None);
    assert_eq!(encode(ev, cfg(1)), b"a");
}

/// Upstream test: "kitty: enter, backspace, tab"
#[test]
fn kitty_enter_backspace_tab() {
    assert_eq!(
        encode(
            make_key_event(Key::Enter, Mods::empty(), true, false, None),
            cfg(1)
        ),
        b"\r"
    );
    assert_eq!(
        encode(
            make_key_event(Key::Backspace, Mods::empty(), true, false, None),
            cfg(1)
        ),
        b"\x7f"
    );
    assert_eq!(
        encode(
            make_key_event(Key::Backspace, Mods::empty(), true, false, None),
            cfg(1)
        ),
        b"\x7f"
    );
    assert_eq!(
        encode(
            make_key_event(Key::Tab, Mods::empty(), true, false, None),
            cfg(1)
        ),
        b"\t"
    );

    // No release events if "report_all" is not set
    assert_eq!(
        encode(
            make_key_event(Key::Enter, Mods::empty(), false, false, None),
            cfg(3)
        ),
        b""
    );
    assert_eq!(
        encode(
            make_key_event(Key::Backspace, Mods::empty(), false, false, None),
            cfg(3)
        ),
        b""
    );
    assert_eq!(
        encode(
            make_key_event(Key::Tab, Mods::empty(), false, false, None),
            cfg(3)
        ),
        b""
    );

    // Release events if "report_all" is set
    assert_eq!(
        encode(
            make_key_event(Key::Enter, Mods::empty(), false, false, None),
            cfg(11)
        ),
        b"\x1b[13;1:3u"
    );
    assert_eq!(
        encode(
            make_key_event(Key::Backspace, Mods::empty(), false, false, None),
            cfg(11)
        ),
        b"\x1b[127;1:3u"
    );
    assert_eq!(
        encode(
            make_key_event(Key::Tab, Mods::empty(), false, false, None),
            cfg(11)
        ),
        b"\x1b[9;1:3u"
    );
}

/// Upstream test: "kitty: shift+backspace emits CSI u"
#[test]
fn kitty_shift_backspace_emits_csi_u() {
    let ev = make_key_event(Key::Backspace, Mods::SHIFT, true, false, None);
    assert_eq!(encode(ev, cfg(1)), b"\x1b[127;2u");
}

/// Upstream test: "kitty: shift+enter emits CSI u"
#[test]
fn kitty_shift_enter_emits_csi_u() {
    let ev = make_key_event(Key::Enter, Mods::SHIFT, true, false, None);
    assert_eq!(encode(ev, cfg(1)), b"\x1b[13;2u");
}

/// Upstream test: "kitty: shift+tab emits CSI u"
#[test]
fn kitty_shift_tab_emits_csi_u() {
    let ev = make_key_event(Key::Tab, Mods::SHIFT, true, false, None);
    assert_eq!(encode(ev, cfg(1)), b"\x1b[9;2u");
}

/// Upstream test: "kitty: enter with all flags"
#[test]
fn kitty_enter_with_all_flags() {
    let ev = make_key_event(Key::Enter, Mods::empty(), true, false, None);
    let actual = encode(ev, cfg(31));
    assert_eq!(&actual[1..], b"[13u");
}

/// Upstream test: "kitty: ctrl with all flags"
#[test]
fn kitty_ctrl_with_all_flags() {
    let ev = make_key_event(Key::ControlLeft, Mods::CTRL, true, false, None);
    let actual = encode(ev, cfg(31));
    assert_eq!(&actual[1..], b"[57442;5u");
}

/// Upstream test: "kitty: ctrl release with ctrl mod set"
#[test]
fn kitty_ctrl_release_with_ctrl_mod_set() {
    let ev = make_key_event(Key::ControlLeft, Mods::CTRL, false, false, None);
    let actual = encode(ev, cfg(31));
    assert_eq!(&actual[1..], b"[57442;5:3u");
}

/// Upstream test: "kitty: delete"
#[test]
fn kitty_delete() {
    let ev = make_key_event(Key::Delete, Mods::empty(), true, false, None);
    assert_eq!(encode(ev, cfg(1)), b"\x1b[3~");
}

/// Upstream test: "kitty: composing with no modifier"
#[test]
fn kitty_composing_with_no_modifier() {
    let ev = make_key_event_full(Key::Char('a'), Mods::SHIFT, true, false, None, None, true);
    assert_eq!(encode(ev, cfg(1)), b"");
}

/// Upstream test: "kitty: composing with modifier"
#[test]
fn kitty_composing_with_modifier() {
    // While composing, only a plain modifier-key event is still sent
    // (upstream: `entry.modifier` breaks the composing suppression), and
    // only under report_all.
    let ev = make_key_event_full(Key::ShiftLeft, Mods::SHIFT, true, false, None, None, true);
    let actual = encode(ev, cfg(9)); // disambiguate + report_all
    assert_eq!(&actual[..], b"\x1b[57441;2u");
}

/// Upstream test: "kitty: composed text with report all"
#[test]
fn kitty_composed_text_with_report_all() {
    let ev = make_key_event_full(
        Key::Unidentified,
        Mods::empty(),
        true,
        false,
        None,
        Some("\u{fb}"),
        false,
    );
    assert_eq!(encode(ev, cfg(31)), "\u{fb}".as_bytes());
}
