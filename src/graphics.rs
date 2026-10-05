/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

//! Kitty Graphics Protocol support.
//!
//! Upstream speaks the Kitty Graphics Protocol
//! (<https://sw.kovidgoyal.net/kitty/graphics-protocol/>) over APC escape
//! sequences of the form:
//!
//! ```text
//! ESC _ G <control-data> ; <payload> ESC \
//! ```
//!
//! where `<control-data>` is a comma-separated list of `key=value` pairs and
//! `<payload>` is (for the direct transmission medium) base64-encoded image
//! data.
//!
//! This module is deliberately grid-agnostic: it only owns the image store,
//! the placement records, and the chunk-assembly buffers. Escape-sequence
//! framing lives in the parser, which hands us the already-split control data
//! and payload bytes.
//!
//! Coverage is the core transmit/display/delete flow. Animation frames
//! (`a=f`/`a=a`), shared-memory (`t=s`) and file-based (`t=f`/`t=t`)
//! transmission are not implemented; they are reported as
//! [`GraphicsResponse::Unsupported`] rather than treated as an error.

use std::collections::HashMap;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;

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
        if chars.next().is_some() { None } else { Some(first) }
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

/// Default maximum memory capacity allocated for stored images per terminal pane (64 MiB).
pub const DEFAULT_MAX_IMAGE_MEMORY_BYTES: u64 = 64 * 1024 * 1024;
/// Default maximum memory capacity allocated for decoded image pixel/texture buffer per terminal pane (64 MiB).
pub const DEFAULT_MAX_DECODED_IMAGE_BYTES: u64 = DEFAULT_MAX_IMAGE_MEMORY_BYTES;

/// Image store, placement list, and chunk-assembly state for one terminal.
#[derive(Debug)]
pub struct GraphicsState {
    images: HashMap<u32, StoredImage>,
    placements: Vec<Placement>,
    pending: HashMap<ChunkKey, PendingTransfer>,
    next_image_id: u32,
    next_image_generation: u64,
    next_pending_generation: u64,
    max_memory_bytes: u64,
    last_reply: Option<String>,
}

impl GraphicsState {
    /// Heap this store holds, by capacity: the two maps' tables, the placement
    /// spine, and every image's and in-flight transfer's own buffer.
    ///
    /// Image pixels and chunked transfers are the largest single thing a
    /// terminal can be holding, and `Vec::clear` on a finished transfer keeps
    /// its allocation, so length is not what is resident here.
    pub fn retained_capacity_bytes(&self) -> u64 {
        let mut total: u64 = 0;
        total = total.saturating_add(
            (self.images.capacity() as u64)
                .saturating_mul(std::mem::size_of::<(u32, StoredImage)>() as u64),
        );
        for img in self.images.values() {
            let decoded = (img.width as u64)
                .saturating_mul(img.height as u64)
                .saturating_mul(4);
            total = total.saturating_add((img.pixels.capacity() as u64).max(decoded));
        }
        total = total.saturating_add(
            (self.placements.capacity() as u64)
                .saturating_mul(std::mem::size_of::<Placement>() as u64),
        );
        total = total.saturating_add(
            (self.pending.capacity() as u64)
                .saturating_mul(std::mem::size_of::<(ChunkKey, PendingTransfer)>() as u64),
        );
        for transfer in self.pending.values() {
            let decoded = (transfer.width as u64)
                .saturating_mul(transfer.height as u64)
                .saturating_mul(4);
            total = total.saturating_add((transfer.data.capacity() as u64).max(decoded));
        }
        total
    }

    pub fn new() -> Self {
        Self {
            images: HashMap::new(),
            placements: Vec::new(),
            pending: HashMap::new(),
            next_image_id: 1,
            next_image_generation: 1,
            next_pending_generation: 1,
            max_memory_bytes: DEFAULT_MAX_IMAGE_MEMORY_BYTES,
            last_reply: None,
        }
    }

    /// Takes the pending PTY response message for the last handled command, if any.
    pub fn take_last_reply(&mut self) -> Option<String> {
        self.last_reply.take()
    }

    /// Current configured memory cap for this pane.
    pub fn max_memory_bytes(&self) -> u64 {
        self.max_memory_bytes
    }

    /// Sets the maximum memory capacity (in bytes) and prunes any excess stored images.
    pub fn set_max_memory_bytes(&mut self, max: u64) {
        self.max_memory_bytes = max;
        self.enforce_memory_cap(0);
    }

    /// Enforces the memory cap by evicting oldest completed images, and then
    /// oldest pending transfers if completed images alone are not enough.
    /// Returns false if `incoming_bytes` alone exceeds the configured maximum memory cap,
    /// or if retained memory cannot be brought under the cap.
    pub fn enforce_memory_cap(&mut self, incoming_bytes: u64) -> bool {
        if incoming_bytes > self.max_memory_bytes {
            return false;
        }
        while self.retained_capacity_bytes().saturating_add(incoming_bytes) > self.max_memory_bytes {
            if !self.images.is_empty() {
                if let Some(&oldest_id) = self.images.iter().min_by_key(|(_, img)| img.generation).map(|(id, _)| id) {
                    self.images.remove(&oldest_id);
                    self.placements.retain(|p| p.image_id != oldest_id);
                    self.pending.remove(&ChunkKey::Image(oldest_id));
                } else {
                    break;
                }
            } else if !self.pending.is_empty() {
                if let Some(&oldest_key) = self.pending.iter().min_by_key(|(_, transfer)| transfer.generation).map(|(k, _)| k) {
                    self.pending.remove(&oldest_key);
                } else {
                    break;
                }
            } else {
                break;
            }
        }
        self.retained_capacity_bytes().saturating_add(incoming_bytes) <= self.max_memory_bytes
    }

    /// Stores a raw image (e.g. from an iTerm2 OSC 1337 File sequence) and records a placement for it.
    pub fn store_and_place_raw_image(
        &mut self,
        format: ImageFormat,
        width: u32,
        height: u32,
        pixels: Vec<u8>,
    ) -> Result<(u32, u32), String> {
        let (width, height) = if width == 0 || height == 0 {
            detect_image_dimensions(&pixels).unwrap_or((width, height))
        } else {
            (width, height)
        };
        let decoded_bytes = (width as u64)
            .saturating_mul(height as u64)
            .saturating_mul(4);
        if width > 0 && height > 0 && decoded_bytes > self.max_memory_bytes {
            return Err("image decoded size exceeds per-pane memory cap".into());
        }
        let size = (pixels.len() as u64).max(decoded_bytes);
        if !self.enforce_memory_cap(size) {
            return Err("image exceeds per-pane memory cap".into());
        }
        let image_id = self.allocate_image_id();
        let generation = self.allocate_image_generation();
        let placement_id = 1;
        self.images.insert(
            image_id,
            StoredImage {
                format,
                width,
                height,
                generation,
                pixels,
            },
        );
        self.placements.push(Placement {
            image_id,
            placement_id,
        });
        Ok((image_id, placement_id))
    }

