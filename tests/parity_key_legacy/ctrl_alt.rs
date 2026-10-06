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

/// Upstream test: "legacy: backspace with utf8 (dead key state)"
#[test]
fn legacy_backspace_with_utf8_dead_key_state() {
    // `unshifted: Some('\r')` here is just backspace's own normal unshifted
    // value (upstream's test sets `unshifted_codepoint = 0x0D` too) -- the
    // dead-key commit is carried by `text`, upstream's `utf8`.
    let event = KeyEvent {
        key: Key::Backspace,
        mods: Mods::empty(),
        repeat: false,
        press: true,
        unshifted: Some('\r'),
        physical: Some('\r'),
        text: Some("A".to_string()),
        composing: false,
    };
    let config = EncodeConfig::default();
    assert_eq!(encode(event, config), b"");
}

/// Upstream test: "legacy: enter with utf8 (dead key state)"
#[test]
fn legacy_enter_with_utf8_dead_key_state() {
    let event = KeyEvent {
        key: Key::Enter,
        mods: Mods::empty(),
        repeat: false,
        press: true,
        unshifted: Some('\r'),
        physical: Some('\r'),
        text: Some("A".to_string()),
        composing: false,
    };
    let config = EncodeConfig::default();
    assert_eq!(encode(event, config), b"A");
}

/// Upstream test: "legacy: esc with utf8 (dead key state)"
#[test]
fn legacy_esc_with_utf8_dead_key_state() {
    let event = KeyEvent {
        key: Key::Escape,
        mods: Mods::empty(),
        repeat: false,
        press: true,
        unshifted: Some('\r'),
        physical: Some('\r'),
        text: Some("A".to_string()),
        composing: false,
    };
    let config = EncodeConfig::default();
    assert_eq!(encode(event, config), b"A");
}

/// Upstream test: "legacy: ctrl+shift+minus (underscore on US)"
#[test]
fn legacy_ctrl_shift_minus_underscore_on_us() {
    let event = KeyEvent {
        key: Key::Char('_'),
        mods: Mods::CTRL | Mods::SHIFT,
        repeat: false,
        press: true,
        unshifted: None,
        physical: None,
        text: None,
        composing: false,
    };
    let config = EncodeConfig::default();
    assert_eq!(encode(event, config), b"\x1F");
}

/// Upstream test: "legacy: ctrl+alt+c"
#[test]
fn legacy_ctrl_alt_c() {
    let event = KeyEvent {
        key: Key::Char('c'),
        mods: Mods::CTRL | Mods::ALT,
        repeat: false,
        press: true,
        unshifted: None,
        physical: None,
        text: None,
        composing: false,
    };
    let config = EncodeConfig {
        alt_esc_prefix: true,
        ..Default::default()
    };
    assert_eq!(encode(event, config), b"\x1b\x03");
}

/// Upstream test: "legacy: alt+c"
#[test]
fn legacy_alt_c() {
    let event = KeyEvent {
        key: Key::Char('c'),
        mods: Mods::ALT,
        repeat: false,
        press: true,
        unshifted: None,
        physical: None,
        text: None,
        composing: false,
    };
    let config = EncodeConfig {
        alt_esc_prefix: true,
        ..Default::default()
    };
    assert_eq!(encode(event, config), b"\x1bc");
}

/// Upstream test: "legacy: alt+e only unshifted"
#[test]
fn legacy_alt_e_only_unshifted() {
    let event = KeyEvent {
        key: Key::Char('e'),
        mods: Mods::ALT,
        repeat: false,
        press: true,
        unshifted: Some('e'),
        physical: Some('e'),
        text: None,
        composing: false,
    };
    let config = EncodeConfig {
        alt_esc_prefix: true,
        ..Default::default()
    };
    assert_eq!(encode(event, config), b"\x1be");
}

/// Upstream test: "legacy: alt+x macos"
#[test]
fn legacy_alt_x_macos() {
    let event = KeyEvent {
        key: Key::Char('\u{2248}'),
        mods: Mods::ALT,
        repeat: false,
        press: true,
        unshifted: Some('c'),
        physical: Some('c'),
        text: None,
        composing: false,
    };
    let config = EncodeConfig {
        alt_esc_prefix: true,
        ..Default::default()
    };
    assert_eq!(encode(event, config), b"\x1bc");
}

/// Upstream test: "legacy: shift+alt+. macos"
#[test]
fn legacy_shift_alt_period_macos() {
    let event = KeyEvent {
        key: Key::Char('>'),
        mods: Mods::ALT | Mods::SHIFT,
        repeat: false,
        press: true,
        unshifted: Some('.'),
        physical: Some('.'),
        text: None,
        composing: false,
    };
    let config = EncodeConfig {
        alt_esc_prefix: true,
        ..Default::default()
    };
    assert_eq!(encode(event, config), b"\x1b>");
}

/// Upstream test: "legacy: alt+ф"
#[test]
fn legacy_alt_cyrillic_ef() {
    let event = KeyEvent {
        key: Key::Char('ф'),
        mods: Mods::ALT,
        repeat: false,
        press: true,
        unshifted: None,
        physical: None,
        text: None,
        composing: false,
    };
    let config = EncodeConfig {
        alt_esc_prefix: true,
        ..Default::default()
    };
    assert_eq!(encode(event, config), "ф".as_bytes());
}

/// Upstream test: "legacy: ctrl+c"
#[test]
fn legacy_ctrl_c() {
    let event = KeyEvent {
        key: Key::Char('c'),
        mods: Mods::CTRL,
        repeat: false,
        press: true,
        unshifted: None,
        physical: None,
        text: None,
        composing: false,
    };
    let config = EncodeConfig::default();
    assert_eq!(encode(event, config), b"\x03");
}

/// Upstream test: "legacy: ctrl+space"
#[test]
fn legacy_ctrl_space() {
    let event = KeyEvent {
        key: Key::Space,
        mods: Mods::CTRL,
        repeat: false,
        press: true,
        unshifted: None,
        physical: None,
        text: None,
        composing: false,
    };
    let config = EncodeConfig::default();
    assert_eq!(encode(event, config), b"\x00");
}

/// Upstream test: "legacy: ctrl+shift+backspace"
#[test]
fn legacy_ctrl_shift_backspace() {
    let event = KeyEvent {
        key: Key::Backspace,
        mods: Mods::CTRL | Mods::SHIFT,
        repeat: false,
        press: true,
        unshifted: None,
        physical: None,
        text: None,
        composing: false,
    };
    let config = EncodeConfig::default();
    assert_eq!(encode(event, config), b"\x08");
}

/// Upstream test: "legacy: backspace (DECBKM reset)"
#[test]
fn legacy_backspace_decbkm_reset() {
    let event = KeyEvent {
        key: Key::Backspace,
        mods: Mods::empty(),
        repeat: false,
        press: true,
        unshifted: None,
        physical: None,
        text: None,
        composing: false,
    };
    let config = EncodeConfig::default();
    assert_eq!(encode(event, config), b"\x7f");
}
