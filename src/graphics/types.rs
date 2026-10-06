/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use std::collections::HashMap;

/// Pixel format of a stored image.
///
/// Maps to the protocol's `f=` key: `f=24` -> RGB, `f=32` -> RGBA,
/// `f=100` -> PNG.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ImageFormat {
    /// 3 bytes per pixel, no alpha (`f=24`).
    Rgb,
    /// 4 bytes per pixel (`f=32`). The protocol default.
    Rgba,
    /// Raw PNG file bytes (`f=100`), stored undecoded.
    Png,
}

/// A parsed APC control-data block: the `key=value` pairs, verbatim.
///
/// Unknown keys are retained rather than rejected -- the protocol is
/// extensible and a future key must not break an otherwise valid command.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct GraphicsCommand {
    keys: HashMap<char, String>,
}

impl GraphicsCommand {
    /// Raw string value for `key`, if present.
    pub fn get(&self, key: char) -> Option<&str> {
        self.keys.get(&key).map(|s| s.as_str())
    }

    /// Value for `key` parsed as a `u32`. `None` if absent or not a number.
    pub fn get_u32(&self, key: char) -> Option<u32> {
        self.get(key).and_then(|v| v.parse().ok())
    }

    /// Single-character value for `key` (used by `a=`, `t=`, `d=`).
    pub fn get_char(&self, key: char) -> Option<char> {
        let v = self.get(key)?;
        let mut chars = v.chars();
        let first = chars.next()?;
        if chars.next().is_some() {
            None
        } else {
            Some(first)
        }
    }

    /// Number of key/value pairs parsed.
    pub fn len(&self) -> usize {
        self.keys.len()
    }

    /// Whether the control data contained no key/value pairs.
    pub fn is_empty(&self) -> bool {
        self.keys.is_empty()
    }
}

/// Parse a comma-separated `key=value` control-data string.
///
/// Malformed fragments (no `=`, an empty or multi-character key) are skipped;
/// this never fails, because a single unusable pair must not discard the rest
/// of an otherwise well-formed command. Unknown keys are kept as-is.
pub fn parse_control_data(s: &str) -> GraphicsCommand {
    let mut keys = HashMap::new();

    for pair in s.split(',') {
        let pair = pair.trim();
        if pair.is_empty() {
            continue;
        }
        let Some((raw_key, value)) = pair.split_once('=') else {
            continue;
        };
        let mut key_chars = raw_key.trim().chars();
        let Some(key) = key_chars.next() else {
            continue;
        };
        if key_chars.next().is_some() {
            // Keys in this protocol are single characters; anything longer is
            // not something we can address, so drop it.
            continue;
        }
        keys.insert(key, value.trim().to_string());
    }

    GraphicsCommand { keys }
}

/// An image held in the graphics store.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StoredImage {
    pub format: ImageFormat,
    pub width: u32,
    pub height: u32,
    /// Monotonic generation for this image ID, incremented on every
    /// successful replace/transmit completion.
    pub generation: u64,
    /// Decoded payload: raw pixels for [`ImageFormat::Rgb`]/[`ImageFormat::Rgba`],
    /// or the PNG file bytes verbatim for [`ImageFormat::Png`].
    pub pixels: Vec<u8>,
}

/// A record that an image is displayed somewhere.
///
/// Screen position is intentionally absent: placement geometry belongs to the
/// terminal grid, which wires into this module later.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Placement {
    pub image_id: u32,
    pub placement_id: u32,
}

/// Outcome of handling one graphics command.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GraphicsResponse {
    /// Image fully received and stored (`a=t`).
    Stored { image_id: u32 },
    /// Image stored (if transmitted) and placed (`a=T` / `a=p`).
    Displayed { image_id: u32, placement_id: u32 },
    /// Images removed (`a=d`). Empty when nothing matched.
    Deleted { image_ids: Vec<u32> },
    /// Query reply to send back to client (`a=q`).
    Query { reply: String },
    /// A well-formed command this implementation does not support.
    Unsupported,
    /// A malformed or unsatisfiable command.
    Error(String),
}

impl GraphicsResponse {
    /// Returns the reply string for responses that require communication back to the host.
    pub fn reply(&self) -> Option<&str> {
        match self {
            Self::Query { reply } => Some(reply.as_str()),
            _ => None,
        }
    }
}

/// Key for an in-progress chunked transmission.
///
/// A chunked transmission that never sent `i=`/`I=` still has to accumulate
/// somewhere, so anonymous transmissions share one synthetic slot -- the
/// protocol only allows one such transmission to be in flight at a time.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(crate) enum ChunkKey {
    Image(u32),
    Anonymous,
}

/// A partially-received image: the chunk buffer plus the metadata from the
/// first chunk, which is the only chunk required to carry it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct PendingTransfer {
    pub format: ImageFormat,
    pub width: u32,
    pub height: u32,
    pub generation: u64,
    pub data: Vec<u8>,
}
