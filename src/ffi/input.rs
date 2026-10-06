/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::core::{TakoCore, lock_recover};
use super::event_types::FfiEvent;
use super::input_types::{
    FfiFeedOutcome, FfiKey, FfiKeyEvent, FfiMouseAction, FfiMouseButton, FfiMouseEvent,
};
use crate::key_encode::{EncodeConfig, Key, KeyEvent, Mods, OptionAsAlt, encode as encode_key_raw};
use crate::modes::MouseTracking;
use crate::mouse_encode::{
    MouseAction, MouseButton, MouseEncoding, MouseEvent, MouseMods, encode as encode_mouse_raw,
};

#[uniffi::export]
impl TakoCore {
    /// Feeds raw PTY output bytes into the terminal's VT100/ANSI parser.
    pub fn feed(&self, bytes: Vec<u8>) {
        lock_recover(&self.inner).feed(&bytes);
    }

    /// Feeds PTY bytes and reports the result of that feed in one shot.
    pub fn feed_with_outcome(&self, bytes: Vec<u8>) -> FfiFeedOutcome {
        let mut engine = lock_recover(&self.inner);
        engine.feed(&bytes);
        let output = engine.take_output();
        let events = engine
            .take_events()
            .into_iter()
            .map(FfiEvent::from)
            .collect();
        FfiFeedOutcome {
            output,
            events,
            has_damage: engine.has_damage(),
            synchronized_output_active: engine.is_synchronized_output(),
            epoch: engine.epoch,
        }
    }

    /// Drains and returns any queued device-reply bytes.
    pub fn take_output(&self) -> Vec<u8> {
        lock_recover(&self.inner).take_output()
    }

    /// The Kitty keyboard protocol's currently active flags.
    pub fn kitty_keyboard_flags(&self) -> u8 {
        lock_recover(&self.inner).kitty_keyboard_flags()
    }

    /// Drains queued host-visible events.
    pub fn take_events(&self) -> Vec<FfiEvent> {
        lock_recover(&self.inner)
            .take_events()
            .into_iter()
            .map(FfiEvent::from)
            .collect()
    }

    /// Whether clipboard query / reading escape sequences are allowed.
    pub fn is_clipboard_read_allowed(&self) -> bool {
        lock_recover(&self.inner).clipboard_policy() == crate::terminal::ClipboardPolicy::ReadWrite
    }

    /// Enable or disable clipboard query / reading escape sequences.
    pub fn set_clipboard_read_allowed(&self, allowed: bool) {
        let policy = if allowed {
            crate::terminal::ClipboardPolicy::ReadWrite
        } else {
            crate::terminal::ClipboardPolicy::WriteOnly
        };
        lock_recover(&self.inner).set_clipboard_policy(policy);
    }