    /// Access all stored images (for checkpoint export).
    pub(crate) fn images(&self) -> &HashMap<u32, StoredImage> {
        &self.images
    }

    /// Access pending chunked transfers (for checkpoint export).
    pub(crate) fn pending(&self) -> &HashMap<ChunkKey, PendingTransfer> {
        &self.pending
    }

    /// Current next image ID counter.
    pub(crate) fn next_image_id(&self) -> u32 {
        self.next_image_id
    }

    /// Current next image generation counter.
    pub(crate) fn next_image_generation(&self) -> u64 {
        self.next_image_generation
    }

    /// Restore full graphics state from checkpoint data.
    pub(crate) fn restore(
        images: HashMap<u32, StoredImage>,
        placements: Vec<Placement>,
        pending: HashMap<ChunkKey, PendingTransfer>,
        next_image_id: u32,
        next_image_generation: u64,
    ) -> Self {
        let mut state = Self {
            images,
            placements,
            pending,
            next_image_id: next_image_id.max(1),
            next_image_generation: next_image_generation.max(1),
            next_pending_generation: 1,
            max_memory_bytes: DEFAULT_MAX_IMAGE_MEMORY_BYTES,
            last_reply: None,
        };
        state.enforce_memory_cap(0);
        state
    }

    /// Handle one APC graphics command.
    ///
    /// `control_data` is the text between `ESC _ G` and `;`, `payload` the
    /// bytes between `;` and `ESC \`.
    pub fn handle(&mut self, control_data: &str, payload: &[u8]) -> GraphicsResponse {
        self.last_reply = None;
        let cmd = parse_control_data(control_data);

        let action = match (cmd.get('a'), cmd.get_char('a')) {
            (Some(_), None) => return GraphicsResponse::Error("invalid action key 'a'".to_string()),
            (Some(_), Some(ch)) => ch,
            (None, _) => 't', // Kitty protocol default action is 't' (transmit)
        };

        let resp = match action {
            't' => self.transmit(&cmd, payload, false),
            'T' => self.transmit(&cmd, payload, true),
            'p' => self.display_stored(&cmd),
            'd' => self.delete(&cmd),
            'q' => self.query(&cmd, payload),
            other => GraphicsResponse::Error(format!("unsupported action a={other}")),
        };

        if cmd.get_u32('q') == Some(2) {
            match &resp {
                GraphicsResponse::Displayed { image_id, placement_id } => {
                    self.last_reply = Some(format!("\x1b_Gi={image_id},p={placement_id};OK\x1b\\"));
                }
                GraphicsResponse::Stored { image_id } => {
                    self.last_reply = Some(format!("\x1b_Gi={image_id};OK\x1b\\"));
                }
                GraphicsResponse::Deleted { .. } => {
                    self.last_reply = Some("\x1b_G;OK\x1b\\".to_string());
                }
                GraphicsResponse::Error(msg) => {
                    self.last_reply = Some(format!("\x1b_G;{msg}\x1b\\"));
                }
                _ => {}
            }
        } else if let GraphicsResponse::Error(ref msg) = resp {
            if cmd.get_u32('q') != Some(1) && action == 'q' {
                self.last_reply = Some(format!("\x1b_G;{msg}\x1b\\"));
            }
        }

        resp
    }

    /// The stored image with `id`, if any.
    pub fn image(&self, id: u32) -> Option<&StoredImage> {
        self.images.get(&id)
    }

    /// All current placements, in the order they were created.
    pub fn placements(&self) -> &[Placement] {
        &self.placements
    }

