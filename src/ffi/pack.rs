/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::render_types::{FfiRowRange, FfiSnapshot};
use super::types::{
    DEFAULT_BG, DEFAULT_FG, FfiGrapheme, FfiGraphicsPlacement, FfiSelectionRange, FfiTerminalModes,
    PACKED_BLINK, PACKED_BOLD, PACKED_CELL_SIZE, PACKED_DIM, PACKED_GRAPHEME, PACKED_HIDDEN,
    PACKED_ITALIC, PACKED_OVERLINE, PACKED_REVERSE, PACKED_STRIKETHROUGH, PACKED_UNDERLINE,
    PACKED_WIDE, grapheme_text, resolve_color,
};
use crate::grid::CellAttrs;
use crate::terminal::{ScreenBuffer, Terminal};

pub(crate) fn snapshot_from_terminal(terminal: &mut Terminal) -> FfiSnapshot {
    let damaged_rows = terminal.take_damage();
    let (cursor_row, cursor_col) = terminal.cursor();
    let m = terminal.modes();
    let modes = FfiTerminalModes {
        autowrap: m.autowrap,
        origin_mode: m.origin_mode,
        cursor_key_app_mode: m.cursor_key_app_mode,
        mouse_tracking: m.mouse_tracking.into(),
        mouse_utf8: m.mouse_utf8,
        mouse_sgr: m.mouse_sgr,
        focus_events: m.focus_events,
        bracketed_paste: m.bracketed_paste,
        alternate_screen: terminal.active_screen() == ScreenBuffer::Alternate,
        alternate_scroll: m.alternate_scroll,
    };
    let selection_mode = terminal.selection_mode().into();
    let selection = terminal
        .selection_range()
        .map(|((sr, sc), (er, ec))| FfiSelectionRange {
            start_row: sr as u32,
            start_col: sc as u32,
            end_row: er as u32,
            end_col: ec as u32,
            mode: selection_mode,
        });
    let graphics_placements = terminal
        .graphics_placements()
        .iter()
        .map(|p| FfiGraphicsPlacement {
            image_id: p.image_id,
            placement_id: p.placement_id,
            row: p.row as u32,
            col: p.col as u32,
        })
        .collect();
    FfiSnapshot {
        cols: terminal.active_grid().cols() as u32,
        rows: terminal.active_grid().rows() as u32,
        cursor_row: cursor_row as u32,
        cursor_col: cursor_col as u32,
        cursor_visible: terminal.cursor_visible(),
        cursor_style: terminal.cursor_style().into(),
        title: terminal.title().to_string(),
        modes,
        viewport_offset: terminal.viewport_offset() as u32,
        scrollback_len: terminal.active_grid().scrollback_len() as u32,
        damaged_rows,
        selection,
        graphics_placements,
    }
}

pub(crate) fn viewport_packed_from_terminal(terminal: &Terminal) -> (Vec<u8>, Vec<FfiGrapheme>) {
    let rows = terminal.active_grid().rows() as u32;
    let all: Vec<u32> = (0..rows).collect();
    packed_rows_from_terminal(terminal, &all)
}

pub(crate) fn packed_rows_from_terminal(
    terminal: &Terminal,
    rows: &[u32],
) -> (Vec<u8>, Vec<FfiGrapheme>) {
    let (dfg, dbg, _) = terminal.default_colors();
    let default_fg = dfg.unwrap_or(DEFAULT_FG);
    let default_bg = dbg.unwrap_or(DEFAULT_BG);
    let palette = terminal.palette();
    let grid = terminal.active_grid();
    let cols = grid.cols();

    let mut out = Vec::with_capacity(rows.len() * cols * PACKED_CELL_SIZE);
    let mut graphemes = Vec::new();
    for (index, &row) in rows.iter().enumerate() {
        for (col, cell) in terminal.viewport_row(row as usize).into_iter().enumerate() {
            let grapheme = grapheme_text(grid, &cell);
            let ch = if cell.is_wide_spacer {
                0
            } else if cell.char == '\0' {
                u32::from(' ')
            } else {
                u32::from(cell.char)
            };
            let (fr, fg, fb) = resolve_color(cell.fg, default_fg, palette);
            let (br, bg, bb) = resolve_color(cell.bg, default_bg, palette);
            let (ur, ug, ub) = resolve_color(cell.underline_color, (fr, fg, fb), palette);

            let mut bits: u16 = 0;
            let mut set = |flag: u16, on: bool| {
                if on {
                    bits |= flag;
                }
            };
            set(PACKED_BOLD, cell.attrs.contains(CellAttrs::BOLD));
            set(PACKED_DIM, cell.attrs.contains(CellAttrs::DIM));
            set(PACKED_ITALIC, cell.attrs.contains(CellAttrs::ITALIC));
            set(PACKED_UNDERLINE, cell.attrs.contains(CellAttrs::UNDERLINE));
            set(PACKED_BLINK, cell.attrs.contains(CellAttrs::BLINK));
            set(PACKED_REVERSE, cell.attrs.contains(CellAttrs::REVERSE));
            set(PACKED_HIDDEN, cell.attrs.contains(CellAttrs::HIDDEN));
            set(
                PACKED_STRIKETHROUGH,
                cell.attrs.contains(CellAttrs::STRIKETHROUGH),
            );
            set(PACKED_OVERLINE, cell.attrs.contains(CellAttrs::OVERLINE));
            set(PACKED_WIDE, cell.is_wide_spacer_head);
            set(PACKED_GRAPHEME, grapheme.is_some());
            if let Some(text) = grapheme {
                graphemes.push(FfiGrapheme {
                    row: index as u32,
                    col: col as u32,
                    text,
                });
            }

            out.extend_from_slice(&ch.to_le_bytes());
            out.extend_from_slice(&[fr, fg, fb, br, bg, bb]);
            out.extend_from_slice(&bits.to_le_bytes());
            out.push(cell.underline_style);
            out.extend_from_slice(&[ur, ug, ub]);
        }
    }
    (out, graphemes)
}

pub(crate) fn collapse_row_ranges(rows: &[u32]) -> Vec<FfiRowRange> {
    let mut ranges: Vec<FfiRowRange> = Vec::new();
    for &row in rows {
        match ranges.last_mut() {
            Some(last) if last.start + last.count == row => last.count += 1,
            _ => ranges.push(FfiRowRange {
                start: row,
                count: 1,
            }),
        }
    }
    ranges
}
