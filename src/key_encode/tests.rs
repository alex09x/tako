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

fn press(key: Key) -> KeyEvent {
    KeyEvent {
        key,
        mods: Mods::empty(),
        repeat: false,
        press: true,
        unshifted: None,
        physical: None,
        text: None,
        composing: false,
    }
}

fn press_mod(key: Key, mods: Mods) -> KeyEvent {
    KeyEvent {
        key,
        mods,
        repeat: false,
        press: true,
        unshifted: None,
        physical: None,
        text: None,
        composing: false,
    }
}

#[test]
fn test_plain_letters() {
    let cfg = EncodeConfig::default();
    assert_eq!(encode(press(Key::Char('a')), cfg), b"a");
    assert_eq!(encode(press(Key::Char('Z')), cfg), b"Z");
    assert_eq!(encode(press(Key::Char('ñ')), cfg), "ñ".as_bytes());
}

#[test]
fn test_ctrl_codes() {
    let cfg = EncodeConfig::default();
    assert_eq!(encode(press_mod(Key::Char('a'), Mods::CTRL), cfg), b"\x01");
    assert_eq!(encode(press_mod(Key::Char('A'), Mods::CTRL), cfg), b"\x01");
    assert_eq!(encode(press_mod(Key::Char('z'), Mods::CTRL), cfg), b"\x1a");
    assert_eq!(encode(press_mod(Key::Char('@'), Mods::CTRL), cfg), b"\x00");
    assert_eq!(encode(press_mod(Key::Char('_'), Mods::CTRL), cfg), b"\x1f");
    assert_eq!(encode(press_mod(Key::Space, Mods::CTRL), cfg), b"\x00");
}

#[test]
fn test_alt_prefixing() {
    let cfg = EncodeConfig {
        alt_esc_prefix: true,
        ..Default::default()
    };

    assert_eq!(encode(press_mod(Key::Char('a'), Mods::ALT), cfg), b"\x1ba");
    assert_eq!(
        encode(press_mod(Key::Char('a'), Mods::CTRL | Mods::ALT), cfg),
        b"\x1b\x01"
    );
    assert_eq!(encode(press_mod(Key::Enter, Mods::ALT), cfg), b"\x1b\r");

    let cfg_no_alt = EncodeConfig {
        alt_esc_prefix: false,
        ..Default::default()
    };
    assert_eq!(
        encode(press_mod(Key::Char('a'), Mods::ALT), cfg_no_alt),
        b"a"
    );
}

#[test]
fn test_named_keys() {
    let cfg = EncodeConfig::default();
    assert_eq!(encode(press(Key::Enter), cfg), b"\r");
    assert_eq!(encode(press(Key::Tab), cfg), b"\t");
    assert_eq!(encode(press_mod(Key::Tab, Mods::SHIFT), cfg), b"\x1b[Z");
    assert_eq!(encode(press(Key::Backspace), cfg), b"\x7f");
    assert_eq!(encode(press_mod(Key::Backspace, Mods::CTRL), cfg), b"\x08");
    assert_eq!(encode(press(Key::Escape), cfg), b"\x1b");
    assert_eq!(encode(press(Key::Space), cfg), b" ");
}

#[test]
fn test_arrows_normal_and_app_mode() {
    let cfg_norm = EncodeConfig {
        cursor_key_app_mode: false,
        ..Default::default()
    };
    assert_eq!(encode(press(Key::Up), cfg_norm), b"\x1b[A");
    assert_eq!(encode(press(Key::Down), cfg_norm), b"\x1b[B");
    assert_eq!(encode(press(Key::Right), cfg_norm), b"\x1b[C");
    assert_eq!(encode(press(Key::Left), cfg_norm), b"\x1b[D");

    let cfg_app = EncodeConfig {
        cursor_key_app_mode: true,
        ..Default::default()
    };
    assert_eq!(encode(press(Key::Up), cfg_app), b"\x1bOA");
    assert_eq!(encode(press(Key::Down), cfg_app), b"\x1bOB");
    assert_eq!(encode(press(Key::Right), cfg_app), b"\x1bOC");
    assert_eq!(encode(press(Key::Left), cfg_app), b"\x1bOD");
}

