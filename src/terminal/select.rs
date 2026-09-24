//! Expanding a click into a word or a line.
//!
//! Double-click selects the word under the pointer, triple-click the whole
//! logical line. Both live here rather than in the host because both need
//! things only the grid knows: where a wide glyph's spacer sits, and which
//! rows are soft-wrapped continuations of the row above rather than lines of
//! their own.
//!
//! That second point is the one that matters in practice. The text worth
//! double-clicking in a terminal is usually a path or a URL, and those are
//! exactly the strings long enough to wrap. A word selection that stopped at
//! the right edge of the screen would fail on the cases it exists for.

use super::{SelectionMode, Terminal};
use crate::grid::Cell;

/// Characters that continue a word beyond letters and digits.
///
/// This is wider than prose would want: with `.` and `-` in the set,
/// double-clicking `end.` in a sentence takes the full stop with it. It is
/// the right trade for a terminal anyway, because the strings people reach
/// for are `src/terminal/select.rs`, `https://host/p?q=1`, `file.rs:42` and
/// `some-package@1.2.3`, and every one of them would otherwise come apart
/// into fragments. kitty and wezterm default to very nearly this set for the
/// same reason.
const WORD_PUNCTUATION: &str = "_@-./~?&=%+#:";

/// What kind of run a cell belongs to. Double-clicking selects the whole run
/// of whichever kind was clicked, so a click on punctuation takes the
/// punctuation and a click in a gap takes the gap.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Class {
    Space,
    Word,
    Symbol,
}

fn classify(cell: &Cell) -> Class {
    // A wide glyph's trailing spacer carries no character of its own; it
    // belongs to the glyph in the cell before it.
    let ch = cell.char;
    if ch == '\0' || ch == ' ' || ch == '\t' {
        return Class::Space;
    }
    if ch.is_alphanumeric() || WORD_PUNCTUATION.contains(ch) {
        return Class::Word;
    }
    Class::Symbol
}

impl Terminal {
    /// The class of the cell at a viewport position, treating a wide glyph's
    /// spacer as part of the glyph it follows.
    fn class_at(&self, row: usize, col: usize) -> Class {
        let cells = self.viewport_row(row);
        let Some(cell) = cells.get(col) else {
            return Class::Space;
        };
        if cell.is_wide_spacer && col > 0 {
            return classify(&cells[col - 1]);
        }
        classify(cell)
    }

    /// Whether the viewport row is a soft-wrapped continuation of the row
    /// above it -- the same logical line, broken by the screen edge.
    fn viewport_row_is_continuation(&self, row: usize) -> bool {
        let grid = self.active_grid();
        let vp_top_abs = grid.scrollback_len().saturating_sub(self.viewport_offset);
        self.is_line_wrapped_abs(vp_top_abs + row)
    }

    /// Selects the word under viewport `(row, col)`.
    ///
    /// A run continues across a soft wrap, so a path or URL broken by the
    /// screen edge still selects whole. It stops at the top of the viewport:
    /// a line that began in scrollback above the visible area is not
    /// addressable here, and clamping is better than selecting the wrong
    /// thing.
    pub fn select_word(&mut self, row: usize, col: usize) {
        let cols = self.active_grid().cols();
        let rows = self.active_grid().rows();
        if cols == 0 || rows == 0 {
            return;
        }
        // The viewport is always `rows` tall whatever the scroll offset --
        // rows above the live screen are served from scrollback by
        // `viewport_row`, they are not extra rows.
        let col = col.min(cols - 1);
        let row = row.min(rows - 1);
        let class = self.class_at(row, col);

        // Walk left, crossing into the previous row whenever this one is a
        // continuation of it and we have run off its left edge.
        let (mut start_row, mut start_col) = (row, col);
        loop {
            if start_col > 0 {
                if self.class_at(start_row, start_col - 1) != class {
                    break;
                }
                start_col -= 1;
            } else {
                if start_row == 0 || !self.viewport_row_is_continuation(start_row) {
                    break;
                }
                let above = start_row - 1;
                if self.class_at(above, cols - 1) != class {
                    break;
                }
                start_row = above;
                start_col = cols - 1;
            }
        }

        // And right, crossing into the next row when that row continues this
        // one.
        let last_row = rows - 1;
        let (mut end_row, mut end_col) = (row, col);
        loop {
            if end_col + 1 < cols {
                if self.class_at(end_row, end_col + 1) != class {
                    break;
                }
                end_col += 1;
            } else {
                let below = end_row + 1;
                if below > last_row || !self.viewport_row_is_continuation(below) {
                    break;
                }
                if self.class_at(below, 0) != class {
                    break;
                }
                end_row = below;
                end_col = 0;
            }
        }

        self.set_selection_between((start_row, start_col), (end_row, end_col));
    }

    /// Selects the whole logical line under viewport `(row, col)`, following
    /// soft wraps in both directions so a wrapped command line comes out as
    /// the one line the user sees it as.
    pub fn select_line(&mut self, row: usize, _col: usize) {
        let cols = self.active_grid().cols();
        let rows = self.active_grid().rows();
        if cols == 0 || rows == 0 {
            return;
        }
        let row = row.min(rows - 1);

        let mut first = row;
        while first > 0 && self.viewport_row_is_continuation(first) {
            first -= 1;
        }

        let last_row = rows - 1;
        let mut last = row;
        while last < last_row && self.viewport_row_is_continuation(last + 1) {
            last += 1;
        }

        self.set_selection_between((first, 0), (last, cols - 1));
    }

    /// Anchors a selection across an inclusive viewport span.
    fn set_selection_between(&mut self, from: (usize, usize), to: (usize, usize)) {
        self.start_selection(from.0, from.1, SelectionMode::Linear);
        self.extend_selection(to.0, to.1);
    }
}
