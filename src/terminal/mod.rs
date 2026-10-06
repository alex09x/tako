/*
 * tako — Compact terminal emulator engine
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

pub mod checkpoint;
pub mod checksum;
pub mod commands;
mod dsr;
mod dump;
mod select;

pub(crate) mod checkpoint_api;
pub(crate) mod cluster;
pub(crate) mod column_ops;
pub(crate) mod command_nav;
pub(crate) mod command_ui;
pub(crate) mod erase;
pub(crate) mod events;
pub(crate) mod osc99;
pub(crate) mod perform;
pub(crate) mod query;
pub(crate) mod reset;
pub(crate) mod sanitize;
pub(crate) mod screen;
pub(crate) mod selection_api;
pub(crate) mod sgr;
pub(crate) mod state;
pub(crate) mod types;
pub(crate) mod viewport;

pub(crate) use crate::response;

pub(crate) use types::DcsKind;

pub use crate::charset::Charset;
pub use crate::cursor_style::{CursorShape, CursorStyle};
pub use crate::modes::{self, MouseTracking};
pub use crate::palette::{self, Palette};
pub use crate::response::ResponseQueue;
pub use crate::tabstops::TabStops;
pub use crate::title_stack::{self, TitleStack};
pub use dump::TextTail;
pub use events::{ContextFrame, TerminalEvent};
pub use state::Terminal;
pub use types::{
    ClipboardPolicy, CommandMark, CommandMarkStatus, Cursor, GraphemeWidthMethod,
    GraphicsPlacement, MAX_INLINE_IMAGE_PIXEL_DIM, MAX_INLINE_IMAGE_ROW_SPAN, ProtectedMode,
    SavedCursor, ScreenBuffer, Selection, SelectionMode, SemanticContent, StickyCommandHeader,
};

#[cfg(test)]
mod tests;
