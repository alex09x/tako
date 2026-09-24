//! Deterministic textual snapshots of terminal state.
//!
//! Tests that want to assert "the screen looks like this" have so far
//! rebuilt the string by hand out of [`Terminal::viewport_row`]. That works
//! for one assertion about one row and fails as a golden format: it cannot
//! express styling, and a mismatch prints two opaque strings with no hint of
//! which column moved.
//!
//! The snapshots here are built to be diffed. Styling is reported only where
//! it is not the default, so an ordinary screen stays short and a colour or
//! attribute regression is the only thing that shows up in the diff.

use super::{ScreenBuffer, Terminal};
use crate::grid::{Cell, CellAttrs, Color, Grid};

/// Everything about a cell except which character it holds. Adjacent cells
/// that compare equal collapse into a single reported run.
#[derive(Clone, PartialEq)]
struct Style {
    fg: Color,
    bg: Color,
    attrs: CellAttrs,
    underline_style: u8,
    underline_color: Color,
    protected: bool,
    hyperlink: Option<u32>,
}

impl Style {
    fn of(cell: &Cell) -> Self {
        Self {
            fg: cell.fg,
            bg: cell.bg,
            attrs: cell.attrs,
            underline_style: cell.underline_style,
            underline_color: cell.underline_color,
            protected: cell.protected,
            hyperlink: cell.hyperlink,
        }
    }

    /// A cell nobody has styled. These are the overwhelming majority and are
    /// left out of the snapshot entirely.
    fn is_default(&self) -> bool {
        self.fg == Color::Default
            && self.bg == Color::Default
            && self.attrs.is_empty()
            && self.underline_style == 0
            && self.underline_color == Color::Default
            && !self.protected
            && self.hyperlink.is_none()
    }

    fn describe(&self) -> String {
        let mut parts: Vec<String> = Vec::new();

        for (flag, name) in [
            (CellAttrs::BOLD, "bold"),
            (CellAttrs::DIM, "dim"),
            (CellAttrs::ITALIC, "italic"),
            (CellAttrs::UNDERLINE, "underline"),
            (CellAttrs::BLINK, "blink"),
            (CellAttrs::REVERSE, "reverse"),
            (CellAttrs::HIDDEN, "hidden"),
            (CellAttrs::STRIKETHROUGH, "strike"),
            (CellAttrs::OVERLINE, "overline"),
        ] {
            if self.attrs.contains(flag) {
                parts.push(name.to_string());
            }
        }

        if self.fg != Color::Default {
            parts.push(format!("fg={}", describe_color(self.fg)));
        }
        if self.bg != Color::Default {
            parts.push(format!("bg={}", describe_color(self.bg)));
        }
        if self.underline_style != 0 {
            // 1 single, 2 double, 3 curly, 4 dotted, 5 dashed (SGR 4:x).
            let name = match self.underline_style {
                1 => "single",
                2 => "double",
                3 => "curly",
                4 => "dotted",
                5 => "dashed",
                _ => "other",
            };
            parts.push(format!("ul={name}"));
        }
        if self.underline_color != Color::Default {
            parts.push(format!("ulcolor={}", describe_color(self.underline_color)));
        }
        if self.protected {
            parts.push("protected".to_string());
        }
        if let Some(id) = self.hyperlink {
            parts.push(format!("link={id}"));
        }

        parts.join(" ")
    }
}

fn describe_color(color: Color) -> String {
    match color {
        Color::Default => "default".to_string(),
        Color::Indexed(n) => n.to_string(),
        Color::Rgb(r, g, b) => format!("#{r:02x}{g:02x}{b:02x}"),
    }
}

/// Appends the text a cell contributes to a text dump, if any: its whole
/// grapheme cluster.
///
/// A wide glyph occupies two cells; the second is a spacer that renders
/// nothing, and a spacer head is the stub left in the last column when a wide
/// glyph could not fit and wrapped. Both are grid bookkeeping rather than
/// text, so neither appears in the dump: a wide character is dumped once.
fn push_glyph(grid: &Grid, out: &mut String, cell: &Cell) {
    if cell.is_wide_spacer || cell.is_wide_spacer_head {
        return;
    }
    grid.push_cell_text(out, cell);
}

/// The text of a row of cells, as [`push_glyph`] contributes it.
fn row_text(grid: &Grid, cells: &[Cell]) -> String {
    let mut line = String::new();
    for cell in cells {
        push_glyph(grid, &mut line, cell);
    }
    line
}

