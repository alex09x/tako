/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::budget::allocation_cost;
use super::commands::write_commands;
use super::encode_graphics::encode_graphics;
use super::grid::{write_clusters, write_grid};
use super::host::{shape_code, write_host_config};
use super::types::{CheckpointError, MAX_DIM, MAX_IMPORT_ALLOC_BYTES};
use super::writer::Writer;
use crate::parser::State;
use crate::terminal::{
    Charset, DcsKind, MouseTracking, ProtectedMode, ScreenBuffer, SemanticContent, Terminal,
};

pub(crate) fn encode(
    term: &Terminal,
    limit: u64,
    retain: bool,
    version: u32,
) -> Result<Writer, CheckpointError> {
    let (cols, rows) = (term.active_grid().cols(), term.active_grid().rows());
    if cols == 0 || cols > MAX_DIM || rows == 0 || rows > MAX_DIM {
        return Err(CheckpointError::DimensionOutOfBounds { cols, rows });
    }

    let cost = allocation_cost(term, version);
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

    write_grid(&mut w, &term.primary, rows, version);
    write_grid(&mut w, &term.alternate, rows, version);

    encode_cursor(&mut w, term);
    encode_tabstops(&mut w, term, cols);
    encode_modes(&mut w, term);
    encode_parser(&mut w, term);

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
    for opt_rgb in [term.default_fg, term.default_bg, term.cursor_color] {
        if let Some(rgb) = opt_rgb {
            w.write_bool(true);
            w.write_u8(rgb.0);
            w.write_u8(rgb.1);
            w.write_u8(rgb.2);
        } else {
            w.write_bool(false);
        }
    }

    // Kitty Keyboard
    let k_stack = term.kitty_keyboard.stack();
    w.write_u8(k_stack.len() as u8);
    for &f in k_stack {
        w.write_u8(f.bits());
    }

    encode_graphics(&mut w, term);

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

    if version >= 3 {
        write_host_config(&mut w, term);
        write_clusters(&mut w, &term.primary);
        write_clusters(&mut w, &term.alternate);
    }
    if version >= 4 {
        write_commands(&mut w, term, version);
    }

    if w.overflowed() {
        return Err(CheckpointError::TooLarge {
            size: w.count as u64,
            limit,
        });
    }

    Ok(w)
}

fn encode_cursor(w: &mut Writer, term: &Terminal) {
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
}

fn encode_tabstops(w: &mut Writer, term: &Terminal, cols: usize) {
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
}

fn encode_modes(w: &mut Writer, term: &Terminal) {
    let m = &term.modes;
    let mut mode_flags = 0u32;
    if m.autowrap {
        mode_flags |= 1 << 0;
    }
    if m.origin_mode {
        mode_flags |= 1 << 1;
    }
    if m.cursor_key_app_mode {
        mode_flags |= 1 << 2;
    }
    if m.mouse_utf8 {
        mode_flags |= 1 << 3;
    }
    if m.mouse_sgr {
        mode_flags |= 1 << 4;
    }
    if m.focus_events {
        mode_flags |= 1 << 5;
    }
    if m.bracketed_paste {
        mode_flags |= 1 << 6;
    }
    if m.insert {
        mode_flags |= 1 << 7;
    }
    if m.linefeed_mode {
        mode_flags |= 1 << 8;
    }
    if m.reverse_wrap {
        mode_flags |= 1 << 9;
    }
    if m.reverse_wrap_extended {
        mode_flags |= 1 << 10;
    }
    if m.left_right_margin_mode {
        mode_flags |= 1 << 11;
    }
    if m.alternate_scroll {
        mode_flags |= 1 << 12;
    }
    if m.synchronized_output {
        mode_flags |= 1 << 13;
    }
    if let Some(capture) = m.shift_capture {
        mode_flags |= 1 << 14;
        if capture {
            mode_flags |= 1 << 15;
        }
    }
    mode_flags |= u32::from(m.modify_other_keys.min(2)) << 16;
    if m.color_scheme_updates {
        mode_flags |= 1 << 18;
    }
    w.write_u32(mode_flags);
    w.write_u8(match m.mouse_tracking {
        MouseTracking::Off => 0,
        MouseTracking::Normal => 1,
        MouseTracking::ButtonEvent => 2,
        MouseTracking::AnyEvent => 3,
    });
}

fn encode_parser(w: &mut Writer, term: &Terminal) {
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

    w.write_u8(match term.dcs {
        None => 0,
        Some(DcsKind::Decrqss) => 1,
        Some(DcsKind::XtGetTcap) => 2,
    });
    w.write_bytes(&term.dcs_buf);

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
}
