/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use tako_core::key_encode::{EncodeConfig, Key, KeyEvent, Mods, encode};

#[test]
fn legacy_keypad_enter() {
    let event = KeyEvent {
        key: Key::KeypadEnter,
        mods: Mods::empty(),
        repeat: false,
        press: true,
        unshifted: None,
        physical: None,
        text: None,
        composing: false,
    };
    let config = EncodeConfig::default();
    assert_eq!(encode(event, config), b"\r");
}

/// Upstream test: "legacy: keypad 1"
#[test]
fn legacy_keypad_1() {
    let event = KeyEvent {
        key: Key::Char('1'),
        mods: Mods::empty(),
        repeat: false,
        press: true,
        unshifted: None,
        physical: None,
        text: None,
        composing: false,
    };
    let config = EncodeConfig::default();
    assert_eq!(encode(event, config), b"1");
}

/// Upstream test: "legacy: keypad 1 with application keypad"
#[test]
fn legacy_keypad_1_with_application_keypad() {
    let event = KeyEvent {
        key: Key::Char('1'),
        mods: Mods::empty(),
        repeat: false,
        press: true,
        unshifted: None,
        physical: None,
        text: None,
        composing: false,
    };
    let config = EncodeConfig {
        keypad_app_mode: true,
        ..Default::default()
    };
    assert_eq!(encode(event, config), b"\x1bOq");
}

/// Upstream test: "legacy: keypad 1 with application keypad and numlock"
#[test]
fn legacy_keypad_1_with_application_keypad_and_numlock() {
    let event = KeyEvent {
        key: Key::Char('1'),
        mods: Mods::empty(),
        repeat: false,
        press: true,
        unshifted: None,
        physical: None,
        text: None,
        composing: false,
    };
    let config = EncodeConfig {
        keypad_app_mode: true,
        ..Default::default()
    };
    assert_eq!(encode(event, config), b"\x1bOq");
}

/// Upstream test: "legacy: keypad 1 with application keypad and numlock ignore"
#[test]
fn legacy_keypad_1_with_application_keypad_and_numlock_ignore() {
    let event = KeyEvent {
        key: Key::Char('1'),
        mods: Mods::empty(),
        repeat: false,
        press: true,
        unshifted: None,
        physical: None,
        text: None,
        composing: false,
    };
    // DEC mode 1035: numlock's real state, not the app-mode request,
    // decides digit-vs-SS3 -- upstream's `ignore_keypad_with_numlock`.
    // Without this field the previous two tests are indistinguishable from
    // this one; the port originally dropped it since the field didn't
    // exist yet.
    let config = EncodeConfig {
        keypad_app_mode: true,
        ignore_keypad_with_numlock: true,
        ..Default::default()
    };
    assert_eq!(encode(event, config), b"1");
}

/// Upstream test: "legacy: f1"
#[test]
fn legacy_f1() {
    let config = EncodeConfig::default();
    {
        let event = KeyEvent {
            key: Key::F1,
            mods: Mods::CTRL,
            repeat: false,
            press: true,
            unshifted: None,
            physical: None,
            text: None,
            composing: false,
        };
        assert_eq!(encode(event, config), b"\x1b[1;5P");
    }
    {
        let event = KeyEvent {
            key: Key::F2,
            mods: Mods::CTRL,
            repeat: false,
            press: true,
            unshifted: None,
            physical: None,
            text: None,
            composing: false,
        };
        assert_eq!(encode(event, config), b"\x1b[1;5Q");
    }
    {
        let event = KeyEvent {
            key: Key::F3,
            mods: Mods::CTRL,
            repeat: false,
            press: true,
            unshifted: None,
            physical: None,
            text: None,
            composing: false,
        };
        assert_eq!(encode(event, config), b"\x1b[13;5~");
    }
    {
        let event = KeyEvent {
            key: Key::F4,
            mods: Mods::CTRL,
            repeat: false,
            press: true,
            unshifted: None,
            physical: None,
            text: None,
            composing: false,
        };
        assert_eq!(encode(event, config), b"\x1b[1;5S");
    }
    {
        let event = KeyEvent {
            key: Key::F5,
            mods: Mods::CTRL,
            repeat: false,
            press: true,
            unshifted: None,
            physical: None,
            text: None,
            composing: false,
        };
        assert_eq!(encode(event, config), b"\x1b[15;5~");
    }
}