impl Terminal {
    /// The visible screen as plain text: one line per row, trailing blanks
    /// trimmed. The everyday assertion, and readable in a test failure.
    pub fn dump_text(&self) -> String {
        let rows = self.active_grid().rows();
        let mut out = String::new();
        for row in 0..rows {
            if row > 0 {
                out.push('\n');
            }
            let line = row_text(self.active_grid(), &self.viewport_row(row));
            out.push_str(line.trim_end());
        }
        out
    }

    /// Everything the terminal is holding as plain text: the retained
    /// scrollback first, then the live screen.
    ///
    /// This is what a host copies. Reading only the visible screen — which is
    /// all the viewport-shaped accessors can give — silently drops the
    /// history, so "copy all" on a phone would return the last twenty-four
    /// lines of a session that has thousands.
    ///
    /// Soft-wrapped rows are rejoined, because a line broken by the screen
    /// edge is one line to whoever pastes it. Trailing blanks go, for the
    /// same reason.
    pub fn buffer_text(&self) -> String {
        let grid = self.active_grid();
        let (cols, rows) = (grid.cols(), grid.rows());
        let scrollback_len = grid.scrollback_len();

        let mut out = String::new();
        let mut line = String::new();

        for abs_row in 0..(scrollback_len + rows) {
            for col in 0..cols {
                let cell = if abs_row < scrollback_len {
                    let idx = (scrollback_len - 1) - abs_row;
                    grid.scrollback_line(idx)
                        .and_then(|l| l.get(col).copied())
                        .unwrap_or_default()
                } else {
                    grid.get(abs_row - scrollback_len, col)
                        .copied()
                        .unwrap_or_default()
                };
                push_glyph(grid, &mut line, &cell);
            }

            // The next row continues this one only if it is a soft wrap.
            if self.is_line_wrapped_abs(abs_row + 1) {
                continue;
            }
            while line.ends_with(' ') {
                line.pop();
            }
            out.push_str(&line);
            out.push('\n');
            line.clear();
        }

        out
    }

    /// A full snapshot: geometry and cursor, the text block, then one line
    /// per run of styled cells.
    ///
    /// Rows are quoted so trailing space is visible, and numbered so a diff
    /// names the row that moved. Runs are reported as `row col..col`, with
    /// the end exclusive.
    pub fn dump(&self) -> String {
        let grid = self.active_grid();
        let (cols, rows) = (grid.cols(), grid.rows());
        let (cursor_row, cursor_col) = self.cursor();

        let mut out = String::new();
        out.push_str(&format!(
            "{cols}x{rows} cursor=({cursor_row},{cursor_col}){} screen={} offset={}\n",
            if self.cursor_visible() { "" } else { " hidden" },
            match self.active_screen() {
                ScreenBuffer::Primary => "primary",
                ScreenBuffer::Alternate => "alternate",
            },
            self.viewport_offset(),
        ));

        // Width of the widest row index, so the numbers stay aligned.
        let width = rows.saturating_sub(1).to_string().len();

        for row in 0..rows {
            let line = row_text(grid, &self.viewport_row(row));
            out.push_str(&format!(
                "{row:>width$} \"{}\"\n",
                line.trim_end(),
                width = width
            ));
        }

        let runs = self.style_runs();
        if !runs.is_empty() {
            out.push_str("styles\n");
            for (row, start, end, style) in runs {
                out.push_str(&format!(
                    "{row:>width$} {start}..{end} {}\n",
                    style.describe(),
                    width = width
                ));
            }
        }

        out
    }

    /// Maximal runs of identically-styled, non-default cells, in row order.
    fn style_runs(&self) -> Vec<(usize, usize, usize, Style)> {
        let grid = self.active_grid();
        let (cols, rows) = (grid.cols(), grid.rows());
        let mut runs = Vec::new();

        for row in 0..rows {
            let cells = self.viewport_row(row);
            let mut col = 0;
            while col < cols.min(cells.len()) {
                let style = Style::of(&cells[col]);
                if style.is_default() {
                    col += 1;
                    continue;
                }
                let start = col;
                while col < cols.min(cells.len()) && Style::of(&cells[col]) == style {
                    col += 1;
                }
                runs.push((row, start, col, style));
            }
        }

        runs
    }
}