    /// `a=t` / `a=T`: receive (possibly one chunk of) an image.
    fn transmit(
        &mut self,
        cmd: &GraphicsCommand,
        payload: &[u8],
        display: bool,
    ) -> GraphicsResponse {
        // Only the direct medium carries data in the payload. Anything else
        // (file, temp file, shared memory) is out of scope -- bail out before
        // touching the payload at all.
        if cmd.get_char('t') != Some('d') {
            return GraphicsResponse::Unsupported;
        }

        let format = match cmd.get('f') {
            None | Some("32") => ImageFormat::Rgba,
            Some("24") => ImageFormat::Rgb,
            Some("100") => ImageFormat::Png,
            Some(other) => return GraphicsResponse::Error(format!("unsupported format f={other}")),
        };

        let explicit_id = cmd.get_u32('i').or_else(|| cmd.get_u32('I'));
        let key = match explicit_id {
            Some(id) => ChunkKey::Image(id),
            None => ChunkKey::Anonymous,
        };

        let chunk = match BASE64.decode(payload) {
            Ok(bytes) => bytes,
            Err(err) => {
                // A bad chunk poisons the whole transmission; drop what we had
                // so the next command starts clean.
                self.pending.remove(&key);
                return GraphicsResponse::Error(format!("invalid base64 payload: {err}"));
            }
        };

        let declared_w = cmd.get_u32('s').unwrap_or(0);
        let declared_h = cmd.get_u32('v').unwrap_or(0);
        if declared_w > 0 && declared_h > 0 {
            let decoded = (declared_w as u64)
                .saturating_mul(declared_h as u64)
                .saturating_mul(4);
            if decoded > self.max_memory_bytes {
                self.pending.remove(&key);
                return GraphicsResponse::Error("image decoded size exceeds per-pane memory cap".to_string());
            }
        }
        if format == ImageFormat::Png {
            if let Some((w, h)) = png_dimensions(&chunk) {
                let decoded = (w as u64).saturating_mul(h as u64).saturating_mul(4);
                if decoded > self.max_memory_bytes {
                    self.pending.remove(&key);
                    return GraphicsResponse::Error("image decoded size exceeds per-pane memory cap".to_string());
                }
            }
        }

        let more = cmd.get('m').is_some_and(|m| m != "0");

        let additional_bytes = if let Some(existing) = self.pending.get(&key) {
            let needed = existing.data.len().saturating_add(chunk.len());
            if needed as u64 > self.max_memory_bytes {
                self.pending.remove(&key);
                return GraphicsResponse::Error("image transfer exceeds per-pane memory cap".to_string());
            }
            needed.saturating_sub(existing.data.capacity()) as u64
        } else {
            if chunk.len() as u64 > self.max_memory_bytes {
                return GraphicsResponse::Error("image transfer exceeds per-pane memory cap".to_string());
            }
            chunk.len() as u64
        };

        if !self.enforce_memory_cap(additional_bytes) {
            self.pending.remove(&key);
            return GraphicsResponse::Error("image transfer exceeds per-pane memory cap".to_string());
        }

        let generation = self.allocate_pending_generation();
        // The first chunk carries the metadata; continuations only carry data.
        let entry = self.pending.entry(key).or_insert_with(|| PendingTransfer {
            format,
            width: cmd.get_u32('s').unwrap_or(0),
            height: cmd.get_u32('v').unwrap_or(0),
            generation,
            data: Vec::new(),
        });
        entry.generation = generation;
        if entry.data.capacity() < entry.data.len() + chunk.len() {
            entry.data.reserve_exact(chunk.len());
        }
        entry.data.extend_from_slice(&chunk);

        if more {
            // Still mid-transmission: acknowledge without storing or placing.
            return GraphicsResponse::Stored {
                image_id: explicit_id.unwrap_or(0),
            };
        }

        let mut transfer = self
            .pending
            .remove(&key)
            .expect("pending entry inserted immediately above");
        // A PNG carries its own size, and senders leave `s`/`v` out for it
        // (kitty's `icat` does). Without this the image was stored as 0x0 and
        // never drawn.
        if transfer.format == ImageFormat::Png
            && let Some((width, height)) = png_dimensions(&transfer.data)
        {
            transfer.width = width;
            transfer.height = height;
        }

        let decoded_bytes = (transfer.width as u64)
            .saturating_mul(transfer.height as u64)
            .saturating_mul(4);
        if transfer.width > 0 && transfer.height > 0 && decoded_bytes > self.max_memory_bytes {
            return GraphicsResponse::Error("image decoded size exceeds per-pane memory cap".to_string());
        }

        let image_id = match explicit_id {
            Some(id) => id,
            None => self.allocate_image_id(),
        };

        let needed_bytes = (transfer.data.capacity() as u64).max(decoded_bytes);
        if !self.enforce_memory_cap(needed_bytes) {
            return GraphicsResponse::Error("image exceeds per-pane memory cap".to_string());
        }

        // Allocate from store-wide state rather than deriving this from the
        // current entry. A renderer may retain a texture after an image is
        // deleted, so delete + retransmit under the same explicit ID must not
        // reuse the old content generation.
        let generation = self.allocate_image_generation();

        self.images.insert(
            image_id,
            StoredImage {
                format: transfer.format,
                width: transfer.width,
                height: transfer.height,
                generation,
                pixels: transfer.data,
            },
        );

        if display {
            let placement_id = cmd.get_u32('p').unwrap_or(0);
            self.placements.push(Placement {
                image_id,
                placement_id,
            });
            GraphicsResponse::Displayed {
                image_id,
                placement_id,
            }
        } else {
            GraphicsResponse::Stored { image_id }
        }
    }

    /// `a=p`: place an image that was transmitted earlier.
    fn display_stored(&mut self, cmd: &GraphicsCommand) -> GraphicsResponse {
        let Some(image_id) = cmd.get_u32('i').or_else(|| cmd.get_u32('I')) else {
            return GraphicsResponse::Error("a=p requires an image id".to_string());
        };

        if !self.images.contains_key(&image_id) {
            return GraphicsResponse::Error(format!("unknown image id {image_id}"));
        }

        let placement_id = cmd.get_u32('p').unwrap_or(0);
        self.placements.push(Placement {
            image_id,
            placement_id,
        });
        GraphicsResponse::Displayed {
            image_id,
            placement_id,
        }
    }

    /// `a=d`: delete images and their placements.
    fn delete(&mut self, cmd: &GraphicsCommand) -> GraphicsResponse {
        match cmd.get_char('d') {
            // Lowercase deletes placements, uppercase also frees the image
            // data. We store no data separately from the image, so both clear
            // the same state.
            Some('a') | Some('A') => {
                let mut image_ids: Vec<u32> = self.images.keys().copied().collect();
                image_ids.sort_unstable();
                self.images.clear();
                self.placements.clear();
                self.pending.clear();
                GraphicsResponse::Deleted { image_ids }
            }
            Some('i') | Some('I') => {
                let Some(image_id) = cmd.get_u32('i').or_else(|| cmd.get_u32('I')) else {
                    return GraphicsResponse::Error("d=i requires an image id".to_string());
                };
                let mut image_ids = Vec::new();
                if self.images.remove(&image_id).is_some() {
                    image_ids.push(image_id);
                }
                self.placements.retain(|p| p.image_id != image_id);
                self.pending.remove(&ChunkKey::Image(image_id));
                GraphicsResponse::Deleted { image_ids }
            }
            _ => GraphicsResponse::Unsupported,
        }
    }

    /// `a=q`: query graphics protocol support.
    fn query(&mut self, cmd: &GraphicsCommand, _payload: &[u8]) -> GraphicsResponse {
        let medium = cmd.get_char('t').unwrap_or('d');
        if medium != 'd' {
            let mut keys = Vec::new();
            if let Some(i) = cmd.get_u32('i') {
                keys.push(format!("i={i}"));
            } else if let Some(big_i) = cmd.get_u32('I') {
                keys.push(format!("I={big_i}"));
            }
            let key_str = if keys.is_empty() { String::new() } else { format!("{};", keys.join(",")) };
            let reply = format!("\x1b_G{}ENOTSUP\x1b\\", key_str);
            self.last_reply = Some(reply.clone());
            return GraphicsResponse::Query { reply };
        }

        let mut keys = Vec::new();
        if let Some(i) = cmd.get_u32('i') {
            keys.push(format!("i={i}"));
        } else if let Some(big_i) = cmd.get_u32('I') {
            keys.push(format!("I={big_i}"));
        }
        if let Some(p) = cmd.get_u32('p') {
            keys.push(format!("p={p}"));
        }
        if let Some(s) = cmd.get_u32('s') {
            keys.push(format!("s={s}"));
        }
        if let Some(v) = cmd.get_u32('v') {
            keys.push(format!("v={v}"));
        }

        let key_str = if keys.is_empty() {
            String::new()
        } else {
            format!("{};", keys.join(","))
        };

        let reply = format!("\x1b_G{}OK\x1b\\", key_str);
        self.last_reply = Some(reply.clone());
        GraphicsResponse::Query { reply }
    }

