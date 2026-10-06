/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::host::shape_from_code;
use super::reader::Reader;
use super::types::{CheckpointError, KITTY_FLAGS_SPINE, MAX_DIM};
use crate::grid::CellAttrs;
use crate::kitty_keyboard::{KittyFlags, KittyKeyboardState};
use crate::terminal::modes::TerminalModes;
use crate::terminal::{
    Charset, Cursor, CursorShape, MouseTracking, ProtectedMode, SavedCursor, TabStops,
};

pub(crate) fn read_cursor(
    r: &mut Reader<'_>,
) -> Result<(Cursor, bool, CursorShape, bool), CheckpointError> {
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
    Ok((cursor, cursor_visible, cursor_shape, cursor_blinking))
}

pub(crate) fn read_tabstops(
    r: &mut Reader<'_>,
    cols: usize,
    rows: usize,
) -> Result<TabStops, CheckpointError> {
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
    Ok(TabStops::from_raw(tab_cols, stops))
}

pub(crate) fn read_modes(r: &mut Reader<'_>) -> Result<TerminalModes, CheckpointError> {
    let mode_flags = r.read_u32()?;
    let mouse_tracking = match r.read_u8()? {
        1 => MouseTracking::Normal,
        2 => MouseTracking::ButtonEvent,
        3 => MouseTracking::AnyEvent,
        _ => MouseTracking::Off,
    };
    Ok(TerminalModes {
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
        grapheme_cluster: true,
        modify_other_keys: (((mode_flags >> 16) & 0b11) as u8).min(2),
        color_scheme_updates: (mode_flags & (1 << 18)) != 0,
    })
}

pub(crate) fn read_kitty_keyboard(
    r: &mut Reader<'_>,
) -> Result<KittyKeyboardState, CheckpointError> {
    let kk_count = r.read_u8()? as usize;
    r.check_count(kk_count, 1)?;
    r.charge_spine(kk_count, KITTY_FLAGS_SPINE)?;
    let mut kk_stack = Vec::with_capacity(kk_count);
    for _ in 0..kk_count {
        kk_stack.push(KittyFlags::from_bits_truncate(r.read_u8()?));
    }
    Ok(KittyKeyboardState::from_stack(kk_stack))
}
