use arbitrary::Arbitrary;
use tako_core::terminal::{SelectionMode, Terminal};

use crate::harness::assert_safe_readback;
use crate::truncate_utf8;

/// Selection mode for arbitrary input generation.
#[derive(Arbitrary, Debug, Clone, Copy, PartialEq, Eq)]
pub enum ArbitrarySelectionMode {
    Linear,
    Rectangular,
}

impl From<ArbitrarySelectionMode> for SelectionMode {
    fn from(mode: ArbitrarySelectionMode) -> Self {
        match mode {
            ArbitrarySelectionMode::Linear => SelectionMode::Linear,
            ArbitrarySelectionMode::Rectangular => SelectionMode::Rectangular,
        }
    }
}

/// A discrete, bounded operation that can be applied to a [`Terminal`].
#[derive(Arbitrary, Debug, Clone)]
pub enum TerminalOp {
    Feed(Vec<u8>),
    Resize {
        cols: u8,
        rows: u8,
    },
    ResizeWithPixels {
        cols: u8,
        rows: u8,
        width_px: u16,
        height_px: u16,
    },
    ResizeWithCellSize {
        cols: u8,
        rows: u8,
        cell_w: u16,
        cell_h: u16,
    },
    ScrollUp(u8),
    ScrollDown(u8),
    ScrollBottom,
    SetScrollPosition(u8),
    StartSelection {
        row: u8,
        col: u8,
        mode: ArbitrarySelectionMode,
    },
    ExtendSelection {
        row: u8,
        col: u8,
    },
    SelectWord {
        row: u8,
        col: u8,
    },
    SelectLine {
        row: u8,
        col: u8,
    },
    ClearSelection,
    SetDarkScheme(bool),
    SetAnswerback(String),
    SetXtversion(String),
    MarkAllDamaged,
}

/// Input structure for the stateful terminal operations fuzz target.
#[derive(Arbitrary, Debug, Clone)]
pub struct TerminalOpInput {
    pub initial_cols: u8,
    pub initial_rows: u8,
    pub initial_scrollback: u16,
    pub ops: Vec<TerminalOp>,
}

/// Clamps columns to a safe, non-zero bound [1, 200].
pub fn clamp_cols(c: u8) -> usize {
    (c as usize % 200).max(1)
}

/// Clamps rows to a safe, non-zero bound [1, 100].
pub fn clamp_rows(r: u8) -> usize {
    (r as usize % 100).max(1)
}

/// Clamps scrollback capacity to [1, 2000].
pub fn clamp_scrollback(s: u16) -> usize {
    (s as usize % 2000).max(1)
}

/// Applies a single [`TerminalOp`] to `term` with bounded values, then validates readback safety.
pub fn apply_op(term: &mut Terminal, op: &TerminalOp) {
    match op {
        TerminalOp::Feed(bytes) => {
            let max_len = bytes.len().min(4096);
            term.feed(&bytes[..max_len]);
        }
        TerminalOp::Resize { cols, rows } => {
            term.resize(clamp_cols(*cols), clamp_rows(*rows));
        }
        TerminalOp::ResizeWithPixels {
            cols,
            rows,
            width_px,
            height_px,
        } => {
            term.resize_with_pixels(
                clamp_cols(*cols),
                clamp_rows(*rows),
                *width_px as u32,
                *height_px as u32,
            );
        }
        TerminalOp::ResizeWithCellSize {
            cols,
            rows,
            cell_w,
            cell_h,
        } => {
            term.resize_with_cell_size(
                clamp_cols(*cols),
                clamp_rows(*rows),
                (*cell_w as u32 % 200).max(1),
                (*cell_h as u32 % 200).max(1),
            );
        }
        TerminalOp::ScrollUp(n) => {
            term.scroll_viewport_up((*n as usize) % 100);
        }
        TerminalOp::ScrollDown(n) => {
            term.scroll_viewport_down((*n as usize) % 100);
        }
        TerminalOp::ScrollBottom => {
            term.scroll_viewport_bottom();
        }
        TerminalOp::SetScrollPosition(pos) => {
            let p = (*pos as f64) / 255.0;
            term.set_scroll_position(p);
        }
        TerminalOp::StartSelection { row, col, mode } => {
            term.start_selection(*row as usize, *col as usize, (*mode).into());
        }
        TerminalOp::ExtendSelection { row, col } => {
            term.extend_selection(*row as usize, *col as usize);
        }
        TerminalOp::SelectWord { row, col } => {
            term.select_word(*row as usize, *col as usize);
        }
        TerminalOp::SelectLine { row, col } => {
            term.select_line(*row as usize, *col as usize);
        }
        TerminalOp::ClearSelection => {
            term.clear_selection();
        }
        TerminalOp::SetDarkScheme(dark) => {
            term.set_dark_scheme(*dark);
        }
        TerminalOp::SetAnswerback(s) => {
            term.set_answerback(truncate_utf8(s, 64));
        }
        TerminalOp::SetXtversion(s) => {
            term.set_xtversion(truncate_utf8(s, 64));
        }
        TerminalOp::MarkAllDamaged => {
            term.mark_all_damaged();
        }
    }

    assert_safe_readback(term);
}

/// Initializes a [`Terminal`] and applies all bounded operations from [`TerminalOpInput`].
pub fn apply_ops(input: &TerminalOpInput) {
    let cols = clamp_cols(input.initial_cols);
    let rows = clamp_rows(input.initial_rows);
    let scrollback = clamp_scrollback(input.initial_scrollback);
    let mut term = Terminal::with_scrollback(cols, rows, scrollback);

    // Initial readback
    assert_safe_readback(&mut term);

    // Limit operation count to avoid timeouts / time-bombs
    for op in input.ops.iter().take(64) {
        apply_op(&mut term, op);
    }
}
