/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

pub use tako_core::ffi::{FfiPaletteEntry, FfiRgb, TakoCore};
pub use tako_core::terminal::Terminal;

pub const BASE_FG: (u8, u8, u8) = (10, 20, 30);
pub const BASE_BG: (u8, u8, u8) = (40, 50, 60);
pub const BASE_CURSOR: (u8, u8, u8) = (1, 2, 3);
pub const BASE_IDX1: (u8, u8, u8) = (100, 110, 120);
pub const BASE_IDX2: (u8, u8, u8) = (130, 140, 150);

pub const BUILTIN_IDX1: (u8, u8, u8) = (0xCC, 0x66, 0x66);
pub const BUILTIN_IDX2: (u8, u8, u8) = (0xB5, 0xBD, 0x68);

pub fn osc4_set(index: u8, rgb: (u8, u8, u8)) -> Vec<u8> {
    format!("]4;{};#{:02x}{:02x}{:02x}", index, rgb.0, rgb.1, rgb.2).into_bytes()
}

pub fn rgb(r: u8, g: u8, b: u8) -> FfiRgb {
    FfiRgb { r, g, b }
}
