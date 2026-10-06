/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

pub(crate) mod api;
pub(crate) mod budget;
pub(crate) mod commands;
pub(crate) mod crc;
pub(crate) mod decode;
pub(crate) mod decode_input;
pub(crate) mod decode_state;
pub(crate) mod encode;
pub(crate) mod encode_graphics;
pub(crate) mod grid;
pub(crate) mod host;
pub(crate) mod reader;
pub(crate) mod types;
pub(crate) mod writer;

#[cfg(test)]
mod tests;

pub use api::{
    export, export_limited, export_version, inspect, measure, measure_limited, measure_version,
    supports, validate, verify, version,
};
pub use budget::{import_cost, retained_cost};
pub use crc::crc32;
pub use decode::{import, import_reserving, import_traced, import_traced_reserving};
pub use types::{
    CELL_BYTES, COMMAND_RECORD_SPINE, CURRENT_VERSION, CheckpointError, CheckpointInfo,
    FieldOffsets, GRID_ROW_SPINE, HEADER_SIZE, KITTY_FLAGS_SPINE, MAGIC, MAX_CONTAINER_LEN,
    MAX_DIM, MAX_IMPORT_ALLOC_BYTES, MAX_PAYLOAD_LEN, MAX_SCROLLBACK_LEN, MIN_EXPORT_VERSION,
    MIN_SUPPORTED_VERSION, OWNER_RUN_SPINE, SCROLLBACK_ROW_SPINE, STRING_SPINE, map_spine,
};
