/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::reader::Reader;
use super::types::{
    CheckpointError, HYPERLINK_ID_ENTRY, IMAGE_ENTRY, MIN_BYTES_PER_HYPERLINK_ID,
    MIN_BYTES_PER_IMAGE, MIN_BYTES_PER_LENGTH_PREFIXED, MIN_BYTES_PER_PENDING,
    MIN_BYTES_PER_PLACEMENT, PENDING_ENTRY, PLACEMENT_SPINE, STRING_SPINE, map_spine,
};
use crate::parser::{Parser, ParserSnapshot, State};
use crate::terminal::palette::Palette;
use crate::terminal::title_stack::TitleStack;
use crate::terminal::{Charset, DcsKind, GraphicsPlacement};
use std::collections::HashMap;

#[allow(clippy::type_complexity)]
pub(crate) fn read_parser_and_charsets(
    r: &mut Reader<'_>,
) -> Result<
    (
        Parser,
        Option<DcsKind>,
        Vec<u8>,
        Charset,
        Charset,
        Charset,
        Charset,
        bool,
        u8,
        Option<Charset>,
    ),
    CheckpointError,
> {
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
        return Err(CheckpointError::InvalidData(
            "too many parser intermediates",
        ));
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

    let dcs = match r.read_u8()? {
        1 => Some(DcsKind::Decrqss),
        2 => Some(DcsKind::XtGetTcap),
        _ => None,
    };
    let dcs_buf = r.read_bytes_budgeted()?.to_vec();

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

    Ok((
        parser,
        dcs,
        dcs_buf,
        g0,
        g1,
        g2,
        g3,
        shift_out,
        gr_slot,
        single_shift,
    ))
}

pub(crate) fn read_hyperlinks(
    r: &mut Reader<'_>,
) -> Result<(Vec<String>, HashMap<String, u32>, Option<u32>), CheckpointError> {
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
    Ok((hyperlinks, hyperlink_ids, current_hyperlink))
}

pub(crate) fn read_title_and_stack(
    r: &mut Reader<'_>,
) -> Result<(String, TitleStack), CheckpointError> {
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
    Ok((title, TitleStack::from_items(title_items)))
}

pub(crate) fn read_palette(
    r: &mut Reader<'_>,
) -> Result<
    (
        Palette,
        Option<(u8, u8, u8)>,
        Option<(u8, u8, u8)>,
        Option<(u8, u8, u8)>,
    ),
    CheckpointError,
> {
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
    palette.set_fg_overridden(default_fg.is_some());
    palette.set_bg_overridden(default_bg.is_some());
    palette.set_cursor_overridden(cursor_color.is_some());
    Ok((palette, default_fg, default_bg, cursor_color))
}

pub(crate) fn read_graphics(
    r: &mut Reader<'_>,
) -> Result<(Vec<GraphicsPlacement>, crate::graphics::GraphicsState), CheckpointError> {
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
                generation: 0,
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
    Ok((graphics_placements, graphics))
}
