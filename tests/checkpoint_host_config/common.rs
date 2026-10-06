/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

pub use tako_core::cursor_style::{CursorShape, CursorStyle};
pub use tako_core::ffi::TakoCore;
pub use tako_core::terminal::Terminal;
pub use tako_core::terminal::checkpoint::{
    self, CURRENT_VERSION, CheckpointError, MIN_EXPORT_VERSION,
};

pub const THEME_A_IDX2: (u8, u8, u8) = (100, 110, 120);
pub const THEME_B_IDX2: (u8, u8, u8) = (130, 140, 150);
pub const THEME_A_FG: (u8, u8, u8) = (10, 20, 30);
pub const THEME_B_FG: (u8, u8, u8) = (40, 50, 60);
pub const PROGRAM_IDX1: (u8, u8, u8) = (1, 2, 3);

/// A terminal under theme A in which a program has set palette entry 1.
pub fn themed_source() -> Terminal {
    let mut term = Terminal::new(20, 4);
    term.set_base_colors(Some(THEME_A_FG), None, None, &[(2, THEME_A_IDX2)]);
    term.feed(b"\x1b]4;1;#010203\x07");
    term.feed(b"hello");
    term
}

pub fn restored(blob: &[u8]) -> Terminal {
    let mut term = Terminal::new(20, 4);
    term.import_checkpoint(blob).unwrap();
    term
}

pub fn header_version(blob: &[u8]) -> u32 {
    u32::from_le_bytes(blob[4..8].try_into().unwrap())
}
