/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::types::{
    FfiCursorStyle, FfiGrapheme, FfiGraphicsPlacement, FfiSelectionRange, FfiTerminalModes,
};

/// Everything a renderer needs for one frame, in a single FFI call.
#[derive(uniffi::Record, Debug, Clone, PartialEq)]
pub struct FfiSnapshot {
    pub cols: u32,
    pub rows: u32,
    pub cursor_row: u32,
    pub cursor_col: u32,
    pub cursor_visible: bool,
    pub cursor_style: FfiCursorStyle,
    pub title: String,
    pub modes: FfiTerminalModes,
    pub viewport_offset: u32,
    pub scrollback_len: u32,
    pub damaged_rows: Vec<u32>,
    pub selection: Option<FfiSelectionRange>,
    pub graphics_placements: Vec<FfiGraphicsPlacement>,
}

#[derive(uniffi::Record, Debug, Clone, PartialEq)]
pub struct FfiRenderFrame {
    pub snapshot: FfiSnapshot,
    pub packed_cells: Vec<u8>,
    pub epoch: u64,
    #[uniffi(default)]
    pub graphemes: Vec<FfiGrapheme>,
}

#[derive(uniffi::Record, Debug, Clone, PartialEq)]
pub struct FfiRenderFrameOverscan {
    pub snapshot: FfiSnapshot,
    pub packed_cells: Vec<u8>,
    pub overscan_rows: u32,
    pub epoch: u64,
    #[uniffi(default)]
    pub graphemes: Vec<FfiGrapheme>,
}

#[derive(uniffi::Record, Debug, Clone, Copy, PartialEq, Eq)]
pub struct FfiRowRange {
    pub start: u32,
    pub count: u32,
}

#[derive(uniffi::Enum, Debug, Clone, Copy, PartialEq, Eq)]
pub enum FfiResyncReason {
    Delta,
    FirstFrame,
    VersionMismatch,
    Resized,
    ViewportScrolled,
    ScreenSwitched,
    Reset,
    FullDamage,
    DamageOwnershipLost,
}

#[derive(uniffi::Record, Debug, Clone, PartialEq)]
pub struct FfiRenderFrameDelta {
    pub snapshot: FfiSnapshot,
    pub frame_version: u64,
    pub base_version: u64,
    pub full_resync: bool,
    pub resync_reason: FfiResyncReason,
    pub cols: u32,
    pub rows: u32,
    pub cell_stride: u32,
    pub row_stride: u32,
    pub row_indices: Vec<u32>,
    pub row_ranges: Vec<FfiRowRange>,
    pub packed_cells: Vec<u8>,
    #[uniffi(default)]
    pub graphemes: Vec<FfiGrapheme>,
}

#[derive(Debug, Default)]
pub(crate) struct DeltaState {
    pub(crate) version: u64,
    pub(crate) started: bool,
    pub(crate) cols: u32,
    pub(crate) rows: u32,
    pub(crate) viewport_offset: u32,
    pub(crate) alternate: bool,
    pub(crate) reset_pending: bool,
    pub(crate) foreign_drain: bool,
}
