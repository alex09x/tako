/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::writer::Writer;
use crate::terminal::Terminal;

pub(crate) fn encode_graphics(w: &mut Writer, term: &Terminal) {
    w.write_u32(term.graphics_placements.len() as u32);
    for p in &term.graphics_placements {
        w.write_u32(p.image_id);
        w.write_u32(p.placement_id);
        w.write_u32(p.row as u32);
        w.write_u32(p.col as u32);
    }

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
    let mut pending_entries: Vec<(
        &crate::graphics::ChunkKey,
        &crate::graphics::PendingTransfer,
    )> = pending.iter().collect();
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
}
