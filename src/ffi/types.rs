/*
 * Tako — Terminal Emulation Engine
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use crate::cursor_style::{CursorShape, CursorStyle};
use crate::graphics::{ImageFormat, StoredImage};
use crate::grid::{Cell, CellAttrs, Color, Grid};
use crate::modes::MouseTracking;
use crate::palette::Palette;
use crate::terminal::{GraphemeWidthMethod, SelectionMode};

pub const DEFAULT_FG: (u8, u8, u8) = (0xED, 0xE6, 0xDF);
pub const DEFAULT_BG: (u8, u8, u8) = (0x14, 0x10, 0x0E);

pub fn resolve_color(color: Color, default: (u8, u8, u8), palette: &Palette) -> (u8, u8, u8) {
    match color {
        Color::Default => default,
        Color::Rgb(r, g, b) => (r, g, b),
        Color::Indexed(n) => palette.get(n),
    }
}

/// A single terminal cell, flattened for FFI consumption: glyph, resolved
/// foreground/background RGB, and boolean style flags.
#[derive(uniffi::Record, Debug, Clone, PartialEq, Eq)]
pub struct FfiCell {
    pub ch: u32,
    pub fg_r: u8,
    pub fg_g: u8,
    pub fg_b: u8,
    pub bg_r: u8,
    pub bg_g: u8,
    pub bg_b: u8,
    pub bold: bool,
    pub dim: bool,
    pub italic: bool,
    pub underline: bool,
    pub blink: bool,
    pub reverse: bool,
    pub hidden: bool,
    pub strikethrough: bool,
    pub overline: bool,
    pub underline_style: u8,
    pub ul_r: u8,
    pub ul_g: u8,
    pub ul_b: u8,
    pub hyperlink_uri: Option<String>,
    pub wide: bool,
    #[uniffi(default)]
    pub grapheme: Option<String>,
}

#[derive(uniffi::Record, Debug, Clone, PartialEq, Eq)]
pub struct FfiGrapheme {
    pub row: u32,
    pub col: u32,
    pub text: String,
}

#[derive(uniffi::Enum, Debug, Clone, Copy, PartialEq, Eq)]
pub enum FfiGraphemeWidthMethod {
    Unicode,
    Legacy,
}

impl From<FfiGraphemeWidthMethod> for GraphemeWidthMethod {
    fn from(method: FfiGraphemeWidthMethod) -> Self {
        match method {
            FfiGraphemeWidthMethod::Unicode => GraphemeWidthMethod::Unicode,
            FfiGraphemeWidthMethod::Legacy => GraphemeWidthMethod::Legacy,
        }
    }
}

#[derive(uniffi::Record, Debug, Clone, Copy, PartialEq, Eq)]
pub struct FfiRgb {
    pub r: u8,
    pub g: u8,
    pub b: u8,
}

impl From<FfiRgb> for (u8, u8, u8) {
    fn from(rgb: FfiRgb) -> Self {
        (rgb.r, rgb.g, rgb.b)
    }
}

#[derive(uniffi::Record, Debug, Clone, Copy, PartialEq, Eq)]
pub struct FfiPaletteEntry {
    pub index: u8,
    pub color: FfiRgb,
}

pub const PACKED_CELL_SIZE: usize = 16;
pub const MAX_OVERSCAN_ROWS: u32 = 2;

pub const PACKED_BOLD: u16 = 1 << 0;
pub const PACKED_DIM: u16 = 1 << 1;
pub const PACKED_ITALIC: u16 = 1 << 2;
pub const PACKED_UNDERLINE: u16 = 1 << 3;
pub const PACKED_BLINK: u16 = 1 << 4;
pub const PACKED_REVERSE: u16 = 1 << 5;
pub const PACKED_HIDDEN: u16 = 1 << 6;
pub const PACKED_STRIKETHROUGH: u16 = 1 << 7;
pub const PACKED_OVERLINE: u16 = 1 << 8;
pub const PACKED_WIDE: u16 = 1 << 9;
pub const PACKED_GRAPHEME: u16 = 1 << 10;

pub fn grapheme_text(grid: &Grid, cell: &Cell) -> Option<String> {
    let extra = grid.grapheme(cell);
    if extra.is_empty() || cell.is_wide_spacer {
        return None;
    }
    let mut text = String::with_capacity(cell.char.len_utf8() + extra.len());
    text.push(cell.char);
    text.push_str(extra);
    Some(text)
}

pub fn cell_to_ffi(
    cell: &Cell,
    hyperlink_uri: Option<String>,
    grapheme: Option<String>,
    palette: &Palette,
    default_fg: (u8, u8, u8),
    default_bg: (u8, u8, u8),
) -> FfiCell {
    let (fg_r, fg_g, fg_b) = resolve_color(cell.fg, default_fg, palette);
    let (bg_r, bg_g, bg_b) = resolve_color(cell.bg, default_bg, palette);
    let (ul_r, ul_g, ul_b) = resolve_color(cell.underline_color, (fg_r, fg_g, fg_b), palette);
    FfiCell {
        ch: if cell.is_wide_spacer {
            0
        } else if cell.char == '\0' {
            u32::from(' ')
        } else {
            u32::from(cell.char)
        },
        fg_r,
        fg_g,
        fg_b,
        bg_r,
        bg_g,
        bg_b,
        bold: cell.attrs.contains(CellAttrs::BOLD),
        dim: cell.attrs.contains(CellAttrs::DIM),
        italic: cell.attrs.contains(CellAttrs::ITALIC),
        underline: cell.attrs.contains(CellAttrs::UNDERLINE),
        blink: cell.attrs.contains(CellAttrs::BLINK),
        reverse: cell.attrs.contains(CellAttrs::REVERSE),
        hidden: cell.attrs.contains(CellAttrs::HIDDEN),
        strikethrough: cell.attrs.contains(CellAttrs::STRIKETHROUGH),
        overline: cell.attrs.contains(CellAttrs::OVERLINE),
        underline_style: cell.underline_style,
        ul_r,
        ul_g,
        ul_b,
        hyperlink_uri,
        wide: cell.is_wide_spacer_head,
        grapheme,
    }
}

#[derive(uniffi::Enum, Debug, Clone, Copy, PartialEq, Eq)]
pub enum FfiSelectionMode {
    Linear,
    Rectangular,
}

impl From<FfiSelectionMode> for SelectionMode {
    fn from(mode: FfiSelectionMode) -> Self {
        match mode {
            FfiSelectionMode::Linear => SelectionMode::Linear,
            FfiSelectionMode::Rectangular => SelectionMode::Rectangular,
        }
    }
}

impl From<SelectionMode> for FfiSelectionMode {
    fn from(mode: SelectionMode) -> Self {
        match mode {
            SelectionMode::Linear => FfiSelectionMode::Linear,
            SelectionMode::Rectangular => FfiSelectionMode::Rectangular,
        }
    }
}

#[derive(uniffi::Record, Debug, Clone, Copy, PartialEq, Eq)]
pub struct FfiSelectionRange {
    pub start_row: u32,
    pub start_col: u32,
    pub end_row: u32,
    pub end_col: u32,
    pub mode: FfiSelectionMode,
}

#[derive(uniffi::Enum, Debug, Clone, Copy, PartialEq, Eq)]
pub enum FfiMouseTracking {
    Off,
    Normal,
    ButtonEvent,
    AnyEvent,
}

impl From<MouseTracking> for FfiMouseTracking {
    fn from(mode: MouseTracking) -> Self {
        match mode {
            MouseTracking::Off => FfiMouseTracking::Off,
            MouseTracking::Normal => FfiMouseTracking::Normal,
            MouseTracking::ButtonEvent => FfiMouseTracking::ButtonEvent,
            MouseTracking::AnyEvent => FfiMouseTracking::AnyEvent,
        }
    }
}

#[derive(uniffi::Record, Debug, Clone, Copy, PartialEq, Eq)]
pub struct FfiTerminalModes {
    pub autowrap: bool,
    pub origin_mode: bool,
    pub cursor_key_app_mode: bool,
    pub mouse_tracking: FfiMouseTracking,
    pub mouse_utf8: bool,
    pub mouse_sgr: bool,
    pub focus_events: bool,
    pub bracketed_paste: bool,
    pub alternate_screen: bool,
    pub alternate_scroll: bool,
}

#[derive(uniffi::Enum, Debug, Clone, Copy, PartialEq, Eq)]
pub enum FfiImageFormat {
    Rgb,
    Rgba,
    Png,
}

impl From<ImageFormat> for FfiImageFormat {
    fn from(format: ImageFormat) -> Self {
        match format {
            ImageFormat::Rgb => FfiImageFormat::Rgb,
            ImageFormat::Rgba => FfiImageFormat::Rgba,
            ImageFormat::Png => FfiImageFormat::Png,
        }
    }
}

#[derive(uniffi::Record, Debug, Clone, PartialEq, Eq)]
pub struct FfiStoredImage {
    pub format: FfiImageFormat,
    pub width: u32,
    pub height: u32,
    pub pixels: Vec<u8>,
}

#[derive(uniffi::Record, Debug, Clone, Copy, PartialEq, Eq)]
pub struct FfiGraphicsImageMetadata {
    pub format: FfiImageFormat,
    pub width: u32,
    pub height: u32,
    pub generation: u64,
}

impl From<&StoredImage> for FfiStoredImage {
    fn from(image: &StoredImage) -> Self {
        Self {
            format: image.format.into(),
            width: image.width,
            height: image.height,
            pixels: image.pixels.clone(),
        }
    }
}

#[derive(uniffi::Record, Debug, Clone, Copy, PartialEq, Eq)]
pub struct FfiGraphicsPlacement {
    pub image_id: u32,
    pub placement_id: u32,
    pub row: u32,
    pub col: u32,
}

#[derive(uniffi::Enum, Debug, Clone, Copy, PartialEq, Eq)]
pub enum FfiCursorShape {
    Block,
    Underline,
    Bar,
}

impl From<FfiCursorShape> for CursorShape {
    fn from(shape: FfiCursorShape) -> Self {
        match shape {
            FfiCursorShape::Block => CursorShape::Block,
            FfiCursorShape::Underline => CursorShape::Underline,
            FfiCursorShape::Bar => CursorShape::Bar,
        }
    }
}

impl From<CursorShape> for FfiCursorShape {
    fn from(shape: CursorShape) -> Self {
        match shape {
            CursorShape::Block => FfiCursorShape::Block,
            CursorShape::Underline => FfiCursorShape::Underline,
            CursorShape::Bar => FfiCursorShape::Bar,
        }
    }
}

#[derive(uniffi::Record, Debug, Clone, Copy, PartialEq, Eq)]
pub struct FfiCursorStyle {
    pub shape: FfiCursorShape,
    pub blinking: bool,
}

impl From<CursorStyle> for FfiCursorStyle {
    fn from(style: CursorStyle) -> Self {
        Self {
            shape: style.shape.into(),
            blinking: style.blinking,
        }
    }
}
