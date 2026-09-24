//! Native versioned binary checkpoint and restore for Terminal.
//!
//! Provides atomic, lossless serialization and deserialization of the full
//! terminal state machine, including:
//! - Active, primary, and alternate screen buffers with styled cells,
//!   underlines, colors, hyperlinks, wide spacer and spacer head markers.
//! - Retained scrollback history lines and per-row soft-wrap flags.
//! - Cursor position, attributes, style, visibility, and deferred pending-wrap.
//! - DECSC / ESC 7 saved cursor state and attributes.
//! - Scroll margins (top/bottom/left/right) and origin mode.
//! - Custom tab stop bitmasks.
//! - DEC and ANSI terminal modes.
//! - In-flight parser state (CSI params/intermediates, DCS, OSC buffers,
//!   and partial UTF-8 multi-byte sequences).
//! - Viewport offset, title, title stack, palette, and Kitty keyboard state.
//!
//! Wire format specification (Version 3):
//! - Header (20 bytes):
//!   - `magic`: `[u8; 4]` = `b"TKCK"`
//!   - `version`: `u32` (little-endian, 3; versions 1 and 2 are still
//!     readable, and 2 can still be written for a peer that reads no newer)
//!   - `flags`: `u32` (little-endian, 0)
//!   - `payload_len`: `u32` (little-endian)
//!   - `checksum`: `u32` (little-endian, IEEE 802.3 CRC32 of payload bytes)
//! - Payload:
//!   - Binary structured payload with run-length encoded cells and strictly
//!     bounds-checked primitives.
//!
//! Version 2 differs from version 1 in exactly one way: it does not carry the
//! source surface's text selection. A v1 payload ends with that block --
//! `present: bool`, and when present `anchor_row`, `anchor_col`, `active_row`,
//! `active_col` as `u32` and `mode` as `u8` -- which this build reads past and
//! discards. A restore therefore never installs a foreign highlight, and never
//! decodes four attacker-supplied grid coordinates it does not validate.
//!
//! Version 3 is version 2 followed by the host configuration -- the palette
//! base and which entries a program has set since, the same for the default
//! foreground, background and cursor colour, and the default cursor style and
//! whether a program has changed it -- and then each grid's grapheme
//! clusters, whose cells otherwise carry only their first character. A v2 import has to guess those, and
//! guesses that every colour differing from the built-in default was a
//! program's -- so a theme's colours stayed on screen as "overrides" after a
//! destination with another theme set its own.

use std::collections::HashMap;

use super::{
    Cursor, DcsKind, GraphemeWidthMethod, GraphicsPlacement, ProtectedMode, SavedCursor,
    ScreenBuffer, SemanticContent, Terminal,
};
use crate::charset::Charset;
use crate::cursor_style::{CursorShape, CursorStyle};
use crate::grid::{Cell, CellAttrs, Color, Grid, ScrollbackRow, SemanticPrompt};
use crate::kitty_keyboard::{KittyFlags, KittyKeyboardState};
use crate::modes::{MouseTracking, TerminalModes};
use crate::palette::Palette;
use crate::parser::{Parser, ParserSnapshot, State};
use crate::response::ResponseQueue;
use crate::tabstops::TabStops;
use crate::title_stack::TitleStack;

pub const MAGIC: [u8; 4] = *b"TKCK";
pub const CURRENT_VERSION: u32 = 3;

/// The oldest container this build can write, for [`export_version`]. Version
/// 1 is readable but no longer written: it carried the selection.
pub const MIN_EXPORT_VERSION: u32 = 2;

/// The oldest container this build still reads.
///
/// Version 1 carried the source surface's text selection in the payload. A
/// selection belongs to the surface that owns the grid, not to the engine,
/// and its coordinates mean nothing in a destination whose viewport and
/// scrollback differ -- so v2 stops writing it. v1 containers are still
/// read: the decoder walks past those bytes and restores with no selection,
/// which is what a restored surface should show anyway.
pub const MIN_SUPPORTED_VERSION: u32 = 1;
pub const HEADER_SIZE: usize = 20;

/// The agreed wire cap, 64 MiB, applied to the **whole container** -- the
/// 20-byte header included.
///
/// One number governs both directions. Export refuses to emit a container
/// larger than this (see [`export_limited`]), and import refuses to look at
/// one before it allocates anything, so the largest blob this build can write
/// is exactly the largest it can read. Capping the payload on one side and the
/// container on the other is how an exporter comes to succeed at producing
/// something its own importer rejects.
pub const MAX_CONTAINER_LEN: usize = 64 * 1024 * 1024;

/// The largest payload a legal container can carry: the container cap less its
/// header. Kept because callers reason about the payload, and because
/// [`CheckpointInfo::payload_len`] is what they have in hand.
pub const MAX_PAYLOAD_LEN: usize = MAX_CONTAINER_LEN - HEADER_SIZE;
pub const MAX_DIM: usize = 10_000;
pub const MAX_SCROLLBACK_LEN: usize = 1_000_000;

/// A wire cap is not a memory cap. `Cell` is 32 bytes, run-length encoding is
/// how a checkpoint stays small, and the two together mean a legal 64 MiB
/// payload can declare billions of cells. So every declared count is charged
/// against this cumulative budget as it is decoded -- across the whole import,
/// not per field -- and export charges the same budget against the terminal it
/// is about to serialize, so a checkpoint this build writes is always one this
/// build can read back.
pub const MAX_IMPORT_ALLOC_BYTES: u64 = 512 * 1024 * 1024;

/// The measured size of one decoded grid cell. The allocation budget is
/// denominated in bytes, so it has to be the real figure, not a hoped-for one:
/// if `Cell` grows, this assertion fails rather than the budget silently
/// under-counting by a third.
pub const CELL_BYTES: u64 = std::mem::size_of::<Cell>() as u64;

/// The heap a collection commits for its own spine, per element, before a
/// single byte of that element's content is read.
///
/// Charging only the content is how a budget leaks: a payload can declare a
/// million empty scrollback rows in six megabytes and cost thirty-two
/// megabytes of `Vec<ScrollbackRow>` that the cumulative counter never sees.
/// Every reserved container below is charged for what reserving it costs.
pub const SCROLLBACK_ROW_SPINE: u64 = std::mem::size_of::<ScrollbackRow>() as u64;
/// Per visible row: the `Vec<Cell>` handle in the row vector, plus the wrap
/// flag and the semantic prompt kept in their own parallel vectors.
pub const GRID_ROW_SPINE: u64 = std::mem::size_of::<Vec<Cell>>() as u64 + 2;
/// A `String` handle inside a `Vec<String>`, separate from its bytes -- which
/// `read_string_budgeted` charges on their own.
pub const STRING_SPINE: u64 = std::mem::size_of::<String>() as u64;
/// One `KittyFlags` in the saved stack.
const KITTY_FLAGS_SPINE: u64 = std::mem::size_of::<KittyFlags>() as u64;

/// An upper bound on what a hash table commits for `entries` pairs of
/// `entry_bytes`.
///
/// The table keeps one control byte per bucket beside the pair, and grows the
/// bucket array past the entry count to stay under its load factor. Doubling
/// bounds that growth for every table this container builds, and bounding it
/// is the point: a budget that guesses low is not a budget.
const fn map_spine(entries: u64, entry_bytes: u64) -> u64 {
    entries
        .saturating_mul(entry_bytes.saturating_add(1))
        .saturating_mul(2)
}

/// `hyperlink_ids`: `HashMap<String, u32>`.
const HYPERLINK_ID_ENTRY: u64 = std::mem::size_of::<(String, u32)>() as u64;
/// `graphics.images`: `HashMap<u32, StoredImage>`.
const IMAGE_ENTRY: u64 = std::mem::size_of::<(u32, crate::graphics::StoredImage)>() as u64;
/// `graphics.pending`: `HashMap<ChunkKey, PendingTransfer>`.
const PENDING_ENTRY: u64 =
    std::mem::size_of::<(crate::graphics::ChunkKey, crate::graphics::PendingTransfer)>() as u64;
/// One decoded `GraphicsPlacement` in its vector.
const PLACEMENT_SPINE: u64 = std::mem::size_of::<GraphicsPlacement>() as u64;
const _: () = assert!(std::mem::size_of::<Cell>() == 32);

/// Smallest number of encoded payload bytes one scrollback row can occupy:
/// the wrapped flag, the cell count, and at least one cell opcode.
const MIN_BYTES_PER_SCROLLBACK_ROW: usize = 6;
/// Smallest encoded size of a length-prefixed byte string or `String`.
const MIN_BYTES_PER_LENGTH_PREFIXED: usize = 4;
/// Smallest encoded size of one hyperlink-id map entry (a string plus a u32).
const MIN_BYTES_PER_HYPERLINK_ID: usize = 8;
/// Smallest encoded size of one graphics placement (four u32s).
const MIN_BYTES_PER_PLACEMENT: usize = 16;
/// Smallest encoded size of one stored image (id, format, w, h, generation,
/// length-prefixed pixels).
const MIN_BYTES_PER_IMAGE: usize = 25;
/// Smallest encoded size of one pending chunked transfer (key tag, format,
/// w, h, length-prefixed data).
const MIN_BYTES_PER_PENDING: usize = 14;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CheckpointError {
    UnexpectedEof,
    InvalidMagic,
    UnsupportedVersion(u32),
    ChecksumMismatch { expected: u32, got: u32 },
    InvalidPayloadLength { declared: usize, actual: usize },
    InvalidData(&'static str),
    DimensionOutOfBounds { cols: usize, rows: usize },
    AllocationLimitExceeded,
    /// The state does not fit the declared limits. Returned by export, which
    /// refuses rather than emitting a checkpoint that could not be imported
    /// back, and by import for a payload over the wire cap.
    TooLarge { size: u64, limit: u64 },
}

impl std::fmt::Display for CheckpointError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::UnexpectedEof => write!(f, "unexpected end of checkpoint buffer"),
            Self::InvalidMagic => write!(f, "invalid checkpoint magic"),
            Self::UnsupportedVersion(v) => write!(f, "unsupported checkpoint version: {v}"),
            Self::ChecksumMismatch { expected, got } => {
                write!(f, "checkpoint CRC32 mismatch: expected {expected:#x}, got {got:#x}")
            }
            Self::InvalidPayloadLength { declared, actual } => {
                write!(f, "invalid payload length: declared {declared}, actual {actual}")
            }
            Self::InvalidData(msg) => write!(f, "invalid checkpoint data: {msg}"),
            Self::DimensionOutOfBounds { cols, rows } => {
                write!(f, "terminal dimension out of bounds: {cols}x{rows}")
            }
            Self::AllocationLimitExceeded => write!(f, "checkpoint memory limit exceeded"),
            Self::TooLarge { size, limit } => {
                write!(f, "checkpoint is {size} bytes, limit is {limit}")
            }
        }
    }
}

