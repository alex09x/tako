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

#[test]
fn kitty_enter_with_utf8_dead_key_state() {
    // An IME confirmation still sends an Enter key, so when it carries
    // committed text (and that text is not itself a single control
    // character), the text wins over Enter's own default bytes.
    let ev = make_key_event_full(
        Key::Enter,
        Mods::empty(),
        true,
        false,
        Some('\r'),
        Some("A"),
        false,
    );
    assert_eq!(encode(ev, cfg(13)), b"A");
}

/// Upstream test: "kitty: keypad number"
#[test]
fn kitty_keypad_number() {
    let ev = make_key_event_full(
        Key::Keypad1,
        Mods::empty(),
        true,
        false,
        None,
        Some("1"),
        false,
    );
    let actual = encode(ev, cfg(31));
    assert_eq!(&actual[1..], b"[57400;;49u");
}

/// Upstream test: "kitty: backspace with utf8 (dead key state)"
#[test]
fn kitty_backspace_with_utf8_dead_key_state() {
    // Backspace's dead-key text commit encodes nothing at all: the IME
    // already modified the preedit buffer, so there is nothing left to send.
    let ev = make_key_event_full(
        Key::Backspace,
        Mods::empty(),
        true,
        false,
        Some('\r'),
        Some("A"),
        false,
    );
    assert_eq!(encode(ev, cfg(31)), b"");
}

/// Upstream test: "kitty: backspace (DECBKM reset) (report_all: true)"
#[test]
fn kitty_backspace_decbkm_reset_report_all_true() {
    let ev = make_key_event(Key::Backspace, Mods::empty(), true, false, None);
    assert_eq!(encode(ev, cfg(31)), b"\x1b[127u");
}

/// Upstream test: "kitty: backspace (DECBKM set) (report_all: true)"
#[test]
fn kitty_backspace_decbkm_set_report_all_true() {
    let ev = make_key_event(Key::Backspace, Mods::empty(), true, false, None);
    assert_eq!(encode(ev, cfg(31)), b"\x1b[127u");
}

// Upstream's `KittySequence: ...` tests exercise the CSI-sequence formatter
// directly rather than through the full `kitty()` pipeline above -- see
// `key_encode::kitty_sequence_encode`'s doc comment for the parameter
// mapping (mods_int is the "1 + bitmask" seqInt value, event_val is
// 0=none/1=press/2=repeat/3=release).
use tako_core::key_encode::kitty_sequence_encode;

/// Upstream test: "KittySequence: backspace"
#[test]
fn kitty_sequence_backspace() {
    // Plain.
    assert_eq!(
        kitty_sequence_encode(127, b'u', 1, 0, [None, None], None),
        b"\x1b[127u"
    );
    // Release event.
    assert_eq!(
        kitty_sequence_encode(127, b'u', 1, 3, [None, None], None),
        b"\x1b[127;1:3u"
    );
    // Shift.
    assert_eq!(
        kitty_sequence_encode(127, b'u', 2, 0, [None, None], None),
        b"\x1b[127;2u"
    );
}

/// Upstream test: "KittySequence: text"
#[test]
fn kitty_sequence_text() {
    // Plain.
    assert_eq!(
        kitty_sequence_encode(127, b'u', 1, 0, [None, None], Some("A")),
        b"\x1b[127;;65u"
    );
    // Release.
    assert_eq!(
        kitty_sequence_encode(127, b'u', 1, 3, [None, None], Some("A")),
        b"\x1b[127;1:3;65u"
    );
    // Shift.
    assert_eq!(
        kitty_sequence_encode(127, b'u', 2, 0, [None, None], Some("A")),
        b"\x1b[127;2;65u"
    );
}

/// Upstream test: "KittySequence: text with control characters"
#[test]
fn kitty_sequence_text_with_control_characters() {
    // By itself: the only codepoint is control, so the whole text section
    // (and its leading ";;") is omitted.
    assert_eq!(
        kitty_sequence_encode(127, b'u', 1, 0, [None, None], Some("\n")),
        b"\x1b[127u"
    );
    // With other printables: the control codepoint is skipped, not the text
    // section itself.
    assert_eq!(
        kitty_sequence_encode(127, b'u', 1, 0, [None, None], Some("A\n")),
        b"\x1b[127;;65u"
    );
}

/// Upstream test: "KittySequence: special no mods"
#[test]
fn kitty_sequence_special_no_mods() {
    assert_eq!(
        kitty_sequence_encode(1, b'A', 1, 0, [None, None], None),
        b"\x1b[A"
    );
}

/// Upstream test: "KittySequence: special mods only"
#[test]
fn kitty_sequence_special_mods_only() {
    assert_eq!(
        kitty_sequence_encode(1, b'A', 2, 0, [None, None], None),
        b"\x1b[1;2A"
    );
}

/// Upstream test: "KittySequence: special mods and event"
#[test]
fn kitty_sequence_special_mods_and_event() {
    assert_eq!(
        kitty_sequence_encode(1, b'A', 2, 3, [None, None], None),
        b"\x1b[1;2:3A"
    );
}
