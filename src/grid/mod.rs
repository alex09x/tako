/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

// The cell grid, its scrollback ring, and reflow on resize.

pub mod cells;
pub mod command_output;
pub mod grapheme;
pub mod reflow;
pub mod resize;
pub mod row;
pub mod scroll;
pub mod search;
pub mod snapshot;
pub mod types;

pub use command_output::CommandOutput;
pub(crate) use grapheme::{
    MAX_EXTRA_BYTES, always_breaks, continues_cluster, unicode_cluster_is_wide,
};
pub use search::{SearchChunk, SearchHit};
pub use types::*;

#[cfg(test)]
mod tests;