impl std::error::Error for CheckpointError {}

// Standard IEEE 802.3 CRC32 (polynomial 0xEDB88320)
const CRC32_TABLE: [u32; 256] = {
    let mut table = [0u32; 256];
    let mut i = 0;
    while i < 256 {
        let mut crc = i as u32;
        let mut j = 0;
        while j < 8 {
            crc = if (crc & 1) != 0 {
                0xEDB8_8320 ^ (crc >> 1)
            } else {
                crc >> 1
            };
            j += 1;
        }
        table[i] = crc;
        i += 1;
    }
    table
};

pub fn crc32(bytes: &[u8]) -> u32 {
    let mut crc = 0xFFFF_FFFFu32;
    for &b in bytes {
        let idx = ((crc ^ (b as u32)) & 0xFF) as usize;
        crc = CRC32_TABLE[idx] ^ (crc >> 8);
    }
    !crc
}

/// The payload sink.
///
/// `count` is what the payload *would* be; `buf` is what was actually
/// allocated. They are equal for as long as the payload fits `limit`, and once
/// it does not the writer stops allocating and keeps counting -- so export can
/// report the true size in `TooLarge { size, limit }` without ever having
/// allocated past the cap the caller asked for.
///
/// `retain` turns the same writer into a pure counting sink: every field is
/// still encoded and charged, and nothing is kept. That is what lets a size
/// query answer with the exact figure an export would produce without
/// building the export -- one encoder, so the two can never disagree.
struct Writer {
    buf: Vec<u8>,
    count: usize,
    limit: usize,
    retain: bool,
}

impl Writer {
    /// `limit` bounds the WHOLE container -- header included. A transport that
    /// says it will carry 64 MiB carries the blob, not the blob minus the
    /// twenty bytes that make it parseable.
    fn with_capacity(cap: usize, limit: usize) -> Self {
        Self {
            buf: Vec::with_capacity(cap.min(limit)),
            count: 0,
            limit,
            retain: true,
        }
    }

    /// A writer that keeps nothing. Measures a container without ever holding
    /// one: no capacity is reserved and no byte is stored, so the peak heap of
    /// a size query is independent of the checkpoint's size.
    fn counting(limit: usize) -> Self {
        Self {
            buf: Vec::new(),
            count: 0,
            limit,
            retain: false,
        }
    }

    /// Reserve the container header slot and charge it to the count. Writing
    /// the twenty bytes directly into `buf` would put them outside the only
    /// thing that enforces the cap, so the reservation goes through the same
    /// accounting as everything else.
    fn reserve_header(&mut self) {
        self.count = HEADER_SIZE;
        if self.retain && HEADER_SIZE <= self.limit {
            self.buf.resize(HEADER_SIZE, 0);
        }
    }

    #[inline]
    fn push(&mut self, bytes: &[u8]) {
        let next = self.count.saturating_add(bytes.len());
        if self.retain && next <= self.limit {
            self.buf.extend_from_slice(bytes);
        }
        self.count = next;
    }

    #[inline]
    fn overflowed(&self) -> bool {
        self.count > self.limit
    }

    #[inline]
    fn write_u8(&mut self, val: u8) {
        self.push(&[val]);
    }

    #[inline]
    fn write_u16(&mut self, val: u16) {
        self.push(&val.to_le_bytes());
    }

    #[inline]
    fn write_u32(&mut self, val: u32) {
        self.push(&val.to_le_bytes());
    }

    #[inline]
    fn write_u64(&mut self, val: u64) {
        self.push(&val.to_le_bytes());
    }

    #[inline]
    fn write_bool(&mut self, val: bool) {
        self.write_u8(if val { 1 } else { 0 });
    }

    fn write_bytes(&mut self, bytes: &[u8]) {
        self.write_u32(bytes.len() as u32);
        self.push(bytes);
    }

    fn write_string(&mut self, s: &str) {
        self.write_bytes(s.as_bytes());
    }

    fn write_color(&mut self, c: Color) {
        match c {
            Color::Default => self.write_u8(0),
            Color::Indexed(n) => {
                self.write_u8(1);
                self.write_u8(n);
            }
            Color::Rgb(r, g, b) => {
                self.write_u8(2);
                self.write_u8(r);
                self.write_u8(g);
                self.write_u8(b);
            }
        }
    }

    fn write_single_cell_content(&mut self, cell: &Cell) {
        self.write_u32(cell.char as u32);
        self.write_color(cell.fg);
        self.write_color(cell.bg);
        self.write_u16(cell.attrs.bits());
        let mut flags = 0u8;
        if cell.is_wide_spacer {
            flags |= 1 << 0;
        }
        if cell.protected {
            flags |= 1 << 1;
        }
        if cell.is_wide_spacer_head {
            flags |= 1 << 2;
        }
        if cell.underline_color != Color::Default {
            flags |= 1 << 3;
        }
        if cell.hyperlink.is_some() {
            flags |= 1 << 4;
        }
        self.write_u8(flags);
        self.write_u8(cell.underline_style);
        if cell.underline_color != Color::Default {
            self.write_color(cell.underline_color);
        }
        if let Some(id) = cell.hyperlink {
            self.write_u32(id);
        }
    }

    fn write_cells(&mut self, cells: &[Cell]) {
        let mut idx = 0;
        let default_cell = Cell::default();
        while idx < cells.len() {
            let cell = &cells[idx];
            if *cell == default_cell {
                let start = idx;
                while idx < cells.len() && cells[idx] == default_cell && (idx - start) < 65535 {
                    idx += 1;
                }
                let count = idx - start;
                if count == 1 {
                    self.write_u8(0x00);
                } else {
                    self.write_u8(0x01);
                    self.write_u16(count as u16);
                }
            } else {
                let start = idx;
                while idx < cells.len() && cells[idx] == *cell && (idx - start) < 65535 {
                    idx += 1;
                }
                let count = idx - start;
                if count == 1 {
                    self.write_u8(0x02);
                    self.write_single_cell_content(cell);
                } else {
                    self.write_u8(0x03);
                    self.write_u16(count as u16);
                    self.write_single_cell_content(cell);
                }
            }
        }
    }
}

struct Reader<'a> {
    data: &'a [u8],
    pos: usize,
    /// Heap bytes this import has committed to so far, across every field.
    alloc: u64,
}

impl<'a> Reader<'a> {
    fn new(data: &'a [u8]) -> Self {
        Self::with_reservation(data, 0)
    }

    /// A reader that starts the budget already partly spent.
    ///
    /// `reserved` is heap that stays live for the duration of the import and
    /// so is not available to it -- the destination terminal that is still
    /// standing while its replacement is built, and the container the caller
    /// is holding. Charging it up front is what makes the budget describe the
    /// import's real peak instead of the replacement in isolation.
    fn with_reservation(data: &'a [u8], reserved: u64) -> Self {
        Self {
            data,
            pos: 0,
            alloc: reserved,
        }
    }

    #[inline]
    fn remaining(&self) -> usize {
        self.data.len().saturating_sub(self.pos)
    }

    /// Charge `bytes` against the cumulative budget *before* the allocation
    /// they pay for is made.
    fn charge(&mut self, bytes: u64) -> Result<(), CheckpointError> {
        self.alloc = self.alloc.saturating_add(bytes);
        if self.alloc > MAX_IMPORT_ALLOC_BYTES {
            return Err(CheckpointError::AllocationLimitExceeded);
        }
        Ok(())
    }

    /// Charge a container's own spine: `count` elements at `per_element`
    /// bytes, before the container is reserved.
    fn charge_spine(&mut self, count: usize, per_element: u64) -> Result<(), CheckpointError> {
        self.charge((count as u64).saturating_mul(per_element))
    }

    /// A declared element count is only credible if the payload still holds
    /// the minimum encoding of that many elements. Checked before the count
    /// is used to reserve anything.
    fn check_count(&self, count: usize, min_bytes_each: usize) -> Result<(), CheckpointError> {
        match count.checked_mul(min_bytes_each) {
            Some(needed) if needed <= self.remaining() => Ok(()),
            _ => Err(CheckpointError::UnexpectedEof),
        }
    }

