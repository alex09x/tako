/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

pub mod capi;
pub mod charset;
pub mod cursor_style;
pub mod ffi;
pub mod graphics;
pub mod grid;
pub mod key_encode;
pub mod kitty_keyboard;
pub mod modes;
pub mod mouse_encode;
pub mod palette;
pub mod parser;
pub mod paste;
#[cfg(feature = "pty")]
pub mod pty;
pub mod response;
#[cfg(feature = "ssh")]
pub mod ssh;
pub mod tabstops;
pub mod terminal;
pub mod title_stack;

uniffi::setup_scaffolding!();