/// Upstream test: "legacy: left_shift+tab"
#[test]
fn legacy_left_shift_tab() {
    // Note: sides (left/right modifier) is omitted.
    let event = KeyEvent {
        key: Key::Tab,
        mods: Mods::SHIFT,
        repeat: false,
        press: true,
        unshifted: None,
        physical: None,
        text: None,
        composing: false,
    };
    let config = EncodeConfig::default();
    assert_eq!(encode(event, config), b"\x1b[Z");
}

/// Upstream test: "legacy: right_shift+tab"
#[test]
fn legacy_right_shift_tab() {
    // Note: sides (left/right modifier) is omitted.
    let event = KeyEvent {
        key: Key::Tab,
        mods: Mods::SHIFT,
        repeat: false,
        press: true,
        unshifted: None,
        physical: None,
        text: None,
        composing: false,
    };
    let config = EncodeConfig::default();
    assert_eq!(encode(event, config), b"\x1b[Z");
}

/// Upstream test: "legacy: hu layout ctrl+ő sends proper codepoint"
#[test]
fn legacy_hu_layout_ctrl_o_double_acuteness_sends_proper_codepoint() {
    let event = KeyEvent {
        key: Key::Char('ő'),
        mods: Mods::CTRL,
        repeat: false,
        press: true,
        unshifted: char::from_u32(337),
        physical: char::from_u32(337),
        text: None,
        composing: false,
    };
    let config = EncodeConfig::default();
    assert_eq!(encode(event, config), b"\x1b[337;5u");
}

/// Upstream test: "legacy: super-only on macOS with text"
#[test]
fn legacy_super_only_on_macos_with_text() {
    let event = KeyEvent {
        key: Key::Char('b'),
        mods: Mods::SUPER,
        repeat: false,
        press: true,
        unshifted: None,
        physical: None,
        text: None,
        composing: false,
    };
    let config = EncodeConfig::default();
    assert_eq!(encode(event, config), b"");
}

/// Upstream test: "legacy: super and other mods on macOS with text"
#[test]
fn legacy_super_and_other_mods_on_macos_with_text() {
    let event = KeyEvent {
        key: Key::Char('B'),
        mods: Mods::SUPER | Mods::SHIFT,
        repeat: false,
        press: true,
        unshifted: None,
        physical: None,
        text: None,
        composing: false,
    };
    let config = EncodeConfig::default();
    assert_eq!(encode(event, config), b"");
}

/// Upstream test: "legacy: backspace with DEL utf8 (DECBKM reset)"
#[test]
fn legacy_backspace_with_del_utf8_decbkm_reset() {
    let event = KeyEvent {
        key: Key::Backspace,
        mods: Mods::empty(),
        repeat: false,
        press: true,
        unshifted: Some('\x08'),
        physical: Some('\x08'),
        text: None,
        composing: false,
    };
    let config = EncodeConfig::default();
    assert_eq!(encode(event, config), b"\x7f");
}

/// Upstream test: "legacy: backspace with DEL utf8 (DECBKM set)"
#[test]
fn legacy_backspace_with_del_utf8_decbkm_set() {
    let event = KeyEvent {
        key: Key::Backspace,
        mods: Mods::empty(),
        repeat: false,
        press: true,
        unshifted: Some('\x08'),
        physical: Some('\x08'),
        text: None,
        composing: false,
    };
    let config = EncodeConfig {
        backarrow_key_mode: true,
        ..Default::default()
    };
    assert_eq!(encode(event, config), b"\x08");
}
