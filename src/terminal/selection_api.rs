/*
 * Tako — Terminal Emulation Engine
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::state::Terminal;
use super::types::{Selection, SelectionMode};

impl Terminal {
    /// Convert a viewport row/col coordinate to a lifetime document coordinate.
    pub(crate) fn viewport_to_lifetime_coord(
        &self,
        viewport_row: usize,
        col: usize,
    ) -> (usize, usize) {
        let grid = self.active_grid();
        let rows = grid.rows();
        let cols = grid.cols();
        let scrollback_len = grid.scrollback_len();
        let total_rows = scrollback_len + rows;

        let c = col.min(cols.saturating_sub(1));

        let vp_top_abs = scrollback_len.saturating_sub(self.viewport_offset);
        let abs_row = vp_top_abs
            .saturating_add(viewport_row)
            .min(total_rows.saturating_sub(1));
        let lifetime_row = grid.history_evicted() + abs_row;
        (lifetime_row, c)
    }

    /// Begin a new selection at viewport `(row, col)`, setting both `anchor` and `active`
    /// to its lifetime document position.
    pub fn start_selection(&mut self, row: usize, col: usize, mode: SelectionMode) {
        let pos = self.viewport_to_lifetime_coord(row, col);
        self.selection = Some(Selection {
            anchor: pos,
            active: pos,
            mode,
        });
    }

    /// Update the active (drag) endpoint of the current selection from viewport `(row, col)`.
    /// No-op if no selection has been started.
    pub fn extend_selection(&mut self, row: usize, col: usize) {
        let pos = self.viewport_to_lifetime_coord(row, col);
        if let Some(sel) = self.selection.as_mut() {
            sel.active = pos;
        }
    }

    /// Discard the current selection.
    pub fn clear_selection(&mut self) {
        self.selection = None;
    }

    /// Selection mode of the current selection, or [`SelectionMode::Linear`].
    pub fn selection_mode(&self) -> SelectionMode {
        self.selection
            .map(|s| s.mode)
            .unwrap_or(SelectionMode::Linear)
    }

    /// Whether a selection is currently active and overlaps retained history/screen.
    pub fn has_selection(&self) -> bool {
        self.current_selection_retained_bounds().is_some()
    }

    /// Returns current selection bounds `(mode, (start_abs_row, start_col), (end_abs_row, end_col))`
    /// in retained document coordinates (where `abs_row = 0` is the oldest retained line),
    /// after clamping/dropping evicted lines.
    pub(crate) fn current_selection_retained_bounds(
        &self,
    ) -> Option<(SelectionMode, (usize, usize), (usize, usize))> {
        let sel = self.selection?;
        let grid = self.active_grid();
        let rows = grid.rows();
        let cols = grid.cols();
        let scrollback_len = grid.scrollback_len();
        let total_rows = scrollback_len + rows;
        if total_rows == 0 || cols == 0 {
            return None;
        }

        let evicted = grid.history_evicted();
        let min_retained_lt = evicted;
        let max_retained_lt = evicted + total_rows - 1;

        match sel.mode {
            SelectionMode::Linear => {
                let (start_lt, end_lt) = if sel.anchor <= sel.active {
                    (sel.anchor, sel.active)
                } else {
                    (sel.active, sel.anchor)
                };

                if end_lt.0 < min_retained_lt || start_lt.0 > max_retained_lt {
                    return None;
                }

                let (start_abs_row, start_col) = if start_lt.0 < min_retained_lt {
                    (0, 0)
                } else {
                    (start_lt.0 - evicted, start_lt.1.min(cols - 1))
                };

                let (end_abs_row, end_col) = if end_lt.0 > max_retained_lt {
                    (total_rows - 1, cols - 1)
                } else {
                    (end_lt.0 - evicted, end_lt.1.min(cols - 1))
                };

                Some((
                    SelectionMode::Linear,
                    (start_abs_row, start_col),
                    (end_abs_row, end_col),
                ))
            }
            SelectionMode::Rectangular => {
                let min_lt_row = sel.anchor.0.min(sel.active.0);
                let max_lt_row = sel.anchor.0.max(sel.active.0);
                let min_col = sel.anchor.1.min(sel.active.1).min(cols - 1);
                let max_col = sel.anchor.1.max(sel.active.1).min(cols - 1);

                if max_lt_row < min_retained_lt || min_lt_row > max_retained_lt {
                    return None;
                }

                let start_abs_row = if min_lt_row < min_retained_lt {
                    0
                } else {
                    min_lt_row - evicted
                };
                let end_abs_row = (max_lt_row.saturating_sub(evicted)).min(total_rows - 1);

                Some((
                    SelectionMode::Rectangular,
                    (start_abs_row, min_col),
                    (end_abs_row, max_col),
                ))
            }
        }
    }

    /// The viewport-relative `(start, end)` bounds of the current selection for rendering highlight,
    /// or `None` if no selection exists or if the selection does not overlap the visible viewport.
    pub fn selection_range(&self) -> Option<((usize, usize), (usize, usize))> {
        let (mode, (start_abs_row, start_col), (end_abs_row, end_col)) =
            self.current_selection_retained_bounds()?;
        let grid = self.active_grid();
        let rows = grid.rows();
        let scrollback_len = grid.scrollback_len();

        let vp_top_abs = scrollback_len.saturating_sub(self.viewport_offset);
        let vp_bottom_abs = vp_top_abs + rows.saturating_sub(1);

        match mode {
            SelectionMode::Linear => {
                if end_abs_row < vp_top_abs || start_abs_row > vp_bottom_abs {
                    return None;
                }

                let eff_start_abs = if start_abs_row < vp_top_abs {
                    (vp_top_abs, 0)
                } else {
                    (start_abs_row, start_col)
                };

                let eff_end_abs = if end_abs_row > vp_bottom_abs {
                    (vp_bottom_abs, grid.cols().saturating_sub(1))
                } else {
                    (end_abs_row, end_col)
                };

                let v_start_row = eff_start_abs.0 - vp_top_abs;
                let v_start_col = eff_start_abs.1;
                let v_end_row = eff_end_abs.0 - vp_top_abs;
                let v_end_col = eff_end_abs.1;

                Some(((v_start_row, v_start_col), (v_end_row, v_end_col)))
            }
            SelectionMode::Rectangular => {
                if end_abs_row < vp_top_abs || start_abs_row > vp_bottom_abs {
                    return None;
                }

                let eff_min_row = start_abs_row.max(vp_top_abs);
                let eff_max_row = end_abs_row.min(vp_bottom_abs);

                let v_start_row = eff_min_row - vp_top_abs;
                let v_end_row = eff_max_row - vp_top_abs;

                Some(((v_start_row, start_col), (v_end_row, end_col)))
            }
        }
    }

    /// Check if absolute row `abs_row` soft-wraps into `abs_row + 1`.
    pub fn is_line_wrapped_abs(&self, abs_row: usize) -> bool {
        let grid = self.active_grid();
        let scrollback_len = grid.scrollback_len();
        let rows = grid.rows();
        let total_rows = scrollback_len + rows;
        if abs_row >= total_rows {
            return false;
        }
        if abs_row < scrollback_len {
            let idx = (scrollback_len - 1) - abs_row;
            grid.scrollback_line_wrapped(idx)
        } else {
            let live_row = abs_row - scrollback_len;
            grid.is_line_wrapped(live_row)
        }
    }

    /// Extract the text covered by the current selection in document coordinates, or `None` if
    /// there is no selection.
    pub fn selected_text(&self) -> Option<String> {
        let (mode, (start_abs_row, start_col), (end_abs_row, end_col)) =
            self.current_selection_retained_bounds()?;
        let grid = self.active_grid();
        let cols = grid.cols();
        let scrollback_len = grid.scrollback_len();

        let abs_row_text = |abs_row: usize, from: usize, to: usize| -> String {
            let mut line = String::new();
            for col in from..=to {
                let cell = if abs_row < scrollback_len {
                    let idx = (scrollback_len - 1) - abs_row;
                    grid.scrollback_line(idx)
                        .and_then(|l| l.get(col).copied())
                        .unwrap_or_default()
                } else {
                    let live_row = abs_row - scrollback_len;
                    grid.get(live_row, col).copied().unwrap_or_default()
                };
                if cell.is_wide_spacer || cell.is_wide_spacer_head {
                    continue;
                }
                grid.push_cell_text(&mut line, &cell);
            }
            line
        };

        match mode {
            SelectionMode::Linear => {
                let mut out = String::new();
                for abs_row in start_abs_row..=end_abs_row {
                    let from = if abs_row == start_abs_row {
                        start_col
                    } else {
                        0
                    };
                    let to = if abs_row == end_abs_row {
                        end_col
                    } else {
                        cols.saturating_sub(1)
                    };
                    let mut line = abs_row_text(abs_row, from, to);

                    let wraps_to_next = self.is_line_wrapped_abs(abs_row + 1);
                    if !wraps_to_next {
                        let trimmed_len = line.trim_end().len();
                        line.truncate(trimmed_len);
                    }

                    out.push_str(&line);
                    if abs_row != end_abs_row && !wraps_to_next {
                        out.push('\n');
                    }
                }
                Some(out)
            }
            SelectionMode::Rectangular => {
                let mut lines: Vec<String> = Vec::new();
                for abs_row in start_abs_row..=end_abs_row {
                    let mut line = abs_row_text(abs_row, start_col, end_col);
                    let trimmed_len = line.trim_end().len();
                    line.truncate(trimmed_len);
                    lines.push(line);
                }
                Some(lines.join("\n"))
            }
        }
    }
}