    /// A length-prefixed byte string bounded by what is actually left in the
    /// payload and charged against the cumulative budget -- deliberately not
    /// by a per-field constant, which is how export and import came apart.
    fn read_bytes_budgeted(&mut self) -> Result<&'a [u8], CheckpointError> {
        let len = self.read_u32()? as usize;
        if len > self.remaining() {
            return Err(CheckpointError::UnexpectedEof);
        }
        self.charge(len as u64)?;
        let slice = &self.data[self.pos..self.pos + len];
        self.pos += len;
        Ok(slice)
    }

    fn read_string_budgeted(&mut self) -> Result<String, CheckpointError> {
        let bytes = self.read_bytes_budgeted()?;
        String::from_utf8(bytes.to_vec())
            .map_err(|_| CheckpointError::InvalidData("non-utf8 string in checkpoint"))
    }

    fn read_u8(&mut self) -> Result<u8, CheckpointError> {
        if self.pos >= self.data.len() {
            return Err(CheckpointError::UnexpectedEof);
        }
        let val = self.data[self.pos];
        self.pos += 1;
        Ok(val)
    }

    fn read_u16(&mut self) -> Result<u16, CheckpointError> {
        if self.remaining() < 2 {
            return Err(CheckpointError::UnexpectedEof);
        }
        let bytes = [self.data[self.pos], self.data[self.pos + 1]];
        self.pos += 2;
        Ok(u16::from_le_bytes(bytes))
    }

    fn read_u32(&mut self) -> Result<u32, CheckpointError> {
        if self.remaining() < 4 {
            return Err(CheckpointError::UnexpectedEof);
        }
        let bytes = [
            self.data[self.pos],
            self.data[self.pos + 1],
            self.data[self.pos + 2],
            self.data[self.pos + 3],
        ];
        self.pos += 4;
        Ok(u32::from_le_bytes(bytes))
    }

    fn read_u64(&mut self) -> Result<u64, CheckpointError> {
        if self.remaining() < 8 {
            return Err(CheckpointError::UnexpectedEof);
        }
        let mut bytes = [0u8; 8];
        bytes.copy_from_slice(&self.data[self.pos..self.pos + 8]);
        self.pos += 8;
        Ok(u64::from_le_bytes(bytes))
    }

    fn read_bool(&mut self) -> Result<bool, CheckpointError> {
        Ok(self.read_u8()? != 0)
    }

    fn read_exact_bytes(&mut self, len: usize) -> Result<&'a [u8], CheckpointError> {
        if self.remaining() < len {
            return Err(CheckpointError::UnexpectedEof);
        }
        let slice = &self.data[self.pos..self.pos + len];
        self.pos += len;
        Ok(slice)
    }

    fn read_color(&mut self) -> Result<Color, CheckpointError> {
        match self.read_u8()? {
            0 => Ok(Color::Default),
            1 => {
                let n = self.read_u8()?;
                Ok(Color::Indexed(n))
            }
            2 => {
                let r = self.read_u8()?;
                let g = self.read_u8()?;
                let b = self.read_u8()?;
                Ok(Color::Rgb(r, g, b))
            }
            _ => Err(CheckpointError::InvalidData("invalid color tag")),
        }
    }

    fn read_single_cell_content(&mut self) -> Result<Cell, CheckpointError> {
        let cp = self.read_u32()?;
        let ch = char::from_u32(cp).unwrap_or('\0');
        let fg = self.read_color()?;
        let bg = self.read_color()?;
        let attrs_bits = self.read_u16()?;
        let attrs = CellAttrs::from_bits_truncate(attrs_bits);
        let flags = self.read_u8()?;
        let is_wide_spacer = (flags & (1 << 0)) != 0;
        let protected = (flags & (1 << 1)) != 0;
        let is_wide_spacer_head = (flags & (1 << 2)) != 0;
        let has_underline_color = (flags & (1 << 3)) != 0;
        let has_hyperlink = (flags & (1 << 4)) != 0;
        let underline_style = self.read_u8()?;
        let underline_color = if has_underline_color {
            self.read_color()?
        } else {
            Color::Default
        };
        let hyperlink = if has_hyperlink {
            Some(self.read_u32()?)
        } else {
            None
        };
        Ok(Cell {
            char: ch,
            fg,
            bg,
            attrs,
            hyperlink,
            is_wide_spacer,
            protected,
            is_wide_spacer_head,
            underline_style,
            underline_color,
            grapheme: 0,
        })
    }

    fn read_cells(&mut self, expected_len: usize) -> Result<Vec<Cell>, CheckpointError> {
        let mut cells = Vec::with_capacity(expected_len);
        let default_cell = Cell::default();
        while cells.len() < expected_len {
            match self.read_u8()? {
                0x00 => {
                    cells.push(default_cell);
                }
                0x01 => {
                    let count = self.read_u16()? as usize;
                    if count == 0 || cells.len() + count > expected_len {
                        return Err(CheckpointError::InvalidData("run length exceeds row width"));
                    }
                    cells.resize(cells.len() + count, default_cell);
                }
                0x02 => {
                    let cell = self.read_single_cell_content()?;
                    cells.push(cell);
                }
                0x03 => {
                    let count = self.read_u16()? as usize;
                    if count == 0 || cells.len() + count > expected_len {
                        return Err(CheckpointError::InvalidData("run length exceeds row width"));
                    }
                    let cell = self.read_single_cell_content()?;
                    cells.resize(cells.len() + count, cell);
                }
                _ => return Err(CheckpointError::InvalidData("unknown cell opcode")),
            }
        }
        if cells.len() != expected_len {
            return Err(CheckpointError::InvalidData("cells decoded length mismatch"));
        }
        Ok(cells)
    }
}

/// Verify that `data` is a well-formed checkpoint buffer without allocating or decoding grids.
///
/// Kept for source compatibility; it conflates "corrupt" with "a version I
/// cannot read", which is why [`inspect`] and [`supports`] exist.
pub fn verify(data: &[u8]) -> bool {
    validate(data).is_ok()
}

/// [`verify`] with the reason kept.
///
/// Header, version, declared payload length and CRC32 only -- the payload is
/// not decoded, so a container that passes here can still fail an [`import`]
/// on a structurally invalid field.
pub fn validate(data: &[u8]) -> Result<(), CheckpointError> {
    validate_container(data).map(|_| ())
}

/// The container version this build writes.
pub fn version() -> u32 {
    CURRENT_VERSION
}

/// Whether this build can import that container version. Explicit, so a peer
/// can negotiate a version rather than infer one from a failed import.
pub fn supports(version: u32) -> bool {
    (MIN_SUPPORTED_VERSION..=CURRENT_VERSION).contains(&version)
}

/// What a checkpoint declares about itself, without decoding it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CheckpointInfo {
    pub version: u32,
    pub flags: u32,
    pub cols: u32,
    pub rows: u32,
    pub payload_len: u32,
}

/// Read the header and leading geometry of a checkpoint without allocating a
/// grid, so a caller can decide whether to commit to an import at all.
pub fn inspect(data: &[u8]) -> Result<CheckpointInfo, CheckpointError> {
    let (_, payload) = validate_container(data)?;
    let mut r = Reader::new(payload);
    let cols = r.read_u32()?;
    let rows = r.read_u32()?;
    Ok(CheckpointInfo {
        version: u32::from_le_bytes([data[4], data[5], data[6], data[7]]),
        flags: u32::from_le_bytes([data[8], data[9], data[10], data[11]]),
        cols,
        rows,
        payload_len: payload.len() as u32,
    })
}

/// Magic, version, declared length and CRC. Returns the payload slice.
///
/// Version is checked before the checksum on purpose: a container from a
/// newer peer must come back as `UnsupportedVersion`, never as corruption.
fn validate_container(data: &[u8]) -> Result<(u32, &[u8]), CheckpointError> {
    if data.len() < HEADER_SIZE {
        return Err(CheckpointError::UnexpectedEof);
    }
    if data[0..4] != MAGIC {
        return Err(CheckpointError::InvalidMagic);
    }
    let version = u32::from_le_bytes([data[4], data[5], data[6], data[7]]);
    if !supports(version) {
        return Err(CheckpointError::UnsupportedVersion(version));
    }
    let payload_len = u32::from_le_bytes([data[12], data[13], data[14], data[15]]) as usize;
    // The cap covers the header too, so this is the same number export was
    // held to. Reported as the container size against the container limit --
    // subtracting a header the caller never sees would make the diagnostic
    // unusable for choosing a smaller cap.
    let container_len = (HEADER_SIZE as u64).saturating_add(payload_len as u64);
    if container_len > MAX_CONTAINER_LEN as u64 {
        return Err(CheckpointError::TooLarge {
            size: container_len,
            limit: MAX_CONTAINER_LEN as u64,
        });
    }
    if data.len() != HEADER_SIZE + payload_len {
        return Err(CheckpointError::InvalidPayloadLength {
            declared: payload_len,
            actual: data.len().saturating_sub(HEADER_SIZE),
        });
    }
    let expected_crc = u32::from_le_bytes([data[16], data[17], data[18], data[19]]);
    let actual_crc = crc32(&data[HEADER_SIZE..]);
    if expected_crc != actual_crc {
        return Err(CheckpointError::ChecksumMismatch {
            expected: expected_crc,
            got: actual_crc,
        });
    }
    Ok((version, &data[HEADER_SIZE..]))
}

/// The heap an import of this terminal will commit to, charged exactly the way
/// [`import`] charges it.
///
/// Export runs this before it writes anything, so the invariant holds in both
/// directions: a checkpoint this build produces is one this build accepts.
/// Anything added to the charge list in `import` belongs here too.
fn allocation_cost(term: &Terminal) -> u64 {
    let mut total: u64 = 0;
    let mut grid_cost = |grid: &Grid| {
        total = total.saturating_add(
            (grid.rows() as u64)
                .saturating_mul(grid.cols() as u64)
                .saturating_mul(CELL_BYTES),
        );
        total = total.saturating_add((grid.rows() as u64).saturating_mul(GRID_ROW_SPINE));
        let mut sb_rows: u64 = 0;
        for row in grid.scrollback_iter() {
            total = total.saturating_add((row.len() as u64).saturating_mul(CELL_BYTES));
            sb_rows += 1;
        }
        total = total.saturating_add(sb_rows.saturating_mul(SCROLLBACK_ROW_SPINE));
        for (_, _, extra, _) in grid.clusters() {
            total = total.saturating_add(extra.len() as u64);
        }
    };
    grid_cost(&term.primary);
    grid_cost(&term.alternate);

    let mut bytes: u64 = term.active_grid().cols() as u64; // tab stop bitset, decoded
    let ps = term.parser.view();
    bytes = bytes.saturating_add(ps.osc_raw.len() as u64);
    bytes = bytes.saturating_add(ps.apc_raw.len() as u64);
    bytes = bytes.saturating_add(term.dcs_buf.len() as u64);
    bytes = bytes.saturating_add((term.hyperlinks.len() as u64).saturating_mul(STRING_SPINE));
    for h in &term.hyperlinks {
        bytes = bytes.saturating_add(h.len() as u64);
    }
    bytes = bytes.saturating_add(map_spine(
        term.hyperlink_ids.len() as u64,
        HYPERLINK_ID_ENTRY,
    ));
    for k in term.hyperlink_ids.keys() {
        // The key's bytes only: its `String` handle and the `u32` id beside it
        // are already inside `HYPERLINK_ID_ENTRY`, and import charges the key
        // through `read_string_budgeted` the same way.
        bytes = bytes.saturating_add(k.len() as u64);
    }
    bytes = bytes.saturating_add(term.title.len() as u64);
    bytes = bytes.saturating_add(
        (term.title_stack.items().len() as u64).saturating_mul(STRING_SPINE),
    );
    for item in term.title_stack.items() {
        bytes = bytes.saturating_add(item.len() as u64);
    }
    bytes = bytes.saturating_add(
        (term.kitty_keyboard.stack().len() as u64).saturating_mul(KITTY_FLAGS_SPINE),
    );
    bytes = bytes.saturating_add(term.answerback.len() as u64);
    bytes = bytes.saturating_add(term.xtversion.len() as u64);
    bytes = bytes.saturating_add(
        (term.graphics_placements.len() as u64).saturating_mul(PLACEMENT_SPINE),
    );
    bytes = bytes.saturating_add(map_spine(
        term.graphics.images().len() as u64,
        IMAGE_ENTRY,
    ));
    for img in term.graphics.images().values() {
        bytes = bytes.saturating_add(img.pixels.len() as u64);
    }
    bytes = bytes.saturating_add(map_spine(
        term.graphics.pending().len() as u64,
        PENDING_ENTRY,
    ));
    for transfer in term.graphics.pending().values() {
        bytes = bytes.saturating_add(transfer.data.len() as u64);
    }
    total.saturating_add(bytes)
}

/// The heap an [`import`] of a checkpoint of `term` will commit to.
///
/// The same number [`export`] refuses above [`MAX_IMPORT_ALLOC_BYTES`], published
/// so a host can ask before it asks for the blob -- and so the symmetry between
/// what export charges and what import charges is testable rather than asserted
/// in a comment.
pub fn import_cost(term: &Terminal) -> u64 {
    allocation_cost(term)
}

