/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::event_types::FfiEvent;
use super::program_status_types::FfiClassifiedReply;

#[derive(uniffi::Enum, Debug, Clone, Copy, PartialEq, Eq)]
pub enum FfiKey {
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
    ShiftLeft,
    ShiftRight,
    ControlLeft,
    ControlRight,
    AltLeft,
    AltRight,
    MetaLeft,
    MetaRight,
    Unidentified,
    Character,
}

#[derive(uniffi::Record, Debug, Clone, PartialEq, Eq)]
pub struct FfiKeyEvent {
    pub key: FfiKey,
    pub text: String,
    pub physical_text: String,
    pub unshifted_text: String,
    pub shift: bool,
    pub alt: bool,
    pub ctrl: bool,
    pub super_key: bool,
    pub press: bool,
    pub repeat: bool,
    pub composing: bool,
}

#[derive(uniffi::Enum, Debug, Clone, Copy, PartialEq, Eq)]
pub enum FfiMouseButton {
    Left,
    Middle,
    Right,
    WheelUp,
    WheelDown,
    WheelLeft,
    WheelRight,
    None,
}

#[derive(uniffi::Enum, Debug, Clone, Copy, PartialEq, Eq)]
pub enum FfiMouseAction {
    Press,
    Release,
    Motion,
}

#[derive(uniffi::Record, Debug, Clone, Copy, PartialEq, Eq)]
pub struct FfiMouseEvent {
    pub button: FfiMouseButton,
    pub action: FfiMouseAction,
    pub shift: bool,
    pub alt: bool,
    pub ctrl: bool,
    pub col: u32,
    pub row: u32,
}

/// Result of feeding a byte batch through [`TakoCore::feed_with_outcome`].
///
/// `output` is the flat concatenation of `replies` from this feed turn for
/// legacy hosts; hosts consuming classified `replies` must write from `replies`
/// and ignore `output` so replies are never written twice.
#[derive(uniffi::Record, Debug, Clone, PartialEq)]
pub struct FfiFeedOutcome {
    pub output: Vec<u8>,
    pub replies: Vec<FfiClassifiedReply>,
    pub reply_overflow_count: u32,
    pub status_overflow_coalesced: bool,
    pub status_overflow_from_revision: u64,
    pub status_resync_snapshot: Option<super::program_status_types::FfiProgramStatusSnapshot>,
    pub events: Vec<FfiEvent>,
    pub has_damage: bool,
    pub synchronized_output_active: bool,
    pub epoch: u64,
}