    /// Next id not already taken by a stored image.
    fn allocate_image_id(&mut self) -> u32 {
        while self.images.contains_key(&self.next_image_id) {
            self.next_image_id = self.next_image_id.wrapping_add(1).max(1);
        }
        let id = self.next_image_id;
        self.next_image_id = self.next_image_id.wrapping_add(1).max(1);
        id
    }

    fn allocate_image_generation(&mut self) -> u64 {
        let generation = self.next_image_generation.max(1);
        self.next_image_generation = generation.wrapping_add(1).max(1);
        generation
    }

    fn allocate_pending_generation(&mut self) -> u64 {
        let generation = self.next_pending_generation.max(1);
        self.next_pending_generation = generation.wrapping_add(1).max(1);
        generation
    }
}

impl Default for GraphicsState {
    fn default() -> Self {
        Self::new()
    }
}

/// The largest image side taken from its own header: Metal's texture limit on
/// Apple GPUs. A few hundred bytes of PNG/JPEG/GIF can claim any size, and
/// downstream allocation must stay bounded.
pub const MAX_PNG_SIDE: u32 = 16_384;
pub const MAX_IMAGE_SIDE: u32 = MAX_PNG_SIDE;

/// Width and height from a PNG's IHDR chunk, which the format puts first:
/// the 8-byte signature, the chunk length, "IHDR", then width and height as
/// big-endian u32s. None for anything that is not a PNG of a drawable size.
pub fn png_dimensions(data: &[u8]) -> Option<(u32, u32)> {
    if data.len() < 24 || &data[..8] != b"\x89PNG\r\n\x1a\n" || &data[12..16] != b"IHDR" {
        return None;
    }
    let width = u32::from_be_bytes(data[16..20].try_into().ok()?);
    let height = u32::from_be_bytes(data[20..24].try_into().ok()?);
    let drawable = |side: u32| (1..=MAX_IMAGE_SIDE).contains(&side);
    (drawable(width) && drawable(height)).then_some((width, height))
}

/// Width and height from a GIF header (GIF87a / GIF89a).
/// Bytes 6..8 width (little-endian u16), bytes 8..10 height (little-endian u16).
pub fn gif_dimensions(data: &[u8]) -> Option<(u32, u32)> {
    if data.len() < 10 {
        return None;
    }
    if &data[..6] != b"GIF87a" && &data[..6] != b"GIF89a" {
        return None;
    }
    let width = u16::from_le_bytes(data[6..8].try_into().ok()?) as u32;
    let height = u16::from_le_bytes(data[8..10].try_into().ok()?) as u32;
    let drawable = |side: u32| (1..=MAX_IMAGE_SIDE).contains(&side);
    (drawable(width) && drawable(height)).then_some((width, height))
}

/// Width and height parsed from a JPEG Start Of Frame (SOF) marker.
pub fn jpeg_dimensions(data: &[u8]) -> Option<(u32, u32)> {
    if data.len() < 4 || data[0] != 0xFF || data[1] != 0xD8 {
        return None;
    }
    let mut i = 2;
    while i + 1 < data.len() {
        if data[i] != 0xFF {
            i += 1;
            continue;
        }
        while i < data.len() && data[i] == 0xFF {
            i += 1;
        }
        if i >= data.len() {
            break;
        }
        let marker = data[i];
        i += 1;
        if marker == 0xD8 || marker == 0xD9 || (0xD0..=0xD7).contains(&marker) || marker == 0x01 {
            continue;
        }
        if i + 2 > data.len() {
            break;
        }
        let len = u16::from_be_bytes(data[i..i + 2].try_into().ok()?) as usize;
        if len < 2 || i + len > data.len() {
            break;
        }
        if matches!(marker, 0xC0..=0xC3 | 0xC5..=0xC7 | 0xC9..=0xCB | 0xCD..=0xCF) {
            if len >= 7 && i + 7 <= data.len() {
                let height = u16::from_be_bytes(data[i + 3..i + 5].try_into().ok()?) as u32;
                let width = u16::from_be_bytes(data[i + 5..i + 7].try_into().ok()?) as u32;
                let drawable = |side: u32| (1..=MAX_IMAGE_SIDE).contains(&side);
                if drawable(width) && drawable(height) {
                    return Some((width, height));
                }
            }
            break;
        }
        i += len;
    }
    None
}

/// Width and height parsed from a WebP container.
pub fn webp_dimensions(data: &[u8]) -> Option<(u32, u32)> {
    if data.len() < 16 || &data[..4] != b"RIFF" || &data[8..12] != b"WEBP" {
        return None;
    }
    let chunk_type = &data[12..16];
    let drawable = |side: u32| (1..=MAX_IMAGE_SIDE).contains(&side);
    if chunk_type == b"VP8 " && data.len() >= 30 {
        if &data[23..26] == b"\x9d\x01\x2a" {
            let width = (u16::from_le_bytes(data[26..28].try_into().ok()?) & 0x3fff) as u32;
            let height = (u16::from_le_bytes(data[28..30].try_into().ok()?) & 0x3fff) as u32;
            if drawable(width) && drawable(height) {
                return Some((width, height));
            }
        }
    } else if chunk_type == b"VP8L" && data.len() >= 25 {
        if data[20] == 0x2f {
            let b1 = data[21] as u32;
            let b2 = data[22] as u32;
            let b3 = data[23] as u32;
            let b4 = data[24] as u32;
            let width = 1 + (b1 | ((b2 & 0x3f) << 8));
            let height = 1 + (((b2 >> 6) | (b3 << 2) | ((b4 & 0x0f) << 10)));
            if drawable(width) && drawable(height) {
                return Some((width, height));
            }
        }
    } else if chunk_type == b"VP8X" && data.len() >= 30 {
        let width = 1 + (data[24] as u32 | ((data[25] as u32) << 8) | ((data[26] as u32) << 16));
        let height = 1 + (data[27] as u32 | ((data[28] as u32) << 8) | ((data[29] as u32) << 16));
        if drawable(width) && drawable(height) {
            return Some((width, height));
        }
    }
    None
}