/// The heap `term` is *holding right now*, counted by capacity.
///
/// This is deliberately not [`import_cost`]. That one answers "how much will a
/// fresh decode of a checkpoint of this state allocate?" and is measured in
/// lengths, because a decoder allocates exactly what it reads. This one answers
/// "how much is this terminal occupying?", and the answer is capacities:
///
/// * `Parser::clear` on a finished OSC is `Vec::clear`, which drops the length
///   and keeps the allocation. A terminal that has just consumed an 8 MiB OSC
///   is still holding 8 MiB while every length in it reads zero.
/// * A grid resized down from 500 columns to 80 still owns the wide rows.
/// * A drained response queue or a completed graphics transfer keeps its buffer.
///
/// [`Terminal::import_checkpoint`] builds the replacement *beside* the terminal
/// it replaces, so the destination's retained heap is live for the whole of the
/// import and belongs in the peak the budget is checked against. Charging
/// `import_cost` there instead would let exactly the states above -- large
/// buffers, logically empty -- disappear from the budget while still occupying
/// the process.
///
/// Conservative by construction: it counts what each container has reserved,
/// which is at least what it is using, and it borrows every buffer it counts
/// rather than copying one in order to measure it.
pub fn retained_cost(term: &Terminal) -> u64 {
    let mut total: u64 = 0;
    total = total.saturating_add(term.primary.retained_capacity_bytes());
    total = total.saturating_add(term.alternate.retained_capacity_bytes());
    total = total.saturating_add(term.parser.retained_capacity_bytes());
    total = total.saturating_add(term.tabstops.retained_capacity_bytes());
    total = total.saturating_add(term.kitty_keyboard.retained_capacity_bytes());
    total = total.saturating_add(term.response.retained_capacity_bytes());
    total = total.saturating_add(term.graphics.retained_capacity_bytes());
    total = total.saturating_add(term.title_stack.retained_capacity_bytes());

    total = total.saturating_add(term.title.capacity() as u64);
    total = total.saturating_add(term.answerback.capacity() as u64);
    total = total.saturating_add(term.xtversion.capacity() as u64);
    total = total.saturating_add(term.dcs_buf.capacity() as u64);

    total = total.saturating_add(
        (term.hyperlinks.capacity() as u64).saturating_mul(STRING_SPINE),
    );
    for h in &term.hyperlinks {
        total = total.saturating_add(h.capacity() as u64);
    }
    total = total.saturating_add(map_spine(
        term.hyperlink_ids.capacity() as u64,
        HYPERLINK_ID_ENTRY,
    ));
    for k in term.hyperlink_ids.keys() {
        total = total.saturating_add(k.capacity() as u64);
    }

    total = total.saturating_add(
        (term.graphics_placements.capacity() as u64).saturating_mul(PLACEMENT_SPINE),
    );
    total = total.saturating_add(
        (term.events.capacity() as u64)
            .saturating_mul(std::mem::size_of::<crate::terminal::TerminalEvent>() as u64),
    );
    for event in &term.events {
        total = total.saturating_add(event_payload_bytes(event));
    }
    total
}

/// Heap owned by one queued event, beyond the slot it occupies in `events`.
///
/// Events never enter a checkpoint -- they are host-bound side effects, and
/// replaying a bell or a clipboard write on restore would be wrong. But they
/// are still the destination's memory until the host calls `take_events`, and
/// an OSC 52 payload is a megabyte in a 24-byte slot.
///
/// The match is deliberately exhaustive: no `_` arm, so a new variant that
/// carries a `String` or a `Vec` cannot be added without this function
/// refusing to compile.
fn event_payload_bytes(event: &crate::terminal::TerminalEvent) -> u64 {
    use crate::terminal::TerminalEvent as E;
    match event {
        E::TitleChanged(s) | E::ClipboardSet(s) | E::PwdChanged(s) => s.capacity() as u64,
        E::Notification { title, body } => {
            (title.capacity() as u64).saturating_add(body.capacity() as u64)
        }
        E::Bell
        | E::ClipboardQuery
        | E::Progress { .. }
        | E::CommandStart
        | E::CommandEnd { .. } => 0,
    }
}

/// Export the complete terminal state as a versioned binary checkpoint,
/// bounded by the wire cap.
pub fn export(term: &Terminal) -> Result<Vec<u8>, CheckpointError> {
    export_limited(term, MAX_CONTAINER_LEN as u64)
}

/// Export bounded by a caller-supplied byte cap.
///
/// The effective limit is `min(max_bytes, MAX_CONTAINER_LEN)`, and `max_bytes`
/// of 0 means the library ceiling alone. The limit bounds the whole container,
/// header included, so a successful export always satisfies
/// `blob.len() <= limit`; exceeding it fails with `TooLarge { size, limit }`
/// where `size` is the full size the blob would have needed. `term` is taken by
/// shared reference: a failed export cannot have mutated, truncated, cleared
/// or reset anything -- it simply produces no checkpoint.
pub fn export_limited(term: &Terminal, max_bytes: u64) -> Result<Vec<u8>, CheckpointError> {
    export_version(term, CURRENT_VERSION, max_bytes)
}

/// [`export_limited`] in a chosen container version, so a host can write the
/// newest one its peer [`supports`] and upgrading one side never makes the
/// other refuse its checkpoints. 0 means [`CURRENT_VERSION`]; anything outside
/// [`MIN_EXPORT_VERSION`]..=[`CURRENT_VERSION`] fails with
/// `UnsupportedVersion`. What an older version cannot carry is left out: a v2
/// checkpoint has no host configuration.
pub fn export_version(
    term: &Terminal,
    version: u32,
    max_bytes: u64,
) -> Result<Vec<u8>, CheckpointError> {
    let version = export_target(version)?;
    let limit = effective_limit(max_bytes);
    let mut w = encode(term, limit, true, version)?;

    let payload_len = (w.buf.len() - HEADER_SIZE) as u32;
    let checksum = crc32(&w.buf[HEADER_SIZE..]);

    w.buf[0..4].copy_from_slice(&MAGIC);
    w.buf[4..8].copy_from_slice(&version.to_le_bytes());
    w.buf[8..12].copy_from_slice(&0u32.to_le_bytes()); // flags
    w.buf[12..16].copy_from_slice(&payload_len.to_le_bytes());
    w.buf[16..20].copy_from_slice(&checksum.to_le_bytes());

    Ok(w.buf)
}

/// How many bytes [`export`] would produce, without producing them.
///
/// Same encoder, same limit, same refusals -- a query that succeeds returns
/// exactly the length the matching export returns, and a query that fails
/// fails with the error the export would have failed with. What it does not do
/// is allocate the checkpoint: the answer to "how big is it" should not cost
/// the thing being measured, which is what makes the NULL/0 half of the
/// two-call C idiom cheap rather than merely convenient.
pub fn measure(term: &Terminal) -> Result<u64, CheckpointError> {
    measure_limited(term, MAX_CONTAINER_LEN as u64)
}

/// [`measure`] bounded by a caller-supplied byte cap, mirroring
/// [`export_limited`].
pub fn measure_limited(term: &Terminal, max_bytes: u64) -> Result<u64, CheckpointError> {
    measure_version(term, CURRENT_VERSION, max_bytes)
}

/// [`measure_limited`] for the container [`export_version`] would write.
pub fn measure_version(term: &Terminal, version: u32, max_bytes: u64) -> Result<u64, CheckpointError> {
    let version = export_target(version)?;
    let limit = effective_limit(max_bytes);
    Ok(encode(term, limit, false, version)?.count as u64)
}

/// The version an export writes: 0 is the current one.
fn export_target(version: u32) -> Result<u32, CheckpointError> {
    match version {
        0 => Ok(CURRENT_VERSION),
        v if (MIN_EXPORT_VERSION..=CURRENT_VERSION).contains(&v) => Ok(v),
        v => Err(CheckpointError::UnsupportedVersion(v)),
    }
}

/// 0 is "no caller limit", not "a limit of zero": a caller that has no
/// transport bound of its own asks for the library ceiling rather than for a
/// guaranteed failure.
fn effective_limit(max_bytes: u64) -> u64 {
    if max_bytes == 0 {
        MAX_CONTAINER_LEN as u64
    } else {
        max_bytes.min(MAX_CONTAINER_LEN as u64)
    }
}

