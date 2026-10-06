/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

pub use tako_core::key_encode::{EncodeConfig, Key, KeyEvent, Mods, OptionAsAlt, encode};

pub fn make_key_event(
    key: Key,
    mods: Mods,
    press: bool,
    repeat: bool,
    unshifted: Option<char>,
) -> KeyEvent {
    KeyEvent {
        key,
        mods,
        repeat,
        press,
        unshifted,
        physical: unshifted,
        text: None,
        composing: false,
    }
}

pub fn make_key_event_full(
    key: Key,
    mods: Mods,
    press: bool,
    repeat: bool,
    unshifted: Option<char>,
    text: Option<&str>,
    composing: bool,
) -> KeyEvent {
    KeyEvent {
        key,
        mods,
        repeat,
        press,
        unshifted,
        physical: unshifted,
        text: text.map(String::from),
        composing,
    }
}

pub fn cfg(kitty_flags: u8) -> EncodeConfig {
    EncodeConfig {
        cursor_key_app_mode: false,
        keypad_app_mode: false,
        kitty_flags,
        alt_esc_prefix: false,
        macos_option_as_alt: OptionAsAlt::False,
        backarrow_key_mode: false,
        modify_other_keys_state_2: false,
        ignore_keypad_with_numlock: false,
    }
}
