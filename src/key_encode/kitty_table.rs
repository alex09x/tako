/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::types::Key;

/// A key's entry in the Kitty keyboard protocol's key table: its assigned
/// code, the CSI final byte to use, and whether it is a bare modifier key
/// (only ever reported under `report_all`).
///
/// Ported from upstream's `kitty` (`raw_entries`), which is
/// itself ported from Foot's `kitty-keymap.h`. Only the entries our `Key`
/// enum can produce are included.
pub(crate) struct KittyEntry {
    pub(crate) code: u32,
    pub(crate) final_byte: u8,
    pub(crate) modifier: bool,
}

pub(crate) fn kitty_entry(key: Key) -> Option<KittyEntry> {
    let (code, final_byte, modifier) = match key {
        Key::Escape => (27, b'u', false),
        Key::Enter => (13, b'u', false),
        Key::Tab => (9, b'u', false),
        Key::Backspace => (127, b'u', false),
        Key::Insert => (2, b'~', false),
        Key::Delete => (3, b'~', false),
        Key::Left => (1, b'D', false),
        Key::Right => (1, b'C', false),
        Key::Up => (1, b'A', false),
        Key::Down => (1, b'B', false),
        Key::PageUp => (5, b'~', false),
        Key::PageDown => (6, b'~', false),
        Key::Home => (1, b'H', false),
        Key::End => (1, b'F', false),
        Key::F1 => (1, b'P', false),
        Key::F2 => (1, b'Q', false),
        // F3 is the one named function key that does not get an SS3 letter
        // -- upstream's table gives it code 13 with the tilde form instead.
        Key::F3 => (13, b'~', false),
        Key::F4 => (1, b'S', false),
        Key::F5 => (15, b'~', false),
        Key::F6 => (17, b'~', false),
        Key::F7 => (18, b'~', false),
        Key::F8 => (19, b'~', false),
        Key::F9 => (20, b'~', false),
        Key::F10 => (21, b'~', false),
        Key::F11 => (23, b'~', false),
        Key::F12 => (24, b'~', false),
        Key::Keypad0 => (57399, b'u', false),
        Key::Keypad1 => (57400, b'u', false),
        Key::Keypad2 => (57401, b'u', false),
        Key::Keypad3 => (57402, b'u', false),
        Key::Keypad4 => (57403, b'u', false),
        Key::Keypad5 => (57404, b'u', false),
        Key::Keypad6 => (57405, b'u', false),
        Key::Keypad7 => (57406, b'u', false),
        Key::Keypad8 => (57407, b'u', false),
        Key::Keypad9 => (57408, b'u', false),
        Key::KeypadDivide => (57410, b'u', false),
        Key::KeypadMultiply => (57411, b'u', false),
        Key::KeypadMinus => (57412, b'u', false),
        Key::KeypadPlus => (57413, b'u', false),
        Key::KeypadEnter => (57414, b'u', false),
        Key::ShiftLeft => (57441, b'u', true),
        Key::ShiftRight => (57447, b'u', true),
        Key::ControlLeft => (57442, b'u', true),
        Key::ControlRight => (57448, b'u', true),
        Key::MetaLeft => (57444, b'u', true),
        Key::MetaRight => (57450, b'u', true),
        Key::AltLeft => (57443, b'u', true),
        Key::AltRight => (57449, b'u', true),
        Key::Space | Key::Char(_) | Key::Unidentified => return None,
    };
    Some(KittyEntry {
        code,
        final_byte,
        modifier,
    })
}