/// Encode the whole container into a writer, retaining the bytes or merely
/// counting them.
///
/// Every refusal an export can make is made here, so a measurement and an
/// export of the same terminal agree on success, on failure, and on the size.
fn encode(term: &Terminal, limit: u64, retain: bool, version: u32) -> Result<Writer, CheckpointError> {
    // Export refuses exactly what import refuses. A terminal may legally be
    // wider or taller than `MAX_DIM` -- nothing here resizes it -- but a
    // checkpoint of one could never be read back, and a success return on an
    // un-importable blob is the asymmetry this container exists to remove.
    let (cols, rows) = (term.active_grid().cols(), term.active_grid().rows());
    if cols == 0 || cols > MAX_DIM || rows == 0 || rows > MAX_DIM {
        return Err(CheckpointError::DimensionOutOfBounds { cols, rows });
    }

    // Refuse before writing anything if importing this state back would blow
    // the cumulative allocation budget. Truncating the parser's in-flight
    // buffers to fit, or resetting anything, would be a lossy export wearing
    // a success return; failing here keeps "a successful export is importable"
    // true without touching the terminal.
    let cost = allocation_cost(term);
    if cost > MAX_IMPORT_ALLOC_BYTES {
        return Err(CheckpointError::TooLarge {
            size: cost,
            limit: MAX_IMPORT_ALLOC_BYTES,
        });
    }

    let mut w = if retain {
        Writer::with_capacity(4096, limit as usize)
    } else {
        Writer::counting(limit as usize)
    };
    // Reserve the 20-byte header slot. It counts against the limit: the cap
    // governs the entire container, so `blob.len() <= limit` always holds for
    // a successful export.
    w.reserve_header();

    w.write_u32(cols as u32);
    w.write_u32(rows as u32);
    w.write_u8(match term.active {
        ScreenBuffer::Primary => 0,
        ScreenBuffer::Alternate => 1,
    });
    w.write_u32(term.scroll_top as u32);
    w.write_u32(term.scroll_bottom as u32);
    w.write_u32(term.scroll_left as u32);
    w.write_u32(term.scroll_right as u32);
    w.write_u32(term.viewport_offset as u32);
    w.write_bool(term.pending_wrap);

    // Primary Grid
    write_grid(&mut w, &term.primary, rows);

    // Alternate Grid
    write_grid(&mut w, &term.alternate, rows);

    // Cursor
    w.write_u32(term.cursor.row as u32);
    w.write_u32(term.cursor.col as u32);
    w.write_color(term.cursor.fg);
    w.write_color(term.cursor.bg);
    w.write_u16(term.cursor.attrs.bits());
    w.write_u8(term.cursor.underline_style);
    w.write_color(term.cursor.underline_color);
    w.write_bool(term.cursor_visible);
    w.write_u8(shape_code(term.cursor_style.shape));
    w.write_bool(term.cursor_style.blinking);

    // Saved Cursor
    if let Some(ref saved) = term.cursor.saved {
        w.write_bool(true);
        w.write_u32(saved.row as u32);
        w.write_u32(saved.col as u32);
        w.write_color(saved.fg);
        w.write_color(saved.bg);
        w.write_u16(saved.attrs.bits());
        w.write_u8(match saved.g0 {
            Charset::Ascii => 0,
            Charset::DecSpecialGraphics => 1,
            Charset::British => 2,
        });
        w.write_u8(match saved.g1 {
            Charset::Ascii => 0,
            Charset::DecSpecialGraphics => 1,
            Charset::British => 2,
        });
        w.write_bool(saved.shift_out);
        w.write_bool(saved.origin_mode);
        w.write_bool(saved.pending_wrap);
        w.write_u8(match saved.protected_mode {
            ProtectedMode::Off => 0,
            ProtectedMode::Iso => 1,
            ProtectedMode::Dec => 2,
        });
        w.write_u8(saved.gr_slot);
    } else {
        w.write_bool(false);
    }

    // Tab Stops (packed bitset)
    let stops = term.tabstops.stops();
    w.write_u32(cols as u32);
    let num_bytes = cols.div_ceil(8);
    let mut bitset = vec![0u8; num_bytes];
    for (i, &b) in stops.iter().enumerate() {
        if b && i < cols {
            bitset[i / 8] |= 1 << (i % 8);
        }
    }
    w.push(&bitset);

    // Terminal Modes
    let m = &term.modes;
    let mut mode_flags = 0u32;
    if m.autowrap { mode_flags |= 1 << 0; }
    if m.origin_mode { mode_flags |= 1 << 1; }
    if m.cursor_key_app_mode { mode_flags |= 1 << 2; }
    if m.mouse_utf8 { mode_flags |= 1 << 3; }
    if m.mouse_sgr { mode_flags |= 1 << 4; }
    if m.focus_events { mode_flags |= 1 << 5; }
    if m.bracketed_paste { mode_flags |= 1 << 6; }
    if m.insert { mode_flags |= 1 << 7; }
    if m.linefeed_mode { mode_flags |= 1 << 8; }
    if m.reverse_wrap { mode_flags |= 1 << 9; }
    if m.reverse_wrap_extended { mode_flags |= 1 << 10; }
    if m.left_right_margin_mode { mode_flags |= 1 << 11; }
    if m.alternate_scroll { mode_flags |= 1 << 12; }
    if m.synchronized_output { mode_flags |= 1 << 13; }
    // XTSHIFTESCAPE: whether a program asked (14), and what (15). A reader
    // that predates the bits ignores them, which is what it did before.
    if let Some(capture) = m.shift_capture {
        mode_flags |= 1 << 14;
        if capture { mode_flags |= 1 << 15; }
    }
    w.write_u32(mode_flags);
    w.write_u8(match m.mouse_tracking {
        MouseTracking::Off => 0,
        MouseTracking::Normal => 1,
        MouseTracking::ButtonEvent => 2,
        MouseTracking::AnyEvent => 3,
    });

    // Parser State
    let ps = term.parser.view();
    w.write_u8(match ps.state {
        State::Ground => 0,
        State::Escape => 1,
        State::EscapeIntermediate => 2,
        State::CsiEntry => 3,
        State::CsiParam => 4,
        State::CsiIntermediate => 5,
        State::CsiIgnore => 6,
        State::DcsEntry => 7,
        State::DcsParam => 8,
        State::DcsIntermediate => 9,
        State::DcsPassthrough => 10,
        State::DcsIgnore => 11,
        State::OscString => 12,
        State::SosPmApcString => 13,
    });
    let inter_len = ps.intermediates.len().min(16);
    w.write_u8(inter_len as u8);
    w.push(&ps.intermediates[..inter_len]);
    w.write_u8(ps.params.len() as u8);
    for &param in ps.params {
        w.write_u16(param);
    }
    w.write_u32(ps.params_sep);
    w.write_bool(ps.ignore);
    w.write_bytes(ps.osc_raw);
    w.write_bytes(ps.apc_raw);
    w.write_u8(ps.utf8_need);
    w.write_u32(ps.utf8_cp);

    // Terminal DCS State
    w.write_u8(match term.dcs {
        None => 0,
        Some(DcsKind::Decrqss) => 1,
        Some(DcsKind::XtGetTcap) => 2,
    });
    w.write_bytes(&term.dcs_buf);

    // Charsets & Shift
    let charset_to_u8 = |cs: Charset| match cs {
        Charset::Ascii => 0,
        Charset::DecSpecialGraphics => 1,
        Charset::British => 2,
    };
    w.write_u8(charset_to_u8(term.g0));
    w.write_u8(charset_to_u8(term.g1));
    w.write_u8(charset_to_u8(term.g2));
    w.write_u8(charset_to_u8(term.g3));
    w.write_bool(term.shift_out);
    w.write_u8(term.gr_slot);
    if let Some(cs) = term.single_shift {
        w.write_bool(true);
        w.write_u8(charset_to_u8(cs));
    } else {
        w.write_bool(false);
    }

    // Hyperlinks
    w.write_u32(term.hyperlinks.len() as u32);
    for h in &term.hyperlinks {
        w.write_string(h);
    }
    w.write_u32(term.hyperlink_ids.len() as u32);
    for (k, &v) in &term.hyperlink_ids {
        w.write_string(k);
        w.write_u32(v);
    }
    if let Some(id) = term.current_hyperlink {
        w.write_bool(true);
        w.write_u32(id);
    } else {
        w.write_bool(false);
    }

    // Title & Title Stack
    w.write_string(&term.title);
    let t_items = term.title_stack.items();
    w.write_u32(t_items.len() as u32);
    for item in t_items {
        w.write_string(item);
    }

    // Palette & Overrides
    for &rgb in term.palette.colors() {
        w.write_u8(rgb.0);
        w.write_u8(rgb.1);
        w.write_u8(rgb.2);
    }
    if let Some(rgb) = term.default_fg {
        w.write_bool(true);
        w.write_u8(rgb.0);
        w.write_u8(rgb.1);
        w.write_u8(rgb.2);
    } else {
        w.write_bool(false);
    }
    if let Some(rgb) = term.default_bg {
        w.write_bool(true);
        w.write_u8(rgb.0);
        w.write_u8(rgb.1);
        w.write_u8(rgb.2);
    } else {
        w.write_bool(false);
    }
    if let Some(rgb) = term.cursor_color {
        w.write_bool(true);
        w.write_u8(rgb.0);
        w.write_u8(rgb.1);
        w.write_u8(rgb.2);
    } else {
        w.write_bool(false);
    }

    // Kitty Keyboard
    let k_stack = term.kitty_keyboard.stack();
    w.write_u8(k_stack.len() as u8);
    for &f in k_stack {
        w.write_u8(f.bits());
    }

    // Graphics Placements
    w.write_u32(term.graphics_placements.len() as u32);
    for p in &term.graphics_placements {
        w.write_u32(p.image_id);
        w.write_u32(p.placement_id);
        w.write_u32(p.row as u32);
        w.write_u32(p.col as u32);
    }

    // Graphics Images, Counters, and Pending Transfers
    w.write_u32(term.graphics.next_image_id());
    w.write_u64(term.graphics.next_image_generation());
    let images = term.graphics.images();
    w.write_u32(images.len() as u32);
    let mut image_ids: Vec<u32> = images.keys().copied().collect();
    image_ids.sort_unstable();
    for &id in &image_ids {
        let img = &images[&id];
        w.write_u32(id);
        w.write_u8(match img.format {
            crate::graphics::ImageFormat::Rgb => 0,
            crate::graphics::ImageFormat::Rgba => 1,
            crate::graphics::ImageFormat::Png => 2,
        });
        w.write_u32(img.width);
        w.write_u32(img.height);
        w.write_u64(img.generation);
        w.write_bytes(&img.pixels);
    }

    let pending = term.graphics.pending();
    w.write_u32(pending.len() as u32);
    let mut pending_entries: Vec<(&crate::graphics::ChunkKey, &crate::graphics::PendingTransfer)> =
        pending.iter().collect();
    pending_entries.sort_by_key(|(k, _)| match k {
        crate::graphics::ChunkKey::Anonymous => (0, 0),
        crate::graphics::ChunkKey::Image(id) => (1, *id),
    });
    for (key, transfer) in pending_entries {
        match key {
            crate::graphics::ChunkKey::Anonymous => {
                w.write_u8(0);
            }
            crate::graphics::ChunkKey::Image(id) => {
                w.write_u8(1);
                w.write_u32(*id);
            }
        }
        w.write_u8(match transfer.format {
            crate::graphics::ImageFormat::Rgb => 0,
            crate::graphics::ImageFormat::Rgba => 1,
            crate::graphics::ImageFormat::Png => 2,
        });
        w.write_u32(transfer.width);
        w.write_u32(transfer.height);
        w.write_bytes(&transfer.data);
    }

    // Remaining State
    if let Some(ch) = term.last_printed_char {
        w.write_bool(true);
        w.write_u32(ch as u32);
    } else {
        w.write_bool(false);
    }
    w.write_u8(match term.protected_mode {
        ProtectedMode::Off => 0,
        ProtectedMode::Iso => 1,
        ProtectedMode::Dec => 2,
    });
    w.write_string(&term.answerback);
    w.write_string(&term.xtversion);
    w.write_u32(term.width_px);
    w.write_u32(term.height_px);
    w.write_u8(match term.dark_scheme {
        None => 0,
        Some(false) => 1,
        Some(true) => 2,
    });
    w.write_u8(match term.semantic_content {
        SemanticContent::None => 0,
        SemanticContent::Prompt => 1,
        SemanticContent::Input => 2,
        SemanticContent::Output => 3,
    });
    w.write_u16(term.checksum_ext);

    // No selection is written. v1 shipped it, which meant a restore silently
    // imposed the source's highlight on a destination whose rows it does not
    // describe -- and handed the decoder four unvalidated coordinates.

    if version >= 3 {
        write_host_config(&mut w, term);
        write_clusters(&mut w, &term.primary);
        write_clusters(&mut w, &term.alternate);
    }

    // Write Header
    if w.overflowed() {
        // Nothing partial escapes: the buffer is dropped here, and the caller
        // gets the true size it would have needed.
        return Err(CheckpointError::TooLarge {
            size: w.count as u64,
            limit,
        });
    }

    Ok(w)
}

