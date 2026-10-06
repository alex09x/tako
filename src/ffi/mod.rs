/*
 * Tako — Terminal Emulation Engine
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

//! UniFFI bindings for Swift.
//!
//! Exposes a thread-safe wrapper (`TakoCore`) around `crate::terminal::Terminal`
//! as a UniFFI `Object`, plus per-cell and render data structures so Swift can
//! render the grid, feed input, search, manage checkpoints, and handle commands.

pub mod checkpoint;
pub mod commands;
pub mod core;
pub mod event_types;
pub mod input;
pub mod input_types;
pub mod pack;
pub mod query_types;
pub mod render;
pub mod render_types;
pub mod search;
pub mod selection;
pub mod terminal;
pub mod types;

#[cfg(test)]
mod tests;

pub use core::TakoCore;
pub use event_types::{FfiContextFrame, FfiEvent};
pub use input_types::{
    FfiFeedOutcome, FfiKey, FfiKeyEvent, FfiMouseAction, FfiMouseButton, FfiMouseEvent,
};
pub use query_types::{
    FfiCheckpointInfo, FfiCommandInfo, FfiCommandMark, FfiCommandOutput, FfiRetainedLines,
    FfiSearchChunk, FfiSearchHit, FfiTextTail, TakoCheckpointError,
};
pub use render_types::{
    FfiRenderFrame, FfiRenderFrameDelta, FfiRenderFrameOverscan, FfiResyncReason, FfiRowRange,
    FfiSnapshot,
};
pub use types::{
    DEFAULT_BG, DEFAULT_FG, FfiCell, FfiCursorShape, FfiCursorStyle, FfiGrapheme,
    FfiGraphemeWidthMethod, FfiGraphicsImageMetadata, FfiGraphicsPlacement, FfiImageFormat,
    FfiMouseTracking, FfiPaletteEntry, FfiRgb, FfiSelectionMode, FfiSelectionRange, FfiStoredImage,
    FfiTerminalModes, MAX_OVERSCAN_ROWS, PACKED_BLINK, PACKED_BOLD, PACKED_CELL_SIZE, PACKED_DIM,
    PACKED_GRAPHEME, PACKED_HIDDEN, PACKED_ITALIC, PACKED_OVERLINE, PACKED_REVERSE,
    PACKED_STRIKETHROUGH, PACKED_UNDERLINE, PACKED_WIDE, resolve_color,
};