#[test]
fn test_arrows_modifiers() {
    let cfg = EncodeConfig::default();
    // {m} = 1 + (shift?1:0) + (alt?2:0) + (ctrl?4:0) + (super?8:0)
    assert_eq!(encode(press_mod(Key::Up, Mods::SHIFT), cfg), b"\x1b[1;2A");
    assert_eq!(encode(press_mod(Key::Up, Mods::ALT), cfg), b"\x1b[1;3A");
    assert_eq!(encode(press_mod(Key::Up, Mods::CTRL), cfg), b"\x1b[1;5A");
    assert_eq!(encode(press_mod(Key::Up, Mods::SUPER), cfg), b"\x1b[1;9A");

    // Combination: SHIFT + CTRL = 1 + 1 + 4 = 6
    assert_eq!(
        encode(press_mod(Key::Up, Mods::SHIFT | Mods::CTRL), cfg),
        b"\x1b[1;6A"
    );
    // All mods: 1 + 1 + 2 + 4 + 8 = 16
    assert_eq!(
        encode(
            press_mod(Key::Up, Mods::SHIFT | Mods::ALT | Mods::CTRL | Mods::SUPER),
            cfg
        ),
        b"\x1b[1;16A"
    );
}

#[test]
fn test_home_end() {
    let mut cfg = EncodeConfig::default();
    assert_eq!(encode(press(Key::Home), cfg), b"\x1b[H");
    assert_eq!(encode(press(Key::End), cfg), b"\x1b[F");

    cfg.cursor_key_app_mode = true;
    assert_eq!(encode(press(Key::Home), cfg), b"\x1bOH");
    assert_eq!(encode(press(Key::End), cfg), b"\x1bOF");

    assert_eq!(encode(press_mod(Key::Home, Mods::CTRL), cfg), b"\x1b[1;5H");
    assert_eq!(encode(press_mod(Key::End, Mods::ALT), cfg), b"\x1b[1;3F");
}

#[test]
fn test_insert_delete_page() {
    let cfg = EncodeConfig::default();
    assert_eq!(encode(press(Key::Insert), cfg), b"\x1b[2~");
    assert_eq!(encode(press(Key::Delete), cfg), b"\x1b[3~");
    assert_eq!(encode(press(Key::PageUp), cfg), b"\x1b[5~");
    assert_eq!(encode(press(Key::PageDown), cfg), b"\x1b[6~");

    assert_eq!(
        encode(press_mod(Key::Insert, Mods::SHIFT), cfg),
        b"\x1b[2;2~"
    );
    assert_eq!(
        encode(press_mod(Key::Delete, Mods::CTRL), cfg),
        b"\x1b[3;5~"
    );
}

#[test]
fn test_f1_f4() {
    let cfg = EncodeConfig::default();
    assert_eq!(encode(press(Key::F1), cfg), b"\x1bOP");
    assert_eq!(encode(press(Key::F2), cfg), b"\x1bOQ");
    // F3 is the one named function key with no SS3 letter of its own --
    // it shares Enter's code (13) and the tilde form instead (upstream's
    // function-key table; see also `kitty_entry`).
    assert_eq!(encode(press(Key::F3), cfg), b"\x1b[13~");
    assert_eq!(encode(press(Key::F4), cfg), b"\x1bOS");

    assert_eq!(encode(press_mod(Key::F1, Mods::ALT), cfg), b"\x1b[1;3P");
    assert_eq!(encode(press_mod(Key::F3, Mods::CTRL), cfg), b"\x1b[13;5~");
    assert_eq!(encode(press_mod(Key::F4, Mods::CTRL), cfg), b"\x1b[1;5S");
}

#[test]
fn test_f5_f12() {
    let cfg = EncodeConfig::default();
    assert_eq!(encode(press(Key::F5), cfg), b"\x1b[15~");
    assert_eq!(encode(press(Key::F12), cfg), b"\x1b[24~");

    assert_eq!(encode(press_mod(Key::F5, Mods::CTRL), cfg), b"\x1b[15;5~");
    assert_eq!(encode(press_mod(Key::F12, Mods::SHIFT), cfg), b"\x1b[24;2~");
}

