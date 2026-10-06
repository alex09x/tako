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

use super::dimensions::detect_image_dimensions;
use super::types::{ChunkKey, ImageFormat, PendingTransfer, Placement, StoredImage};

/// Default maximum memory capacity allocated for stored images per terminal pane (64 MiB).
pub const DEFAULT_MAX_IMAGE_MEMORY_BYTES: u64 = 64 * 1024 * 1024;
/// Default maximum memory capacity allocated for decoded image pixel/texture buffer per terminal pane (64 MiB).
pub const DEFAULT_MAX_DECODED_IMAGE_BYTES: u64 = DEFAULT_MAX_IMAGE_MEMORY_BYTES;

/// Image store, placement list, and chunk-assembly state for one terminal.
#[derive(Debug)]
pub struct GraphicsState {
    pub(crate) images: HashMap<u32, StoredImage>,
    pub(crate) placements: Vec<Placement>,
    pub(crate) pending: HashMap<ChunkKey, PendingTransfer>,
    pub(crate) next_image_id: u32,
    pub(crate) next_image_generation: u64,
    pub(crate) next_pending_generation: u64,
    pub(crate) max_memory_bytes: u64,
    pub(crate) last_reply: Option<String>,
}

impl Default for GraphicsState {
    fn default() -> Self {
        Self::new()
    }
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
        while self
            .retained_capacity_bytes()
            .saturating_add(incoming_bytes)
            > self.max_memory_bytes
        {
            if !self.images.is_empty() {
                if let Some(&oldest_id) = self
                    .images
                    .iter()
                    .min_by_key(|(_, img)| img.generation)
                    .map(|(id, _)| id)
                {
                    self.images.remove(&oldest_id);
                    self.placements.retain(|p| p.image_id != oldest_id);
                    self.pending.remove(&ChunkKey::Image(oldest_id));
                } else {
                    break;
                }
            } else if !self.pending.is_empty() {
                if let Some(&oldest_key) = self
                    .pending
                    .iter()
                    .min_by_key(|(_, transfer)| transfer.generation)
                    .map(|(k, _)| k)
                {
                    self.pending.remove(&oldest_key);
                } else {
                    break;
                }
            } else {
                break;
            }
        }
        self.retained_capacity_bytes()
            .saturating_add(incoming_bytes)
            <= self.max_memory_bytes
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

    /// The stored image with `id`, if any.
    pub fn image(&self, id: u32) -> Option<&StoredImage> {
        self.images.get(&id)
    }

    /// All current placements, in the order they were created.
    pub fn placements(&self) -> &[Placement] {
        &self.placements
    }

    /// Next id not already taken by a stored image.
    pub(crate) fn allocate_image_id(&mut self) -> u32 {
        while self.images.contains_key(&self.next_image_id) {
            self.next_image_id = self.next_image_id.wrapping_add(1).max(1);
        }
        let id = self.next_image_id;
        self.next_image_id = self.next_image_id.wrapping_add(1).max(1);
        id
    }

    pub(crate) fn allocate_image_generation(&mut self) -> u64 {
        let generation = self.next_image_generation;
        self.next_image_generation = self.next_image_generation.wrapping_add(1).max(1);
        generation
    }

    pub(crate) fn allocate_pending_generation(&mut self) -> u64 {
        let generation = self.next_pending_generation;
        self.next_pending_generation = self.next_pending_generation.wrapping_add(1).max(1);
        generation
    }
}
