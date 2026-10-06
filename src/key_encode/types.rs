/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

bitflags::bitflags! {
    #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
    pub struct Mods: u8 {
        const SHIFT = 1;
        const ALT = 2;
        const CTRL = 4;
        const SUPER = 8;
        /// Lock-key state, not a bindable modifier. Kitty reports it
        /// separately in the CSI u modifier field and, unlike shift, it does
        /// not by itself flip a key's reported alternate codepoint.
        const CAPS_LOCK = 16;
        const NUM_LOCK = 32;
    }
}

impl Mods {
    /// The bindable modifiers only -- drops the lock keys. Upstream's
    /// `Mods.binding()`: used to decide whether a key is "held with no
    /// modifier" for the purposes of legacy passthrough/disambiguation,
    /// where caps lock or num lock alone must not count as a modifier.
    pub(crate) fn binding(self) -> Mods {
        self & (Mods::SHIFT | Mods::ALT | Mods::CTRL | Mods::SUPER)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Key {
    Enter,
    Tab,
    Backspace,
    Escape,
    Space,
    Up,
    Down,
    Right,
    Left,
    Home,
    End,
    PageUp,
    PageDown,
    Insert,
    Delete,
    F1,
    F2,
    F3,
    F4,
    F5,
    F6,
    F7,
    F8,
    F9,
    F10,
    F11,
    F12,
    KeypadEnter,
    KeypadPlus,
    KeypadMinus,
    KeypadMultiply,
    KeypadDivide,
    Keypad0,
    Keypad1,
    Keypad2,
    Keypad3,
    Keypad4,
    Keypad5,
    Keypad6,
    Keypad7,
    Keypad8,
    Keypad9,
    /// The modifier keys as events in their own right, only ever reported
    /// under the Kitty protocol's `report_all` flag (upstream's
    /// `shift_left`/`shift_right`/etc; there is no `super_left`/`super_right`
    /// in upstream's Kitty key table, so none exists here either).
    ShiftLeft,
    ShiftRight,
    ControlLeft,
    ControlRight,
    AltLeft,
    AltRight,
    MetaLeft,
    MetaRight,
    /// Text with no key behind it -- e.g. IME-composed text delivered
    /// without an originating physical key.
    Unidentified,
    Char(char),
}

/// Whether the macOS "option" key is treated as Alt for text-suppression
/// purposes (Kitty's `report_associated`) and legacy alt-prefixing, or as a
/// dead-key modifier that still produces composed text. See upstream's
/// `macos-option-as-alt` config.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum OptionAsAlt {
    #[default]
    False,
    True,
    Left,
    Right,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KeyEvent {
    pub key: Key,
    pub mods: Mods,
    pub repeat: bool,
    pub press: bool,
    /// The character the key produces with no modifiers applied.
    ///
    /// The Kitty keyboard protocol identifies a key by its *base* codepoint
    /// and reports shift separately, so `shift+a` is `CSI 97;2u` and never
    /// `CSI 65;2u` -- a receiver that gets the shifted codepoint has no way
    /// to tell which physical key was pressed and drops it. Legacy encoding
    /// still uses the shifted character, which is the text the key produced.
    pub unshifted: Option<char>,
    /// Which key this physically is, as the ASCII it would type on a US
    /// layout.
    ///
    /// On a Cyrillic layout the `c` key types U+0441 and its unshifted
    /// codepoint is U+0441 too, so neither says that this is the `c` key --
    /// and every terminal still sends 0x03 for it. Upstream calls this the
    /// logical key.
    pub physical: Option<char>,
    /// The text this event actually committed -- upstream's `event.utf8`.
    /// Multi-codepoint for an IME/dead-key commit (e.g. `"abcd"`). `None`
    /// falls back to `key`'s own character for `Key::Char`, matching a host
    /// that never populates this separately from the key.
    pub text: Option<String>,
    /// True while a dead-key/IME composition is in progress and this event
    /// has not committed text yet. Upstream's `event.composing`.
    pub composing: bool,
}

impl KeyEvent {
    pub fn new(key: Key) -> Self {
        Self {
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

    /// Upstream's `event.utf8`: the committed text for this event, falling
    /// back to `Key::Char`'s own character when the host didn't report text
    /// separately.
    pub(crate) fn utf8(&self) -> Option<std::borrow::Cow<'_, str>> {
        if let Some(text) = &self.text {
            return Some(std::borrow::Cow::Borrowed(text.as_str()));
        }
        match self.key {
            Key::Char(c) => {
                let mut buf = [0u8; 4];
                Some(std::borrow::Cow::Owned(c.encode_utf8(&mut buf).to_string()))
            }
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct EncodeConfig {
    pub cursor_key_app_mode: bool, // DECCKM
    pub keypad_app_mode: bool,     // DECKPAM
    pub kitty_flags: u8,           // Kitty keyboard progressive-enhancement bits
    pub alt_esc_prefix: bool,      // Alt sends ESC prefix (macOS option-as-meta)
    pub macos_option_as_alt: OptionAsAlt,
    /// DEC Backarrow Key Mode. Off (the default): backspace sends 0x7F, and
    /// ctrl+backspace sends 0x08. On: swapped.
    pub backarrow_key_mode: bool,
    /// xterm's "modifyOtherKeys" state 2: ctrl/alt/shift combinations on a
    /// character key that would otherwise lose their modifiers (or collide
    /// with another sequence) go out as `CSI 27;mods;codepoint~` instead.
    pub modify_other_keys_state_2: bool,
    /// DEC mode 1035. When true (the common modern default), a numpad
    /// digit's own DEC keypad-application-mode encoding is never used --
    /// numlock's real state decides digit-vs-SS3 instead, which upstream
    /// models as the apprt simply not requesting application mode for that
    /// key. We have no separate numpad-vs-top-row signal, so this flag is
    /// the only thing that can suppress it here.
    pub ignore_keypad_with_numlock: bool,
}

pub(crate) fn is_control(cp: u32) -> bool {
    cp < 0x20 || cp == 0x7F
}