fn shape_code(shape: CursorShape) -> u8 {
    match shape {
        CursorShape::Block => 0,
        CursorShape::Underline => 1,
        CursorShape::Bar => 2,
    }
}

fn shape_from_code(code: u8) -> CursorShape {
    match code {
        1 => CursorShape::Underline,
        2 => CursorShape::Bar,
        _ => CursorShape::Block,
    }
}

/// What the host configured, as opposed to what a program did: v3's tail.
fn write_host_config(w: &mut Writer, term: &Terminal) {
    let palette = &term.palette;
    for index in 0..=255u8 {
        let (r, g, b) = palette.base(index);
        w.write_u8(r);
        w.write_u8(g);
        w.write_u8(b);
    }
    for byte in 0..32u8 {
        let mut bits = 0u8;
        for bit in 0..8u8 {
            if palette.is_overridden(byte * 8 + bit) {
                bits |= 1 << bit;
            }
        }
        w.write_u8(bits);
    }
    for base in [palette.base_fg(), palette.base_bg(), palette.base_cursor()] {
        w.write_bool(base.is_some());
        if let Some((r, g, b)) = base {
            w.write_u8(r);
            w.write_u8(g);
            w.write_u8(b);
        }
    }
    w.write_bool(palette.fg_overridden());
    w.write_bool(palette.bg_overridden());
    w.write_bool(palette.cursor_overridden());
    w.write_u8(shape_code(term.default_cursor_style.shape));
    w.write_bool(term.default_cursor_style.blinking);
    w.write_bool(term.cursor_style_overridden);
}

/// A grid's grapheme clusters (v3): a count, then line, column, the text
/// after the cell's character and whether it is drawn wide. The cells carry
/// only their first character; this is the rest.
fn write_clusters(w: &mut Writer, grid: &Grid) {
    let clusters = grid.clusters();
    w.write_u32(clusters.len() as u32);
    for (line, col, extra, wide) in clusters {
        w.write_u32(line as u32);
        w.write_u32(col as u32);
        w.write_string(extra);
        w.write_bool(wide);
    }
}

/// [`write_clusters`]' block, applied to the grid it was written from. A
/// cluster naming a cell the grid does not have is corrupt data, not
/// something to skip.
fn read_clusters(r: &mut Reader<'_>, grid: &mut Grid) -> Result<(), CheckpointError> {
    let count = r.read_u32()? as usize;
    // line, column, a length prefix and the flag: 13 bytes at the least.
    r.check_count(count, 13)?;
    for _ in 0..count {
        let line = r.read_u32()? as usize;
        let col = r.read_u32()? as usize;
        let extra = r.read_string_budgeted()?;
        let wide = r.read_bool()?;
        if !grid.restore_cluster(line, col, &extra, wide) {
            return Err(CheckpointError::InvalidData("grapheme cluster names no cell"));
        }
    }
    Ok(())
}

/// [`write_host_config`]'s block, read back.
struct HostConfig {
    base: [(u8, u8, u8); 256],
    overridden: [bool; 256],
    base_fg: Option<(u8, u8, u8)>,
    base_bg: Option<(u8, u8, u8)>,
    base_cursor: Option<(u8, u8, u8)>,
    fg_overridden: bool,
    bg_overridden: bool,
    cursor_overridden: bool,
    default_cursor_style: CursorStyle,
    cursor_style_overridden: bool,
}

fn read_host_config(r: &mut Reader<'_>) -> Result<HostConfig, CheckpointError> {
    let mut base = [(0u8, 0u8, 0u8); 256];
    for rgb in &mut base {
        *rgb = (r.read_u8()?, r.read_u8()?, r.read_u8()?);
    }
    let mut overridden = [false; 256];
    for byte in 0..32 {
        let bits = r.read_u8()?;
        for bit in 0..8 {
            overridden[byte * 8 + bit] = bits & (1 << bit) != 0;
        }
    }
    let mut bases = [None; 3];
    for slot in &mut bases {
        if r.read_bool()? {
            *slot = Some((r.read_u8()?, r.read_u8()?, r.read_u8()?));
        }
    }
    let [base_fg, base_bg, base_cursor] = bases;
    Ok(HostConfig {
        base,
        overridden,
        base_fg,
        base_bg,
        base_cursor,
        fg_overridden: r.read_bool()?,
        bg_overridden: r.read_bool()?,
        cursor_overridden: r.read_bool()?,
        default_cursor_style: CursorStyle {
            shape: shape_from_code(r.read_u8()?),
            blinking: r.read_bool()?,
        },
        cursor_style_overridden: r.read_bool()?,
    })
}

/// One grid's slice of the container: capacity, eviction counter, scrollback,
/// then the live rows.
///
/// The grid is borrowed, not copied. Serializing through `Grid::raw_parts`
/// deep-cloned every cell and every scrollback row first, which doubled the
/// peak heap of an export and -- worse -- made a size query that keeps nothing
/// still pay for a full copy of the state it was only measuring.
fn write_grid(w: &mut Writer, grid: &crate::grid::Grid, rows: usize) {
    w.write_u32(grid.scrollback_capacity() as u32);
    w.write_u64(grid.history_evicted() as u64);
    w.write_u32(grid.scrollback_rows().len() as u32);
    for row in grid.scrollback_rows() {
        w.write_bool(row.wrapped);
        w.write_u32(row.cells.len() as u32);
        w.write_cells(&row.cells);
    }
    for r in 0..rows {
        w.write_bool(grid.is_line_wrapped(r));
        w.write_u8(match grid.row_semantic_prompt(r) {
            SemanticPrompt::Unset => 0,
            SemanticPrompt::Prompt => 1,
            SemanticPrompt::PromptContinuation => 2,
        });
        w.write_cells(grid.row_cells(r));
    }
}

/// Where a field the tests need to forge sits in the container, recorded as
/// the real decoder walks past it. Nothing in production reads this.
#[doc(hidden)]
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct FieldOffsets {
    /// Absolute offset of the tab-stop column count, from the start of `data`.
    pub tab_cols: usize,
    /// Heap bytes this import charged against [`MAX_IMPORT_ALLOC_BYTES`],
    /// containers and contents alike.
    ///
    /// This is the number [`import_cost`] predicts from the other side. They
    /// are equal for every checkpoint this build writes, and keeping them
    /// equal is what makes "a successful export is importable" a fact rather
    /// than a hope -- so the equality is asserted by tests, not by comment.
    pub allocated: u64,
}

/// Import a Terminal state from a versioned binary checkpoint.
///
/// If any check or read fails, returns `Err` without constructing a half-applied state.
pub fn import(data: &[u8]) -> Result<Terminal, CheckpointError> {
    import_reserving(data, 0)
}

/// [`import`] with part of the allocation budget already spoken for.
///
/// `reserved` is heap the import cannot use because it is still live while the
/// import runs. A restore *into a running terminal* is the case that needs it:
/// the destination is not freed until the replacement has been built, so the
/// two coexist, and a budget charged only for the replacement understates the
/// peak by exactly the size of the terminal being replaced.
///
/// The consequence is deliberate and worth stating plainly: a checkpoint that
/// imports fine into a fresh terminal can be refused when imported into a
/// large live one. That refusal is fail-intact like every other -- the
/// destination is untouched -- and it happens before the replacement is
/// allocated, which is the whole point of charging up front rather than
/// discovering the ceiling halfway through.
pub fn import_reserving(data: &[u8], reserved: u64) -> Result<Terminal, CheckpointError> {
    import_traced_reserving(data, reserved).map(|(term, _)| term)
}

/// [`import`], additionally reporting where selected fields were found.
#[doc(hidden)]
pub fn import_traced(data: &[u8]) -> Result<(Terminal, FieldOffsets), CheckpointError> {
    import_traced_reserving(data, 0)
}