#[test]
fn test_keypad() {
    let mut cfg = EncodeConfig {
        keypad_app_mode: false,
        ..Default::default()
    };
    assert_eq!(encode(press(Key::KeypadEnter), cfg), b"\r");
    assert_eq!(encode(press(Key::KeypadPlus), cfg), b"+");
    assert_eq!(encode(press(Key::KeypadMinus), cfg), b"-");
    assert_eq!(encode(press(Key::KeypadMultiply), cfg), b"*");
    assert_eq!(encode(press(Key::KeypadDivide), cfg), b"/");

    cfg.keypad_app_mode = true;
    assert_eq!(encode(press(Key::KeypadEnter), cfg), b"\x1bOM");
    assert_eq!(encode(press(Key::KeypadPlus), cfg), b"\x1bOk");
    assert_eq!(encode(press(Key::KeypadMinus), cfg), b"\x1bOm");
    assert_eq!(encode(press(Key::KeypadMultiply), cfg), b"\x1bOj");
    assert_eq!(encode(press(Key::KeypadDivide), cfg), b"\x1bOo");
}

#[test]
fn test_kitty_csi_u_disambiguate() {
    let cfg = EncodeConfig {
        kitty_flags: 1,
        ..Default::default()
    }; // DISAMBIGUATE

    assert_eq!(encode(press(Key::Escape), cfg), b"\x1b[27u");
    // Enter/Tab/Backspace keep their legacy bytes under disambiguate
    // alone (upstream "kitty: enter, backspace, tab"): the mode exists
    // to disambiguate escape sequences from typed text, and these three
    // still work as `reset` after a crashed program leaves the mode set.
    assert_eq!(encode(press(Key::Enter), cfg), b"\r");
    // Upstream's "kitty: plain text": with only disambiguate, a key
    // whose purpose is text sends that text. Shift alone does not
    // change that -- shift is how you type a capital.
    assert_eq!(encode(press(Key::Char('a')), cfg), b"a");
    assert_eq!(encode(press_mod(Key::Char('A'), Mods::SHIFT), cfg), b"A");
    assert_eq!(encode(press_mod(Key::Tab, Mods::SHIFT), cfg), b"\x1b[9;2u");
}

#[test]
fn test_kitty_event_types() {
    let cfg = EncodeConfig {
        kitty_flags: 2,
        ..Default::default()
    }; // REPORT_EVENT_TYPES

    // Up has no committed text, so (unlike a plain character key) it
    // never takes the plain-text passthrough shortcut and cleanly
    // demonstrates event-type reporting. Kitty omits the modifier/event
    // section entirely for a plain press with no modifiers (upstream's
    // `KittySequence.encodeFull`/`encodeSpecial`: the section is only
    // written when the event is repeat/release, or `mods > 1`).
    assert_eq!(encode(press(Key::Up), cfg), b"\x1b[A");

    let mut repeat_up = press(Key::Up);
    repeat_up.repeat = true;
    assert_eq!(encode(repeat_up, cfg), b"\x1b[1;1:2A");

    let mut release_up = press(Key::Up);
    release_up.press = false;
    assert_eq!(encode(release_up, cfg), b"\x1b[1;1:3A");

    // A character key still reports its event type once a real modifier
    // forces the mods/event section to appear. `unshifted` must be set
    // for a plain letter to get a table entry at all -- like upstream,
    // a bare `Key::Char` with no unshifted codepoint has nothing to
    // derive one from and just sends its text verbatim.
    let mut release_a = press_mod(Key::Char('a'), Mods::SHIFT);
    release_a.unshifted = Some('a');
    release_a.press = false;
    assert_eq!(encode(release_a, cfg), b"\x1b[97;2:3u");
}

#[test]
fn test_legacy_release_yields_empty() {
    let cfg = EncodeConfig::default();
    let mut release_a = press(Key::Char('a'));
    release_a.press = false;
    assert_eq!(encode(release_a, cfg), Vec::<u8>::new());
}
