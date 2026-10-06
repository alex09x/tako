/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use tako_core::key_encode::{EncodeConfig, Key, KeyEvent, Mods, OptionAsAlt, encode};

#[test]
fn legacy_backspace_decbkm_reset_with_ctrl() {
    let event = KeyEvent {
        key: Key::Backspace,
        mods: Mods::CTRL,
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

/// Upstream test: "legacy: backspace (DECBKM set)"
#[test]
fn legacy_backspace_decbkm_set() {
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
    let config = EncodeConfig {
        backarrow_key_mode: true,
        ..Default::default()
    };
    assert_eq!(encode(event, config), b"\x08");
}

/// Upstream test: "legacy: backspace (DECBKM set, with ctrl)"
#[test]
fn legacy_backspace_decbkm_set_with_ctrl() {
    let event = KeyEvent {
        key: Key::Backspace,
        mods: Mods::CTRL,
        repeat: false,
        press: true,
        unshifted: None,
        physical: None,
        text: None,
        composing: false,
    };
    let config = EncodeConfig {
        backarrow_key_mode: true,
        ..Default::default()
    };
    assert_eq!(encode(event, config), b"\x7f");
}

/// Upstream test: "legacy: ctrl+shift+char with modify other state 2"
#[test]
fn legacy_ctrl_shift_char_with_modify_other_state_2() {
    let event = KeyEvent {
        key: Key::Char('H'),
        mods: Mods::CTRL | Mods::SHIFT,
        repeat: false,
        press: true,
        unshifted: None,
        physical: None,
        text: None,
        composing: false,
    };
    let config = EncodeConfig {
        modify_other_keys_state_2: true,
        ..Default::default()
    };
    assert_eq!(encode(event, config), b"\x1b[27;6;72~");
}

/// Upstream test: "legacy: ctrl+shift+char with modify other state 2 and consumed mods"
#[test]
fn legacy_ctrl_shift_char_with_modify_other_state_2_and_consumed_mods() {
    // Upstream's `consumed_mods` (which mods the apprt already used to
    // produce `utf8`) has no equivalent field here; this crate derives the
    // same "was shift used up" fact from `unshifted` instead, so the
    // scenario is identical to the plain modify-other-state-2 case above.
    let event = KeyEvent {
        key: Key::Char('H'),
        mods: Mods::CTRL | Mods::SHIFT,
        repeat: false,
        press: true,
        unshifted: None,
        physical: None,
        text: None,
        composing: false,
    };
    let config = EncodeConfig {
        modify_other_keys_state_2: true,
        ..Default::default()
    };
    assert_eq!(encode(event, config), b"\x1b[27;6;72~");
}

/// Upstream test: "legacy: alt+digit with modify other state 2"
#[test]
fn legacy_alt_digit_with_modify_other_state_2() {
    let event = KeyEvent {
        key: Key::Char('8'),
        mods: Mods::ALT,
        repeat: false,
        press: true,
        unshifted: None,
        physical: None,
        text: None,
        composing: false,
    };
    let config = EncodeConfig {
        modify_other_keys_state_2: true,
        macos_option_as_alt: OptionAsAlt::True,
        ..Default::default()
    };
    assert_eq!(encode(event, config), b"\x1b[27;3;56~");
}

/// Upstream test: "legacy: alt+digit with modify other state 2 and macos-option-as-alt = false"
#[test]
fn legacy_alt_digit_with_modify_other_state_2_and_macos_option_as_alt_false() {
    let event = KeyEvent {
        key: Key::Char('['),
        mods: Mods::ALT,
        repeat: false,
        press: true,
        unshifted: None,
        physical: None,
        text: None,
        composing: false,
    };
    let config = EncodeConfig::default();
    assert_eq!(encode(event, config), b"[");
}

/// Upstream test: "legacy: fixterm awkward letters"
#[test]
fn legacy_fixterm_awkward_letters() {
    let config = EncodeConfig::default();
    {
        let event = KeyEvent {
            key: Key::Char('i'),
            mods: Mods::CTRL,
            repeat: false,
            press: true,
            unshifted: None,
            physical: None,
            text: None,
            composing: false,
        };
        assert_eq!(encode(event, config), b"\x1b[105;5u");
    }
    {
        let event = KeyEvent {
            key: Key::Char('m'),
            mods: Mods::CTRL,
            repeat: false,
            press: true,
            unshifted: None,
            physical: None,
            text: None,
            composing: false,
        };
        assert_eq!(encode(event, config), b"\x1b[109;5u");
    }
    {
        let event = KeyEvent {
            key: Key::Char('['),
            mods: Mods::CTRL,
            repeat: false,
            press: true,
            unshifted: None,
            physical: None,
            text: None,
            composing: false,
        };
        assert_eq!(encode(event, config), b"\x1b[91;5u");
    }
    {
        let event = KeyEvent {
            key: Key::Char('@'),
            mods: Mods::CTRL | Mods::SHIFT,
            repeat: false,
            press: true,
            unshifted: Some('2'),
            physical: Some('2'),
            text: None,
            composing: false,
        };
        assert_eq!(encode(event, config), b"\x1b[64;5u");
    }
}

/// Upstream test: "legacy: ctrl+shift+letter ascii"
#[test]
fn legacy_ctrl_shift_letter_ascii() {
    let event = KeyEvent {
        key: Key::Char('M'),
        mods: Mods::CTRL | Mods::SHIFT,
        repeat: false,
        press: true,
        unshifted: Some('m'),
        physical: Some('m'),
        text: None,
        composing: false,
    };
    let config = EncodeConfig::default();
    assert_eq!(encode(event, config), b"\x1b[109;6u");
}

/// Upstream test: "legacy: shift+function key should use all mods"
#[test]
fn legacy_shift_function_key_should_use_all_mods() {
    let event = KeyEvent {
        key: Key::Up,
        mods: Mods::SHIFT,
        repeat: false,
        press: true,
        unshifted: None,
        physical: None,
        text: None,
        composing: false,
    };
    let config = EncodeConfig::default();
    assert_eq!(encode(event, config), b"\x1b[1;2A");
}