/// [`import_traced`] with part of the allocation budget already spoken for.
#[doc(hidden)]
pub fn import_traced_reserving(
    data: &[u8],
    reserved: u64,
) -> Result<(Terminal, FieldOffsets), CheckpointError> {
    // Refuse before touching the container at all when the reservation alone
    // has already exhausted the budget, so the caller gets the same error
    // whether the payload is one byte or sixty megabytes.
    if reserved > MAX_IMPORT_ALLOC_BYTES {
        return Err(CheckpointError::AllocationLimitExceeded);
    }
    let (version, payload) = validate_container(data)?;
    let mut offsets = FieldOffsets::default();

    let mut r = Reader::with_reservation(payload, reserved);

    let cols = r.read_u32()? as usize;
    let rows = r.read_u32()? as usize;
    if cols == 0 || cols > MAX_DIM || rows == 0 || rows > MAX_DIM {
        return Err(CheckpointError::DimensionOutOfBounds { cols, rows });
    }

    let active_screen = match r.read_u8()? {
        0 => ScreenBuffer::Primary,
        1 => ScreenBuffer::Alternate,
        _ => return Err(CheckpointError::InvalidData("invalid active screen buffer")),
    };
    let scroll_top = r.read_u32()? as usize;
    let scroll_bottom = r.read_u32()? as usize;
    let scroll_left = r.read_u32()? as usize;
    let scroll_right = r.read_u32()? as usize;
    let viewport_offset = r.read_u32()? as usize;
    let pending_wrap = r.read_bool()?;

    // Primary Grid
    let prim_cap = r.read_u32()? as usize;
    if prim_cap > MAX_SCROLLBACK_LEN {
        return Err(CheckpointError::AllocationLimitExceeded);
    }
    let prim_evicted = r.read_u64()? as usize;
    let prim_sb_len = r.read_u32()? as usize;
    if prim_sb_len > MAX_SCROLLBACK_LEN {
        return Err(CheckpointError::AllocationLimitExceeded);
    }
    r.check_count(prim_sb_len, MIN_BYTES_PER_SCROLLBACK_ROW)?;
    r.charge_spine(prim_sb_len, SCROLLBACK_ROW_SPINE)?;
    let mut prim_sb = Vec::with_capacity(prim_sb_len);
    for _ in 0..prim_sb_len {
        let wrapped = r.read_bool()?;
        let cells_len = r.read_u32()? as usize;
        if cells_len > MAX_DIM {
            return Err(CheckpointError::AllocationLimitExceeded);
        }
        r.charge((cells_len as u64).saturating_mul(CELL_BYTES))?;
        let cells = r.read_cells(cells_len)?;
        prim_sb.push(ScrollbackRow { cells, wrapped });
    }
    // The whole visible grid, charged before a single row is decoded: run
    // length encoding means three payload bytes can declare ten thousand
    // cells, so the payload length is no bound on the heap at all.
    r.charge((rows as u64).saturating_mul(cols as u64).saturating_mul(CELL_BYTES))?;
    r.charge_spine(rows, GRID_ROW_SPINE)?;
    let mut prim_cells = Vec::with_capacity(rows);
    let mut prim_wrapped = Vec::with_capacity(rows);
    let mut prim_sem = Vec::with_capacity(rows);
    for _ in 0..rows {
        prim_wrapped.push(r.read_bool()?);
        prim_sem.push(match r.read_u8()? {
            0 => SemanticPrompt::Unset,
            1 => SemanticPrompt::Prompt,
            2 => SemanticPrompt::PromptContinuation,
            _ => return Err(CheckpointError::InvalidData("invalid semantic prompt")),
        });
        prim_cells.push(r.read_cells(cols)?);
    }
    let mut primary = Grid::from_raw_parts(
        cols,
        rows,
        prim_cap,
        prim_evicted,
        prim_cells,
        prim_wrapped,
        prim_sem,
        prim_sb,
    );

    // Alternate Grid
    let alt_cap = r.read_u32()? as usize;
    if alt_cap > MAX_SCROLLBACK_LEN {
        return Err(CheckpointError::AllocationLimitExceeded);
    }
    let alt_evicted = r.read_u64()? as usize;
    let alt_sb_len = r.read_u32()? as usize;
    if alt_sb_len > MAX_SCROLLBACK_LEN {
        return Err(CheckpointError::AllocationLimitExceeded);
    }
    r.check_count(alt_sb_len, MIN_BYTES_PER_SCROLLBACK_ROW)?;
    r.charge_spine(alt_sb_len, SCROLLBACK_ROW_SPINE)?;
    let mut alt_sb = Vec::with_capacity(alt_sb_len);
    for _ in 0..alt_sb_len {
        let wrapped = r.read_bool()?;
        let cells_len = r.read_u32()? as usize;
        if cells_len > MAX_DIM {
            return Err(CheckpointError::AllocationLimitExceeded);
        }
        r.charge((cells_len as u64).saturating_mul(CELL_BYTES))?;
        let cells = r.read_cells(cells_len)?;
        alt_sb.push(ScrollbackRow { cells, wrapped });
    }
    r.charge((rows as u64).saturating_mul(cols as u64).saturating_mul(CELL_BYTES))?;
    r.charge_spine(rows, GRID_ROW_SPINE)?;
    let mut alt_cells = Vec::with_capacity(rows);
    let mut alt_wrapped = Vec::with_capacity(rows);
    let mut alt_sem = Vec::with_capacity(rows);
    for _ in 0..rows {
        alt_wrapped.push(r.read_bool()?);
        alt_sem.push(match r.read_u8()? {
            0 => SemanticPrompt::Unset,
            1 => SemanticPrompt::Prompt,
            2 => SemanticPrompt::PromptContinuation,
            _ => return Err(CheckpointError::InvalidData("invalid semantic prompt")),
        });
        alt_cells.push(r.read_cells(cols)?);
    }
    let mut alternate = Grid::from_raw_parts(
        cols,
        rows,
        alt_cap,
        alt_evicted,
        alt_cells,
        alt_wrapped,
        alt_sem,
        alt_sb,
    );

    // Cursor
    let cursor_row = r.read_u32()? as usize;
    let cursor_col = r.read_u32()? as usize;
    let cursor_fg = r.read_color()?;
    let cursor_bg = r.read_color()?;
    let cursor_attrs = CellAttrs::from_bits_truncate(r.read_u16()?);
    let cursor_ul_style = r.read_u8()?;
    let cursor_ul_color = r.read_color()?;
    let cursor_visible = r.read_bool()?;
    let cursor_shape = shape_from_code(r.read_u8()?);
    let cursor_blinking = r.read_bool()?;

    let saved_cursor = if r.read_bool()? {
        let s_row = r.read_u32()? as usize;
        let s_col = r.read_u32()? as usize;
        let s_fg = r.read_color()?;
        let s_bg = r.read_color()?;
        let s_attrs = CellAttrs::from_bits_truncate(r.read_u16()?);
        let u8_to_cs = |b: u8| match b {
            1 => Charset::DecSpecialGraphics,
            2 => Charset::British,
            _ => Charset::Ascii,
        };
        let s_g0 = u8_to_cs(r.read_u8()?);
        let s_g1 = u8_to_cs(r.read_u8()?);
        let s_shift_out = r.read_bool()?;
        let s_origin_mode = r.read_bool()?;
        let s_pending_wrap = r.read_bool()?;
        let s_prot = match r.read_u8()? {
            1 => ProtectedMode::Iso,
            2 => ProtectedMode::Dec,
            _ => ProtectedMode::Off,
        };
        let s_gr_slot = r.read_u8()?;
        Some(SavedCursor {
            row: s_row,
            col: s_col,
            fg: s_fg,
            bg: s_bg,
            attrs: s_attrs,
            g0: s_g0,
            g1: s_g1,
            shift_out: s_shift_out,
            origin_mode: s_origin_mode,
            pending_wrap: s_pending_wrap,
            protected_mode: s_prot,
            gr_slot: s_gr_slot,
        })
    } else {
        None
    };

    let cursor = Cursor {
        row: cursor_row,
        col: cursor_col,
        fg: cursor_fg,
        bg: cursor_bg,
        attrs: cursor_attrs,
        underline_style: cursor_ul_style,
        underline_color: cursor_ul_color,
        saved: saved_cursor,
    };

    // Tab Stops
    //
    // Bounded before it reserves anything: `read_exact_bytes` only bounds the
    // *bitset* by the payload, and one bitset byte declares eight columns, so
    // an unchecked count turns a legal payload into a multi-hundred-megabyte
    // `vec![false; n]`. Export always writes `tab_cols == cols`, and `cols`
    // was bounded above, so this is the same check the geometry already got.
    offsets.tab_cols = HEADER_SIZE + r.pos;
    let tab_cols = r.read_u32()? as usize;
    if tab_cols == 0 || tab_cols > MAX_DIM || tab_cols != cols {
        return Err(CheckpointError::DimensionOutOfBounds {
            cols: tab_cols,
            rows,
        });
    }
    r.charge(tab_cols as u64)?;
    let num_bytes = tab_cols.div_ceil(8);
    let bitset = r.read_exact_bytes(num_bytes)?;
    let mut stops = vec![false; tab_cols];
    for (i, stop) in stops.iter_mut().enumerate() {
        if (bitset[i / 8] & (1 << (i % 8))) != 0 {
            *stop = true;
        }
    }
    let tabstops = TabStops::from_raw(tab_cols, stops);

    // Modes
    let mode_flags = r.read_u32()?;
    let mouse_tracking = match r.read_u8()? {
        1 => MouseTracking::Normal,
        2 => MouseTracking::ButtonEvent,
        3 => MouseTracking::AnyEvent,
        _ => MouseTracking::Off,
    };
    let modes = TerminalModes {
        autowrap: (mode_flags & (1 << 0)) != 0,
        origin_mode: (mode_flags & (1 << 1)) != 0,
        cursor_key_app_mode: (mode_flags & (1 << 2)) != 0,
        mouse_tracking,
        mouse_utf8: (mode_flags & (1 << 3)) != 0,
        mouse_sgr: (mode_flags & (1 << 4)) != 0,
        focus_events: (mode_flags & (1 << 5)) != 0,
        bracketed_paste: (mode_flags & (1 << 6)) != 0,
        insert: (mode_flags & (1 << 7)) != 0,
        linefeed_mode: (mode_flags & (1 << 8)) != 0,
        reverse_wrap: (mode_flags & (1 << 9)) != 0,
        reverse_wrap_extended: (mode_flags & (1 << 10)) != 0,
        left_right_margin_mode: (mode_flags & (1 << 11)) != 0,
        alternate_scroll: (mode_flags & (1 << 12)) != 0,
        synchronized_output: (mode_flags & (1 << 13)) != 0,
        shift_capture: ((mode_flags & (1 << 14)) != 0).then_some((mode_flags & (1 << 15)) != 0),
        // Not carried; the importing terminal applies its host's
        // grapheme-width-method.
        grapheme_cluster: true,
    };

    // Parser State
    let p_state = match r.read_u8()? {
        0 => State::Ground,
        1 => State::Escape,
        2 => State::EscapeIntermediate,
        3 => State::CsiEntry,
        4 => State::CsiParam,
        5 => State::CsiIntermediate,
        6 => State::CsiIgnore,
        7 => State::DcsEntry,
        8 => State::DcsParam,
        9 => State::DcsIntermediate,
        10 => State::DcsPassthrough,
        11 => State::DcsIgnore,
        12 => State::OscString,
        13 => State::SosPmApcString,
        _ => State::Ground,
    };
    let inter_len = r.read_u8()? as usize;
    if inter_len > 16 {
        return Err(CheckpointError::InvalidData("too many parser intermediates"));
    }
    let inter_bytes = r.read_exact_bytes(inter_len)?;
    let intermediates = smallvec::SmallVec::from_slice(inter_bytes);
    let params_len = r.read_u8()? as usize;
    if params_len > 64 {
        return Err(CheckpointError::InvalidData("too many parser params"));
    }
    let mut params = smallvec::SmallVec::new();
    for _ in 0..params_len {
        params.push(r.read_u16()?);
    }
    let params_sep = r.read_u32()?;
    let p_ignore = r.read_bool()?;
    // Bounded by what the payload actually holds and by the cumulative
    // budget, not by a per-field constant. The parser accumulates an OSC or
    // an unchunked APC transfer without a length limit of its own, so a
    // fixed reader-side ceiling below the wire cap made honest checkpoints --
    // one taken mid a large OSC 1337 inline image, or mid a Kitty APC
    // transfer sent in one piece -- export fine and then fail to import.
    let osc_raw = r.read_bytes_budgeted()?.to_vec();
    let apc_raw = r.read_bytes_budgeted()?.to_vec();
    let utf8_need = r.read_u8()?;
    let utf8_cp = r.read_u32()?;

    let mut parser = Parser::new();
    parser.restore(ParserSnapshot {
        state: p_state,
        intermediates,
        params,
        params_sep,
        ignore: p_ignore,
        osc_raw,
        apc_raw,
        utf8_need,
        utf8_cp,
    });

    // DCS
    let dcs = match r.read_u8()? {
        1 => Some(DcsKind::Decrqss),
        2 => Some(DcsKind::XtGetTcap),
        _ => None,
    };
    let dcs_buf = r.read_bytes_budgeted()?.to_vec();

    // Charsets & Shift
    let u8_to_cs = |b: u8| match b {
        1 => Charset::DecSpecialGraphics,
        2 => Charset::British,
        _ => Charset::Ascii,
    };
    let g0 = u8_to_cs(r.read_u8()?);
    let g1 = u8_to_cs(r.read_u8()?);
    let g2 = u8_to_cs(r.read_u8()?);
    let g3 = u8_to_cs(r.read_u8()?);
    let shift_out = r.read_bool()?;
    let gr_slot = r.read_u8()?;
    let single_shift = if r.read_bool()? {
        Some(u8_to_cs(r.read_u8()?))
    } else {
        None
    };

    // Hyperlinks
    let h_count = r.read_u32()? as usize;
    if h_count > 100_000 {
        return Err(CheckpointError::AllocationLimitExceeded);
    }
    r.check_count(h_count, MIN_BYTES_PER_LENGTH_PREFIXED)?;
    r.charge_spine(h_count, STRING_SPINE)?;
    let mut hyperlinks = Vec::with_capacity(h_count);
    for _ in 0..h_count {
        hyperlinks.push(r.read_string_budgeted()?);
    }
    let h_id_count = r.read_u32()? as usize;
    if h_id_count > 100_000 {
        return Err(CheckpointError::AllocationLimitExceeded);
    }
    r.check_count(h_id_count, MIN_BYTES_PER_HYPERLINK_ID)?;
    r.charge(map_spine(h_id_count as u64, HYPERLINK_ID_ENTRY))?;
    let mut hyperlink_ids = HashMap::with_capacity(h_id_count);
    for _ in 0..h_id_count {
        let k = r.read_string_budgeted()?;
        let v = r.read_u32()?;
        hyperlink_ids.insert(k, v);
    }
    let current_hyperlink = if r.read_bool()? {
        Some(r.read_u32()?)
    } else {
        None
    };

    // Title & Title Stack
    let title = r.read_string_budgeted()?;
    let ts_count = r.read_u32()? as usize;
    if ts_count > 100 {
        return Err(CheckpointError::AllocationLimitExceeded);
    }
    r.check_count(ts_count, MIN_BYTES_PER_LENGTH_PREFIXED)?;
    r.charge_spine(ts_count, STRING_SPINE)?;
    let mut title_items = Vec::with_capacity(ts_count);
    for _ in 0..ts_count {
        title_items.push(r.read_string_budgeted()?);
    }
    let title_stack = TitleStack::from_items(title_items);

    // Palette
    let mut pal_colors = [(0u8, 0u8, 0u8); 256];
    for col in &mut pal_colors {
        col.0 = r.read_u8()?;
        col.1 = r.read_u8()?;
        col.2 = r.read_u8()?;
    }
    let mut palette = Palette::from_colors(pal_colors);

    let default_fg = if r.read_bool()? {
        Some((r.read_u8()?, r.read_u8()?, r.read_u8()?))
    } else {
        None
    };
    let default_bg = if r.read_bool()? {
        Some((r.read_u8()?, r.read_u8()?, r.read_u8()?))
    } else {
        None
    };
    let cursor_color = if r.read_bool()? {
        Some((r.read_u8()?, r.read_u8()?, r.read_u8()?))
    } else {
        None
    };
    // A checkpoint doesn't carry the host's fg/bg/cursor base configuration
    // (Palette::from_colors leaves base_fg/base_bg/base_cursor as None), so
    // any restored Some value here can only have come from a program's
    // explicit OSC 10/11/12 override, never from a base. Mark it overridden
    // so a later `set_base_colors` doesn't clobber it, mirroring the
    // override inference `Palette::from_colors` already does for the
    // indexed palette above.
    palette.set_fg_overridden(default_fg.is_some());
    palette.set_bg_overridden(default_bg.is_some());
    palette.set_cursor_overridden(cursor_color.is_some());

    // Kitty Keyboard
    let kk_count = r.read_u8()? as usize;
    r.check_count(kk_count, 1)?;
    r.charge_spine(kk_count, KITTY_FLAGS_SPINE)?;
    let mut kk_stack = Vec::with_capacity(kk_count);
    for _ in 0..kk_count {
        kk_stack.push(KittyFlags::from_bits_truncate(r.read_u8()?));
    }
    let kitty_keyboard = KittyKeyboardState::from_stack(kk_stack);

    // Placements
    let p_count = r.read_u32()? as usize;
    if p_count > 10_000 {
        return Err(CheckpointError::AllocationLimitExceeded);
    }
    r.check_count(p_count, MIN_BYTES_PER_PLACEMENT)?;
    r.charge_spine(p_count, PLACEMENT_SPINE)?;
    let mut graphics_placements = Vec::with_capacity(p_count);
    for _ in 0..p_count {
        graphics_placements.push(GraphicsPlacement {
            image_id: r.read_u32()?,
            placement_id: r.read_u32()?,
            row: r.read_u32()? as usize,
            col: r.read_u32()? as usize,
        });
    }

    // Graphics Images, Counters, and Pending Transfers
    let next_image_id = r.read_u32()?;
    let next_image_generation = r.read_u64()?;
    let images_count = r.read_u32()? as usize;
    if images_count > 10_000 {
        return Err(CheckpointError::AllocationLimitExceeded);
    }
    r.check_count(images_count, MIN_BYTES_PER_IMAGE)?;
    r.charge(map_spine(images_count as u64, IMAGE_ENTRY))?;
    let mut images = HashMap::with_capacity(images_count);
    for _ in 0..images_count {
        let id = r.read_u32()?;
        let format = match r.read_u8()? {
            0 => crate::graphics::ImageFormat::Rgb,
            1 => crate::graphics::ImageFormat::Rgba,
            2 => crate::graphics::ImageFormat::Png,
            _ => return Err(CheckpointError::InvalidData("invalid image format")),
        };
        let width = r.read_u32()?;
        let height = r.read_u32()?;
        let generation = r.read_u64()?;
        let pixels = r.read_bytes_budgeted()?.to_vec();
        images.insert(
            id,
            crate::graphics::StoredImage {
                format,
                width,
                height,
                generation,
                pixels,
            },
        );
    }

    let pending_count = r.read_u32()? as usize;
    if pending_count > 10_000 {
        return Err(CheckpointError::AllocationLimitExceeded);
    }
    r.check_count(pending_count, MIN_BYTES_PER_PENDING)?;
    r.charge(map_spine(pending_count as u64, PENDING_ENTRY))?;
    let mut pending = HashMap::with_capacity(pending_count);
    for _ in 0..pending_count {
        let key = match r.read_u8()? {
            0 => crate::graphics::ChunkKey::Anonymous,
            1 => crate::graphics::ChunkKey::Image(r.read_u32()?),
            _ => return Err(CheckpointError::InvalidData("invalid chunk key")),
        };
        let format = match r.read_u8()? {
            0 => crate::graphics::ImageFormat::Rgb,
            1 => crate::graphics::ImageFormat::Rgba,
            2 => crate::graphics::ImageFormat::Png,
            _ => return Err(CheckpointError::InvalidData("invalid image format")),
        };
        let width = r.read_u32()?;
        let height = r.read_u32()?;
        let data = r.read_bytes_budgeted()?.to_vec();
        pending.insert(
            key,
            crate::graphics::PendingTransfer {
                format,
                width,
                height,
                data,
            },
        );
    }

    let placements = graphics_placements
        .iter()
        .map(|p| crate::graphics::Placement {
            image_id: p.image_id,
            placement_id: p.placement_id,
        })
        .collect();

    let graphics = crate::graphics::GraphicsState::restore(
        images,
        placements,
        pending,
        next_image_id,
        next_image_generation,
    );

    // Remaining State
    let last_printed_char = if r.read_bool()? {
        char::from_u32(r.read_u32()?)
    } else {
        None
    };
    let protected_mode = match r.read_u8()? {
        1 => ProtectedMode::Iso,
        2 => ProtectedMode::Dec,
        _ => ProtectedMode::Off,
    };
    let answerback = r.read_string_budgeted()?;
    let xtversion = r.read_string_budgeted()?;
    let width_px = r.read_u32()?;
    let height_px = r.read_u32()?;
    let dark_scheme = match r.read_u8()? {
        1 => Some(false),
        2 => Some(true),
        _ => None,
    };
    let semantic_content = match r.read_u8()? {
        1 => SemanticContent::Prompt,
        2 => SemanticContent::Input,
        3 => SemanticContent::Output,
        _ => SemanticContent::None,
    };
    let checksum_ext = r.read_u16()?;

    // v1 wrote the source's selection here. Read past it and drop it. The
    // destination's own selection is cleared only because this import
    // succeeded; a failed import returns before anything is applied and
    // leaves the destination -- selection included -- exactly as it was.
    if version == MIN_SUPPORTED_VERSION && r.read_bool()? {
        for _ in 0..4 {
            let _ = r.read_u32()?;
        }
        let _ = r.read_u8()?;
    }
    let selection = None;

    // A v3 container says which colours and which cursor style were the
    // host's; an older one leaves the inference above in place.
    let (default_cursor_style, cursor_style_overridden) = if version >= 3 {
        let host = read_host_config(&mut r)?;
        read_clusters(&mut r, &mut primary)?;
        read_clusters(&mut r, &mut alternate)?;
        palette.restore_bases(host.base, host.overridden);
        palette.set_base_fg(host.base_fg);
        palette.set_base_bg(host.base_bg);
        palette.set_base_cursor(host.base_cursor);
        palette.set_fg_overridden(host.fg_overridden);
        palette.set_bg_overridden(host.bg_overridden);
        palette.set_cursor_overridden(host.cursor_overridden);
        (host.default_cursor_style, host.cursor_style_overridden)
    } else {
        // A style other than the power-on one was a program's; the host sets
        // its default again.
        let restored = CursorStyle { shape: cursor_shape, blinking: cursor_blinking };
        (CursorStyle::new(), restored != CursorStyle::new())
    };

    let terminal = Terminal {
        primary,
        alternate,
        active: active_screen,
        cursor,
        scroll_top,
        scroll_bottom,
        scroll_left,
        scroll_right,
        title,
        cursor_visible,
        parser,
        hyperlinks,
        hyperlink_ids,
        current_hyperlink,
        selection,
        g0,
        g1,
        g2,
        g3,
        shift_out,
        gr_slot,
        single_shift,
        tabstops,
        kitty_keyboard,
        response: ResponseQueue::new(),
        checksum_ext,
        modes,
        graphics,
        graphics_placements,
        cursor_style: CursorStyle {
            shape: cursor_shape,
            blinking: cursor_blinking,
        },
        default_cursor_style,
        cursor_style_overridden,
        // Host configuration; `Terminal::import_checkpoint` keeps the
        // importing terminal's.
        grapheme_width_method: GraphemeWidthMethod::Unicode,
        palette,
        title_stack,
        last_printed_char,
        protected_mode,
        events: Vec::new(),
        answerback,
        xtversion,
        width_px,
        height_px,
        dark_scheme,
        semantic_content,
        viewport_offset,
        dcs,
        dcs_buf,
        default_fg,
        default_bg,
        cursor_color,
        pending_wrap,
    };
    offsets.allocated = r.alloc - reserved;
    Ok((terminal, offsets))
}