    /// Encodes a key event into the bytes to write to the PTY.
    pub fn encode_key(&self, event: FfiKeyEvent) -> Vec<u8> {
        let terminal = lock_recover(&self.inner);
        let key = match event.key {
            FfiKey::Enter => Key::Enter,
            FfiKey::Tab => Key::Tab,
            FfiKey::Backspace => Key::Backspace,
            FfiKey::Escape => Key::Escape,
            FfiKey::Space => Key::Space,
            FfiKey::Up => Key::Up,
            FfiKey::Down => Key::Down,
            FfiKey::Right => Key::Right,
            FfiKey::Left => Key::Left,
            FfiKey::Home => Key::Home,
            FfiKey::End => Key::End,
            FfiKey::PageUp => Key::PageUp,
            FfiKey::PageDown => Key::PageDown,
            FfiKey::Insert => Key::Insert,
            FfiKey::Delete => Key::Delete,
            FfiKey::F1 => Key::F1,
            FfiKey::F2 => Key::F2,
            FfiKey::F3 => Key::F3,
            FfiKey::F4 => Key::F4,
            FfiKey::F5 => Key::F5,
            FfiKey::F6 => Key::F6,
            FfiKey::F7 => Key::F7,
            FfiKey::F8 => Key::F8,
            FfiKey::F9 => Key::F9,
            FfiKey::F10 => Key::F10,
            FfiKey::F11 => Key::F11,
            FfiKey::F12 => Key::F12,
            FfiKey::KeypadEnter => Key::KeypadEnter,
            FfiKey::KeypadPlus => Key::KeypadPlus,
            FfiKey::KeypadMinus => Key::KeypadMinus,
            FfiKey::KeypadMultiply => Key::KeypadMultiply,
            FfiKey::KeypadDivide => Key::KeypadDivide,
            FfiKey::Keypad0 => Key::Keypad0,
            FfiKey::Keypad1 => Key::Keypad1,
            FfiKey::Keypad2 => Key::Keypad2,
            FfiKey::Keypad3 => Key::Keypad3,
            FfiKey::Keypad4 => Key::Keypad4,
            FfiKey::Keypad5 => Key::Keypad5,
            FfiKey::Keypad6 => Key::Keypad6,
            FfiKey::Keypad7 => Key::Keypad7,
            FfiKey::Keypad8 => Key::Keypad8,
            FfiKey::Keypad9 => Key::Keypad9,
            FfiKey::ShiftLeft => Key::ShiftLeft,
            FfiKey::ShiftRight => Key::ShiftRight,
            FfiKey::ControlLeft => Key::ControlLeft,
            FfiKey::ControlRight => Key::ControlRight,
            FfiKey::AltLeft => Key::AltLeft,
            FfiKey::AltRight => Key::AltRight,
            FfiKey::MetaLeft => Key::MetaLeft,
            FfiKey::MetaRight => Key::MetaRight,
            FfiKey::Unidentified => Key::Unidentified,
            FfiKey::Character => {
                let base = event
                    .unshifted_text
                    .chars()
                    .next()
                    .or_else(|| event.text.chars().next());
                match base {
                    Some(ch) => Key::Char(ch),
                    None => return Vec::new(),
                }
            }
        };
        let mut mods = Mods::empty();
        if event.shift {
            mods |= Mods::SHIFT;
        }
        if event.alt {
            mods |= Mods::ALT;
        }
        if event.ctrl {
            mods |= Mods::CTRL;
        }
        if event.super_key {
            mods |= Mods::SUPER;
        }
        let config = EncodeConfig {
            cursor_key_app_mode: terminal.modes().cursor_key_app_mode,
            keypad_app_mode: false,
            kitty_flags: terminal.kitty_keyboard_flags(),
            alt_esc_prefix: true,
            macos_option_as_alt: OptionAsAlt::default(),
            backarrow_key_mode: false,
            modify_other_keys_state_2: terminal.modes().modify_other_keys == 2,
            ignore_keypad_with_numlock: true,
        };
        encode_key_raw(
            KeyEvent {
                key,
                mods,
                repeat: event.repeat,
                press: event.press,
                unshifted: event.unshifted_text.chars().next(),
                physical: event.physical_text.chars().next(),
                text: if event.text.is_empty() {
                    None
                } else {
                    Some(event.text)
                },
                composing: event.composing,
            },
            config,
        )
    }

    /// Encodes a mouse event using whichever tracking/encoding modes are enabled.
    pub fn encode_mouse(&self, event: FfiMouseEvent) -> Vec<u8> {
        let terminal = lock_recover(&self.inner);
        let modes = terminal.modes();
        let action = match event.action {
            FfiMouseAction::Press => MouseAction::Press,
            FfiMouseAction::Release => MouseAction::Release,
            FfiMouseAction::Motion => MouseAction::Motion,
        };
        match modes.mouse_tracking {
            MouseTracking::Off => return Vec::new(),
            MouseTracking::Normal if action == MouseAction::Motion => return Vec::new(),
            _ => {}
        }
        let button = match event.button {
            FfiMouseButton::Left => MouseButton::Left,
            FfiMouseButton::Middle => MouseButton::Middle,
            FfiMouseButton::Right => MouseButton::Right,
            FfiMouseButton::WheelUp => MouseButton::WheelUp,
            FfiMouseButton::WheelDown => MouseButton::WheelDown,
            FfiMouseButton::WheelLeft => MouseButton::WheelLeft,
            FfiMouseButton::WheelRight => MouseButton::WheelRight,
            FfiMouseButton::None => MouseButton::None,
        };
        let encoding = if modes.mouse_sgr {
            MouseEncoding::Sgr
        } else if modes.mouse_utf8 {
            MouseEncoding::Utf8
        } else {
            MouseEncoding::X10
        };
        encode_mouse_raw(
            MouseEvent {
                button,
                action,
                mods: MouseMods {
                    shift: event.shift,
                    alt: event.alt,
                    ctrl: event.ctrl,
                },
                col: event.col,
                row: event.row,
            },
            encoding,
        )
        .unwrap_or_default()
    }

    /// Encodes pasted text, bracketing it when the app enabled DEC mode 2004.
    pub fn encode_paste(&self, text: String) -> Vec<u8> {
        let bracketed = lock_recover(&self.inner).modes().bracketed_paste;
        crate::paste::encode(&text, bracketed)
    }

    /// Whether pasting this text unbracketed would be risky.
    pub fn paste_is_unsafe(&self, text: String) -> bool {
        crate::paste::is_unsafe(&text)
    }
}
