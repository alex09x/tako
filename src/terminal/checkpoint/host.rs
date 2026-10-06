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
use super::types::CheckpointError;
use super::writer::Writer;
use crate::terminal::{CursorShape, CursorStyle, Terminal};

pub(crate) fn shape_code(shape: CursorShape) -> u8 {
    match shape {
        CursorShape::Block => 0,
        CursorShape::Underline => 1,
        CursorShape::Bar => 2,
    }
}

pub(crate) fn shape_from_code(code: u8) -> CursorShape {
    match code {
        1 => CursorShape::Underline,
        2 => CursorShape::Bar,
        _ => CursorShape::Block,
    }
}

/// What the host configured, as opposed to what a program did: v3's tail.
pub(crate) fn write_host_config(w: &mut Writer, term: &Terminal) {
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

/// [`write_host_config`]'s block, read back.
pub(crate) struct HostConfig {
    pub(crate) base: [(u8, u8, u8); 256],
    pub(crate) overridden: [bool; 256],
    pub(crate) base_fg: Option<(u8, u8, u8)>,
    pub(crate) base_bg: Option<(u8, u8, u8)>,
    pub(crate) base_cursor: Option<(u8, u8, u8)>,
    pub(crate) fg_overridden: bool,
    pub(crate) bg_overridden: bool,
    pub(crate) cursor_overridden: bool,
    pub(crate) default_cursor_style: CursorStyle,
    pub(crate) cursor_style_overridden: bool,
}

pub(crate) fn read_host_config(r: &mut Reader<'_>) -> Result<HostConfig, CheckpointError> {
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
