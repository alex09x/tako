/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use crate::grid::{Cell, RowOwner, ScrollbackRow};
use crate::kitty_keyboard::KittyFlags;
use crate::terminal::GraphicsPlacement;
use crate::terminal::commands::CommandRecord;

pub const MAGIC: [u8; 4] = *b"TKCK";
pub const CURRENT_VERSION: u32 = 6;
/// Lowest version [`export_version`] will write. Version 1 is unwritten
/// because version 2 is strictly superior (no foreign selection).
pub const MIN_EXPORT_VERSION: u32 = 2;
/// Lowest version [`import`] will accept.
pub const MIN_SUPPORTED_VERSION: u32 = 1;
pub const HEADER_SIZE: usize = 20;

/// The maximum size of a checkpoint container, header included.
///
/// 64 MiB: enough for 100,000 lines of scrollback with heavy styling, plus
/// full graphics state, with generous headroom. An export bounded by this cap
/// refuses to write a larger container; an import refuses to read one.
pub const MAX_CONTAINER_LEN: usize = 64 * 1024 * 1024;
pub const MAX_PAYLOAD_LEN: usize = MAX_CONTAINER_LEN - HEADER_SIZE;
pub const MAX_DIM: usize = 10_000;
pub const MAX_SCROLLBACK_LEN: usize = 1_000_000;

/// The maximum cumulative heap an import is allowed to allocate across the
/// terminal it builds, *before* that terminal starts executing.
///
/// Refuses the checkpoint with [`CheckpointError::AllocationLimitExceeded`]
/// instead of exhausting memory when an input declares sizes that fit within
/// the wire cap via run-length encoding.
pub const MAX_IMPORT_ALLOC_BYTES: u64 = 512 * 1024 * 1024;

// Sizes of the heap allocations import creates, so charges match what the
// allocator actually hands out.
pub const CELL_BYTES: u64 = std::mem::size_of::<Cell>() as u64;
pub const SCROLLBACK_ROW_SPINE: u64 = std::mem::size_of::<ScrollbackRow>() as u64;
pub const GRID_ROW_SPINE: u64 =
    (std::mem::size_of::<Vec<Cell>>() + std::mem::size_of::<bool>()) as u64;
pub const OWNER_RUN_SPINE: u64 = std::mem::size_of::<(RowOwner, usize)>() as u64;
pub const COMMAND_RECORD_SPINE: u64 = std::mem::size_of::<CommandRecord>() as u64;
pub const STRING_SPINE: u64 = std::mem::size_of::<String>() as u64;
pub const KITTY_FLAGS_SPINE: u64 = std::mem::size_of::<KittyFlags>() as u64;

pub const fn map_spine(entries: u64, entry_bytes: u64) -> u64 {
    if entries == 0 {
        return 0;
    }
    let capacity = entries.next_power_of_two();
    capacity.saturating_mul(entry_bytes)
}

pub const HYPERLINK_ID_ENTRY: u64 = std::mem::size_of::<(String, u32)>() as u64;
pub const IMAGE_ENTRY: u64 = std::mem::size_of::<(u32, crate::graphics::StoredImage)>() as u64;
pub const PENDING_ENTRY: u64 =
    std::mem::size_of::<(crate::graphics::ChunkKey, crate::graphics::PendingTransfer)>() as u64;
pub const PLACEMENT_SPINE: u64 = std::mem::size_of::<GraphicsPlacement>() as u64;
const _: () = assert!(std::mem::size_of::<Cell>() == 32);

pub const MIN_BYTES_PER_SCROLLBACK_ROW: usize = 6;
pub const MIN_BYTES_PER_LENGTH_PREFIXED: usize = 4;
pub const MIN_BYTES_PER_HYPERLINK_ID: usize = 8;
pub const MIN_BYTES_PER_PLACEMENT: usize = 16;
pub const MIN_BYTES_PER_IMAGE: usize = 25;
pub const MIN_BYTES_PER_PENDING: usize = 14;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CheckpointError {
    UnexpectedEof,
    InvalidMagic,
    UnsupportedVersion(u32),
    ChecksumMismatch { expected: u32, actual: u32 },
    InvalidPayloadLength { declared: usize, actual: usize },
    InvalidData(&'static str),
    DimensionOutOfBounds { cols: usize, rows: usize },
    AllocationLimitExceeded,
    TooLarge { size: u64, limit: u64 },
}

impl std::fmt::Display for CheckpointError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::UnexpectedEof => write!(f, "unexpected end of checkpoint buffer"),
            Self::InvalidMagic => write!(f, "invalid checkpoint magic (expected TKCK)"),
            Self::UnsupportedVersion(v) => write!(f, "unsupported checkpoint version {v}"),
            Self::ChecksumMismatch { expected, actual } => write!(
                f,
                "checkpoint CRC32 checksum mismatch (expected {expected:#x}, got {actual:#x})"
            ),
            Self::InvalidPayloadLength { declared, actual } => write!(
                f,
                "checkpoint payload length mismatch (declared {declared}, buffer has {actual})"
            ),
            Self::InvalidData(msg) => write!(f, "invalid checkpoint data: {msg}"),
            Self::DimensionOutOfBounds { cols, rows } => write!(
                f,
                "checkpoint terminal dimensions out of bounds ({cols}x{rows})"
            ),
            Self::AllocationLimitExceeded => write!(
                f,
                "checkpoint would allocate more than the {MAX_IMPORT_ALLOC_BYTES}-byte import limit"
            ),
            Self::TooLarge { size, limit } => write!(
                f,
                "checkpoint of {size} bytes exceeds the {limit}-byte wire limit"
            ),
        }
    }
}

impl std::error::Error for CheckpointError {}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CheckpointInfo {
    pub version: u32,
    pub flags: u32,
    pub cols: u32,
    pub rows: u32,
    pub payload_len: u32,
}

#[derive(Default)]
pub struct FieldOffsets {
    /// Absolute offset of the tab-stop column count, from the start of `data`.
    pub tab_cols: usize,
    /// Heap bytes this import charged against [`MAX_IMPORT_ALLOC_BYTES`],
    /// containers and contents alike.
    pub allocated: u64,
}