/// Detect image dimensions from supported image formats (PNG, GIF, JPEG, WebP).
pub fn detect_image_dimensions(data: &[u8]) -> Option<(u32, u32)> {
    png_dimensions(data)
        .or_else(|| gif_dimensions(data))
        .or_else(|| jpeg_dimensions(data))
        .or_else(|| webp_dimensions(data))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn b64(bytes: &[u8]) -> String {
        BASE64.encode(bytes)
    }

    #[test]
    fn parses_key_value_pairs_and_keeps_unknown_keys() {
        let cmd = parse_control_data("a=T,f=32,s=1,v=1,i=7,z=99,X=hello");
        assert_eq!(cmd.get_char('a'), Some('T'));
        assert_eq!(cmd.get_u32('s'), Some(1));
        assert_eq!(cmd.get_u32('i'), Some(7));
        assert_eq!(cmd.get('z'), Some("99"));
        assert_eq!(cmd.get('X'), Some("hello"));
        assert_eq!(cmd.get('q'), None);
        assert_eq!(cmd.len(), 7);
    }

    #[test]
    fn parses_empty_and_malformed_fragments_without_panicking() {
        let cmd = parse_control_data("");
        assert!(cmd.is_empty());

        let cmd = parse_control_data("a=T,,garbage,=5,ab=3,f=32");
        assert_eq!(cmd.get_char('a'), Some('T'));
        assert_eq!(cmd.get('f'), Some("32"));
        assert_eq!(cmd.len(), 2);
    }

    #[test]
    fn transmit_and_display_stores_image_and_records_placement() {
        let mut state = GraphicsState::new();
        // 1x1 RGBA pixel: opaque orange.
        let pixel = [0xFF_u8, 0x80, 0x00, 0xFF];

        let resp = state.handle("a=T,t=d,f=32,s=1,v=1,i=7", b64(&pixel).as_bytes());
        assert_eq!(
            resp,
            GraphicsResponse::Displayed {
                image_id: 7,
                placement_id: 0
            }
        );

        let img = state.image(7).expect("image 7 stored");
        assert_eq!(img.format, ImageFormat::Rgba);
        assert_eq!(img.width, 1);
        assert_eq!(img.height, 1);
        assert_eq!(img.pixels, pixel.to_vec());

        assert_eq!(state.placements().len(), 1);
        assert_eq!(state.placements()[0].image_id, 7);
    }

    #[test]
    fn repeated_reads_do_not_change_generation_or_payload() {
        let mut state = GraphicsState::new();
        let pixel = [0xAA_u8, 0xBB, 0xCC, 0xDD];
        let response = state.handle("a=T,t=d,f=32,s=1,v=1,i=7", b64(&pixel).as_bytes());
        assert_eq!(
            response,
            GraphicsResponse::Displayed {
                image_id: 7,
                placement_id: 0
            }
        );

        let first = state.image(7).expect("image 7 stored");
        assert_eq!(first.format, ImageFormat::Rgba);
        assert_eq!(first.width, 1);
        assert_eq!(first.height, 1);
        assert_eq!(first.generation, 1);
        assert_eq!(first.pixels, pixel.to_vec());

        let second = state.image(7).expect("image 7 stored");
        assert_eq!(second.format, first.format);
        assert_eq!(second.width, first.width);
        assert_eq!(second.height, first.height);
        assert_eq!(second.generation, first.generation);
        assert_eq!(second.pixels, first.pixels);
        assert_eq!(state.placements(), &[Placement {
            image_id: 7,
            placement_id: 0
        }]);
    }

    #[test]
    fn replacing_and_recreating_an_explicit_id_advance_generation() {
        let mut state = GraphicsState::new();
        let first = [0x01_u8, 0x02, 0x03, 0x04];
        let second = [0xFE_u8, 0xDC, 0xBA, 0x98];
        let third = [0x10_u8, 0x20, 0x30, 0x40];

        let first_response = state.handle("a=T,t=d,f=32,s=1,v=1,i=7", b64(&first).as_bytes());
        assert_eq!(
            first_response,
            GraphicsResponse::Displayed {
                image_id: 7,
                placement_id: 0
            }
        );
        let first_generation = state.image(7).expect("image 7 stored first").generation;

        let second_response = state.handle("a=t,t=d,f=32,s=1,v=1,i=7", b64(&second).as_bytes());
        assert_eq!(
            second_response,
            GraphicsResponse::Stored {
                image_id: 7
            }
        );

        let second_image = state.image(7).expect("image 7 stored second");
        assert_eq!(second_image.generation, first_generation + 1);
        assert_eq!(second_image.generation, 2);
        assert_eq!(second_image.pixels, second.to_vec());
        assert_eq!(second_image.width, 1);
        assert_eq!(second_image.height, 1);
        assert_eq!(state.placements(), &[Placement {
            image_id: 7,
            placement_id: 0
        }]);

        assert_eq!(
            state.handle("a=d,d=i,i=7", b""),
            GraphicsResponse::Deleted { image_ids: vec![7] }
        );
        assert!(state.image(7).is_none());

        assert_eq!(
            state.handle("a=t,t=d,f=32,s=1,v=1,i=7", b64(&third).as_bytes()),
            GraphicsResponse::Stored { image_id: 7 }
        );
        let recreated = state.image(7).expect("image 7 recreated");
        assert_eq!(recreated.generation, 3);
        assert_ne!(recreated.generation, first_generation);
        assert_eq!(recreated.pixels, third.to_vec());
    }

    #[test]
    fn transmit_only_does_not_place() {
        let mut state = GraphicsState::new();
        let pixel = [1_u8, 2, 3, 4];

        let resp = state.handle("a=t,t=d,f=32,s=1,v=1,i=3", b64(&pixel).as_bytes());
        assert_eq!(resp, GraphicsResponse::Stored { image_id: 3 });
        assert!(state.image(3).is_some());
        assert!(state.placements().is_empty());
    }

    #[test]
    fn rgb_and_png_formats_are_recognized() {
        let mut state = GraphicsState::new();

        let rgb = [9_u8, 8, 7];
        state.handle("a=t,t=d,f=24,s=1,v=1,i=1", b64(&rgb).as_bytes());
        let img = state.image(1).expect("rgb image stored");
        assert_eq!(img.format, ImageFormat::Rgb);
        assert_eq!(img.pixels, rgb.to_vec());

        // PNG bytes are stored verbatim -- no decoding here.
        let png = b"\x89PNG\r\n\x1a\n-not-really-a-png";
        state.handle("a=t,t=d,f=100,i=2", b64(png).as_bytes());
        let img = state.image(2).expect("png image stored");
        assert_eq!(img.format, ImageFormat::Png);
        assert_eq!(img.pixels, png.to_vec());
    }

    /// A PNG's first 33 bytes: signature, then the IHDR chunk with the size.
    /// Enough for the header read; nothing here decodes pixels.
    fn png_header(width: u32, height: u32) -> Vec<u8> {
        let mut png = b"\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR".to_vec();
        png.extend_from_slice(&width.to_be_bytes());
        png.extend_from_slice(&height.to_be_bytes());
        png.extend_from_slice(b"\x08\x06\x00\x00\x00\x00\x00\x00\x00");
        png
    }

    #[test]
    fn a_png_sent_without_its_size_takes_it_from_its_header() {
        // What `kitten icat` sends: f=100 and no s/v.
        let mut state = GraphicsState::new();
        state.handle("a=T,t=d,f=100,i=5", b64(&png_header(256, 128)).as_bytes());
        let img = state.image(5).expect("png stored");
        assert_eq!((img.width, img.height), (256, 128));
    }

    #[test]
    fn a_pngs_own_header_wins_over_a_wrong_size() {
        let mut state = GraphicsState::new();
        state.handle("a=T,t=d,f=100,s=1,v=1,i=5", b64(&png_header(40, 30)).as_bytes());
        let img = state.image(5).expect("png stored");
        assert_eq!((img.width, img.height), (40, 30));
    }

    #[test]
    fn a_chunked_png_is_sized_from_the_whole_transfer() {
        // The header straddles the chunk boundary. (The continuation repeats
        // a, t and i: the engine does not yet accept the key-less
        // continuation chunks the protocol allows.)
        let png = png_header(640, 480);
        let mut state = GraphicsState::new();
        state.handle("a=T,t=d,f=100,i=6,m=1", b64(&png[..18]).as_bytes());
        state.handle("a=T,t=d,i=6,m=0", b64(&png[18..]).as_bytes());
        let img = state.image(6).expect("png stored");
        assert_eq!((img.width, img.height), (640, 480));
    }

    #[test]
    fn a_png_header_claiming_an_undrawable_size_is_not_believed() {
        let mut state = GraphicsState::new();
        for (i, (w, h)) in [(100_000, 10), (10, 0), (MAX_PNG_SIDE + 1, 1)].into_iter().enumerate() {
            let id = 10 + i as u32;
            state.handle(&format!("a=t,t=d,f=100,i={id}"), b64(&png_header(w, h)).as_bytes());
            let img = state.image(id).expect("png stored");
            assert_eq!((img.width, img.height), (0, 0), "{w}x{h}");
        }
        state.handle("a=t,t=d,f=100,i=20", b64(&png_header(MAX_PNG_SIDE, 1)).as_bytes());
        assert_eq!(state.image(20).map(|img| img.width), Some(MAX_PNG_SIDE));
    }

    #[test]
    fn missing_format_defaults_to_rgba_and_bad_format_errors() {
        let mut state = GraphicsState::new();
        state.handle("a=t,t=d,s=1,v=1,i=5", b64(&[1, 2, 3, 4]).as_bytes());
        assert_eq!(state.image(5).unwrap().format, ImageFormat::Rgba);

        let resp = state.handle("a=t,t=d,f=17,i=6", b64(&[0]).as_bytes());
        assert!(matches!(resp, GraphicsResponse::Error(_)));
        assert!(state.image(6).is_none());
    }

    #[test]
    fn omitted_image_id_auto_assigns_distinct_ids() {
        let mut state = GraphicsState::new();
        let payload = b64(&[0_u8, 0, 0, 0]);

        let first = state.handle("a=t,t=d,f=32,s=1,v=1", payload.as_bytes());
        let second = state.handle("a=t,t=d,f=32,s=1,v=1", payload.as_bytes());

        let (GraphicsResponse::Stored { image_id: a }, GraphicsResponse::Stored { image_id: b }) =
            (first, second)
        else {
            panic!("expected two Stored responses");
        };
        assert_eq!(a, 1);
        assert_ne!(a, b);
        assert!(state.image(a).is_some());
        assert!(state.image(b).is_some());
    }

    #[test]
    fn display_existing_image_and_reject_unknown_id() {
        let mut state = GraphicsState::new();
        state.handle("a=t,t=d,f=32,s=1,v=1,i=4", b64(&[1, 1, 1, 1]).as_bytes());
        assert!(state.placements().is_empty());

        let resp = state.handle("a=p,i=4,p=11", b"");
        assert_eq!(
            resp,
            GraphicsResponse::Displayed {
                image_id: 4,
                placement_id: 11
            }
        );
        assert_eq!(state.placements(), &[Placement {
            image_id: 4,
            placement_id: 11
        }]);

        let resp = state.handle("a=p,i=999", b"");
        assert!(matches!(resp, GraphicsResponse::Error(_)));
        assert_eq!(state.placements().len(), 1);
    }

    #[test]
    fn delete_single_image_leaves_others_intact() {
        let mut state = GraphicsState::new();
        state.handle("a=T,t=d,f=32,s=1,v=1,i=7", b64(&[1, 2, 3, 4]).as_bytes());
        state.handle("a=T,t=d,f=32,s=1,v=1,i=8", b64(&[5, 6, 7, 8]).as_bytes());
        assert_eq!(state.placements().len(), 2);

        let resp = state.handle("a=d,d=i,i=7", b"");
        assert_eq!(resp, GraphicsResponse::Deleted {
            image_ids: vec![7]
        });
        assert!(state.image(7).is_none());
        assert!(state.image(8).is_some());
        assert_eq!(state.placements(), &[Placement {
            image_id: 8,
            placement_id: 0
        }]);

        // Deleting a missing id is not an error, just an empty result.
        let resp = state.handle("a=d,d=i,i=7", b"");
        assert_eq!(resp, GraphicsResponse::Deleted { image_ids: vec![] });
    }

    #[test]
    fn delete_all_clears_images_and_placements() {
        let mut state = GraphicsState::new();
        state.handle("a=T,t=d,f=32,s=1,v=1,i=2", b64(&[1, 2, 3, 4]).as_bytes());
        state.handle("a=T,t=d,f=32,s=1,v=1,i=5", b64(&[5, 6, 7, 8]).as_bytes());

        let resp = state.handle("a=d,d=a", b"");
        assert_eq!(resp, GraphicsResponse::Deleted {
            image_ids: vec![2, 5]
        });
        assert!(state.image(2).is_none());
        assert!(state.image(5).is_none());
        assert!(state.placements().is_empty());
    }

    #[test]
    fn unsupported_delete_sub_action_and_missing_d_key() {
        let mut state = GraphicsState::new();
        assert_eq!(state.handle("a=d,d=c", b""), GraphicsResponse::Unsupported);
        assert_eq!(state.handle("a=d", b""), GraphicsResponse::Unsupported);
    }

    #[test]
    fn chunked_transmission_assembles_across_calls() {
        let mut state = GraphicsState::new();
        // 2x1 RGBA: two distinct pixels, split across two chunks. Each chunk
        // is independently base64-encoded, as the protocol requires.
        let first_half = [0xDE_u8, 0xAD, 0xBE, 0xEF];
        let second_half = [0x01_u8, 0x02, 0x03, 0x04];

        let resp = state.handle(
            "a=T,t=d,f=32,s=2,v=1,i=42,m=1",
            b64(&first_half).as_bytes(),
        );
        assert!(matches!(resp, GraphicsResponse::Stored { .. }));
        // Nothing is visible until the transmission completes.
        assert!(state.image(42).is_none());
        assert!(state.placements().is_empty());

        let resp = state.handle("a=T,t=d,i=42", b64(&second_half).as_bytes());
        assert_eq!(
            resp,
            GraphicsResponse::Displayed {
                image_id: 42,
                placement_id: 0
            }
        );

        let img = state.image(42).expect("assembled image stored");
        assert_eq!(img.format, ImageFormat::Rgba);
        assert_eq!(img.width, 2);
        assert_eq!(img.height, 1);
        assert_eq!(img.pixels, [first_half, second_half].concat());
        assert_eq!(state.placements().len(), 1);
    }

    #[test]
    fn explicit_m0_terminates_a_chunked_transmission() {
        let mut state = GraphicsState::new();
        state.handle("a=t,t=d,f=24,s=2,v=1,i=9,m=1", b64(&[1, 2, 3]).as_bytes());
        let resp = state.handle("a=t,t=d,i=9,m=0", b64(&[4, 5, 6]).as_bytes());
        assert_eq!(resp, GraphicsResponse::Stored { image_id: 9 });
        assert_eq!(state.image(9).unwrap().pixels, vec![1, 2, 3, 4, 5, 6]);
    }

    #[test]
    fn unsupported_transmission_medium_is_reported_not_decoded() {
        let mut state = GraphicsState::new();
        // t=f (file) with a payload that is not even base64 -- we must not try.
        assert_eq!(
            state.handle("a=T,t=f,f=32,s=1,v=1,i=1", b"/tmp/some/file.png"),
            GraphicsResponse::Unsupported
        );
        // A missing medium on a transmit action is equally unsupported.
        assert_eq!(
            state.handle("a=t,f=32,s=1,v=1,i=1", b"AAAA"),
            GraphicsResponse::Unsupported
        );
        assert!(state.image(1).is_none());
    }

    #[test]
    fn malformed_base64_errors_without_panicking() {
        let mut state = GraphicsState::new();
        let resp = state.handle("a=T,t=d,f=32,s=1,v=1,i=1", b"!!!not base64!!!");
        assert!(matches!(resp, GraphicsResponse::Error(_)));
        assert!(state.image(1).is_none());
        assert!(state.placements().is_empty());
    }

    #[test]
    fn missing_action_defaults_to_transmit() {
        let mut state = GraphicsState::new();
        let pixel = [0x55_u8, 0x66, 0x77, 0x88];
        // Without 'a', action defaults to 't' (transmit).
        let resp = state.handle("t=d,f=32,s=1,v=1,i=99", b64(&pixel).as_bytes());
        assert_eq!(resp, GraphicsResponse::Stored { image_id: 99 });
        assert_eq!(state.image(99).unwrap().pixels, pixel.to_vec());
    }

    #[test]
    fn query_graphics_protocol_replies_ok_and_reflects_keys() {
        let mut state = GraphicsState::new();
        let resp = state.handle("a=q,t=d,i=1,s=100,v=50", b"");
        assert_eq!(
            resp,
            GraphicsResponse::Query {
                reply: "\x1b_Gi=1,s=100,v=50;OK\x1b\\".to_string()
            }
        );
        assert_eq!(
            state.take_last_reply(),
            Some("\x1b_Gi=1,s=100,v=50;OK\x1b\\".to_string())
        );

        // Query with unsupported medium returns ENOTSUP
        let resp = state.handle("a=q,t=f,i=2", b"");
        assert_eq!(
            resp,
            GraphicsResponse::Query {
                reply: "\x1b_Gi=2;ENOTSUP\x1b\\".to_string()
            }
        );
    }

    #[test]
    fn response_control_q2_generates_replies_for_displayed_and_deleted() {
        let mut state = GraphicsState::new();
        let pixel = [1_u8, 2, 3, 4];
        state.handle("a=T,t=d,f=32,s=1,v=1,i=5,q=2", b64(&pixel).as_bytes());
        assert_eq!(
            state.take_last_reply(),
            Some("\x1b_Gi=5,p=0;OK\x1b\\".to_string())
        );

        state.handle("a=d,d=i,i=5,q=2", b"");
        assert_eq!(
            state.take_last_reply(),
            Some("\x1b_G;OK\x1b\\".to_string())
        );
    }

    #[test]
    fn memory_cap_enforces_limit_and_evicts_lru() {
        let mut state = GraphicsState::new();
        state.set_max_memory_bytes(10_000);

        let img1 = vec![0x11_u8; 3_000];
        let img2 = vec![0x22_u8; 3_000];
        let img3 = vec![0x33_u8; 5_000];

        state.store_and_place_raw_image(ImageFormat::Png, 10, 10, img1).unwrap();
        state.store_and_place_raw_image(ImageFormat::Png, 10, 10, img2).unwrap();
        assert_eq!(state.placements().len(), 2);

        // img3 causes memory usage to exceed 10_000 bytes, evicting the oldest (img1)
        state.store_and_place_raw_image(ImageFormat::Png, 10, 10, img3).unwrap();
        assert!(state.image(1).is_none(), "oldest image evicted");
        assert!(state.image(2).is_some());
        assert!(state.image(3).is_some());

        // Single image larger than entire cap is rejected
        let huge = vec![0xFF_u8; 20_000];
        assert!(state.store_and_place_raw_image(ImageFormat::Png, 10, 10, huge).is_err());
    }

    #[test]
    fn multiple_pending_transfers_respect_aggregate_memory_cap() {
        let mut state = GraphicsState::new();
        state.set_max_memory_bytes(10_000);

        let chunk1 = vec![0x11_u8; 3_000];
        let chunk2 = vec![0x22_u8; 3_000];
        let chunk3 = vec![0x33_u8; 5_000];

        // Start transfer 1 (m=1)
        let r1 = state.handle("a=t,t=d,f=32,s=10,v=10,i=1,m=1", b64(&chunk1).as_bytes());
        assert_eq!(r1, GraphicsResponse::Stored { image_id: 1 });
        assert!(state.pending().contains_key(&ChunkKey::Image(1)));

        // Start transfer 2 (m=1)
        let r2 = state.handle("a=t,t=d,f=32,s=10,v=10,i=2,m=1", b64(&chunk2).as_bytes());
        assert_eq!(r2, GraphicsResponse::Stored { image_id: 2 });
        assert!(state.pending().contains_key(&ChunkKey::Image(2)));

        // Start transfer 3 (m=1) - causes aggregate pending transfers to exceed 10_000 bytes,
        // evicting the oldest pending transfer (image 1).
        let r3 = state.handle("a=t,t=d,f=32,s=10,v=10,i=3,m=1", b64(&chunk3).as_bytes());
        assert_eq!(r3, GraphicsResponse::Stored { image_id: 3 });
        assert!(!state.pending().contains_key(&ChunkKey::Image(1)), "oldest pending transfer evicted");
        assert!(state.pending().contains_key(&ChunkKey::Image(2)));
        assert!(state.pending().contains_key(&ChunkKey::Image(3)));
        assert!(state.retained_capacity_bytes() <= 10_000);
    }

    #[test]
    fn detect_image_dimensions_handles_png_gif_jpeg_webp() {
        let png = png_header(120, 80);
        assert_eq!(detect_image_dimensions(&png), Some((120, 80)));

        let mut gif = b"GIF89a".to_vec();
        gif.extend_from_slice(&200_u16.to_le_bytes());
        gif.extend_from_slice(&150_u16.to_le_bytes());
        assert_eq!(detect_image_dimensions(&gif), Some((200, 150)));

        // Minimal valid JPEG SOF0 stream
        let mut jpeg = vec![0xFF, 0xD8]; // SOI
        jpeg.extend_from_slice(&[0xFF, 0xC0]); // SOF0
        let sof_len = 11_u16;
        jpeg.extend_from_slice(&sof_len.to_be_bytes());
        jpeg.push(8); // precision
        jpeg.extend_from_slice(&320_u16.to_be_bytes()); // height
        jpeg.extend_from_slice(&640_u16.to_be_bytes()); // width
        jpeg.push(3); // components
        jpeg.extend_from_slice(&[1, 0x11, 0, 2, 0x11, 0, 3, 0x11, 0]);
        assert_eq!(detect_image_dimensions(&jpeg), Some((640, 320)));

        // WebP VP8X extended header
        let mut webp = b"RIFF".to_vec();
        webp.extend_from_slice(&30_u32.to_le_bytes());
        webp.extend_from_slice(b"WEBPVP8X");
        webp.extend_from_slice(&10_u32.to_le_bytes()); // chunk size
        webp.extend_from_slice(&[0, 0, 0, 0]); // flags
        let w_minus_1 = 499_u32;
        let h_minus_1 = 299_u32;
        webp.extend_from_slice(&w_minus_1.to_le_bytes()[..3]);
        webp.extend_from_slice(&h_minus_1.to_le_bytes()[..3]);
        assert_eq!(detect_image_dimensions(&webp), Some((500, 300)));
    }

    #[test]
    fn missing_or_unknown_action_errors() {
        let mut state = GraphicsState::new();
        // Since action 'a' defaults to 't' (transmit), omitting 'a' when 't' medium is also omitted
        // returns Unsupported (transmission without medium is unsupported).
        assert_eq!(
            state.handle("f=32,s=1,v=1", b""),
            GraphicsResponse::Unsupported
        );
        // Unknown action returns Error.
        assert!(matches!(
            state.handle("a=z", b""),
            GraphicsResponse::Error(_)
        ));
        // Multi-character action values are not valid either.
        assert!(matches!(
            state.handle("a=TT", b""),
            GraphicsResponse::Error(_)
        ));
    }

    #[test]
    fn compressed_png_with_oversized_decoded_dimensions_is_rejected() {
        let mut state = GraphicsState::new();
        // A tiny 33-byte PNG header claiming 10,000 x 10,000 pixels (400 MB decoded > 64 MB cap)
        let png = png_header(10_000, 10_000);
        assert!(png.len() < 100);

        // store_and_place_raw_image rejects oversized decoded PNG
        let err = state.store_and_place_raw_image(ImageFormat::Png, 0, 0, png.clone());
        assert!(err.is_err());
        assert_eq!(err.unwrap_err(), "image decoded size exceeds per-pane memory cap");

        // Kitty transmission with action=t or action=T also rejects it
        let resp = state.handle("a=t,t=d,f=100,i=10", b64(&png).as_bytes());
        assert_eq!(
            resp,
            GraphicsResponse::Error("image decoded size exceeds per-pane memory cap".to_string())
        );
        assert!(state.image(10).is_none());
    }

    #[test]
    fn multiple_compressed_pngs_exceeding_aggregate_decoded_budget_evict_lru() {
        let mut state = GraphicsState::new();
        // Cap set to 10,000 bytes.
        state.set_max_memory_bytes(10_000);

        // Each PNG header is 33 bytes on disk, but claims 40x40 pixels = 6,400 bytes decoded RGBA.
        // Individually, 6,400 bytes <= 10,000 bytes.
        let png1 = png_header(40, 40);
        let png2 = png_header(40, 40);

        state.store_and_place_raw_image(ImageFormat::Png, 0, 0, png1).expect("png1 fits");
        assert!(state.image(1).is_some());

        // png2 also decodes to 6,400 bytes. Combined decoded size = 12,800 > 10,000 cap.
        // It must evict png1 (LRU) rather than allowing aggregate decoded memory to exceed the cap.
        state.store_and_place_raw_image(ImageFormat::Png, 0, 0, png2).expect("png2 fits after evicting png1");
        assert!(state.image(1).is_none(), "png1 evicted due to aggregate decoded memory cap");
        assert!(state.image(2).is_some(), "png2 retained");
        assert!(state.retained_capacity_bytes() <= 10_000);
    }

    #[test]
    fn default_matches_new() {
        let state = GraphicsState::default();
        assert!(state.placements().is_empty());
        assert!(state.image(1).is_none());
    }
}
