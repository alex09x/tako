/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

//! Keys a program can only tell apart under the Kitty protocol's "report
//! all keys" mode, and the C0 bytes ctrl makes of digits and punctuation.

use super::*;

/// The Kitty flags a program sets with `CSI > 9 u`: disambiguate (1) and
/// report all keys as escape codes (8).
fn report_all() -> EncodeConfig {
    EncodeConfig {
        kitty_flags: 0b1001,
        ..Default::default()
    }
}

const NAMED: [Key; 51] = [
    Key::Escape,
    Key::Enter,
    Key::Tab,
    Key::Backspace,
    Key::Insert,
    Key::Delete,
    Key::Left,
    Key::Right,
    Key::Up,
    Key::Down,
    Key::PageUp,
    Key::PageDown,
    Key::Home,
    Key::End,
    Key::F1,
    Key::F2,
    Key::F3,
    Key::F4,
    Key::F5,
    Key::F6,
    Key::F7,
    Key::F8,
    Key::F9,
    Key::F10,
    Key::F11,
    Key::F12,
    Key::Keypad0,
    Key::Keypad1,
    Key::Keypad2,
    Key::Keypad3,
    Key::Keypad4,
    Key::Keypad5,
    Key::Keypad6,
    Key::Keypad7,
    Key::Keypad8,
    Key::Keypad9,
    Key::KeypadDivide,
    Key::KeypadMultiply,
    Key::KeypadMinus,
    Key::KeypadPlus,
    Key::KeypadEnter,
    Key::ShiftLeft,
    Key::ShiftRight,
    Key::ControlLeft,
    Key::ControlRight,
    Key::MetaLeft,
    Key::MetaRight,
    Key::AltLeft,
    Key::AltRight,
    Key::Space,
    Key::Unidentified,
];

#[test]
fn under_report_all_every_named_key_is_its_own_escape_code() {
    let mut seen = std::collections::HashMap::new();
    for key in NAMED
        .into_iter()
        .filter(|k| !matches!(k, Key::Space | Key::Unidentified))
    {
        let bytes = encode(KeyEvent::new(key), report_all());
        assert!(
            bytes.starts_with(b"\x1b["),
            "{key:?} is a CSI report: {bytes:?}"
        );
        if let Some(other) = seen.insert(bytes.clone(), key) {
            panic!(
                "{key:?} and {other:?} are reported alike: {:?}",
                String::from_utf8_lossy(&bytes)
            );
        }
    }
    assert_eq!(seen.len(), 49);
    // Spot values from the protocol: keypad keys and bare modifiers have codes of their own.
    assert_eq!(
        encode(KeyEvent::new(Key::Keypad0), report_all()),
        b"\x1b[57399u"
    );
    assert_eq!(
        encode(KeyEvent::new(Key::KeypadEnter), report_all()),
        b"\x1b[57414u"
    );
    assert!(
        String::from_utf8_lossy(&encode(KeyEvent::new(Key::ShiftLeft), report_all()))
            .starts_with("\x1b[57441")
    );
}

#[test]
fn without_the_protocol_keypad_digits_and_bare_modifiers_send_nothing() {
    for key in [
        Key::Keypad3,
        Key::ShiftLeft,
        Key::MetaRight,
        Key::Unidentified,
    ] {
        assert!(
            encode(KeyEvent::new(key), EncodeConfig::default()).is_empty(),
            "{key:?}"
        );
    }
    // Disambiguate alone does not report a bare modifier either.
    let disambiguate = EncodeConfig {
        kitty_flags: 1,
        ..Default::default()
    };
    assert!(encode(KeyEvent::new(Key::ControlLeft), disambiguate).is_empty());
}

#[test]
fn ctrl_turns_digits_and_punctuation_into_their_c0_bytes() {
    let ctrl = |c: char| {
        let mut event = KeyEvent::new(Key::Char(c));
        event.mods = Mods::CTRL;
        encode(event, EncodeConfig::default())
    };
    // xterm's table: ctrl+2 is NUL, 3..7 are ESC, FS, GS, RS, US, 8 is DEL.
    let c0: [(char, u8); 15] = [
        ('2', 0x00),
        ('3', 0x1b),
        ('4', 0x1c),
        ('5', 0x1d),
        ('6', 0x1e),
        ('7', 0x1f),
        ('8', 0x7f),
        ('/', 0x1f),
        ('?', 0x7f),
        ('@', 0x00),
        ('\\', 0x1c),
        (']', 0x1d),
        ('^', 0x1e),
        ('~', 0x1e),
        ('_', 0x1f),
    ];
    for (c, byte) in c0 {
        assert_eq!(ctrl(c), [byte], "ctrl+{c}");
    }
    // ctrl+0, 1 and 9 have no control code: the digit itself goes out.
    for c in ['0', '1', '9'] {
        assert_eq!(ctrl(c), c.to_string().into_bytes(), "ctrl+{c}");
    }
}
