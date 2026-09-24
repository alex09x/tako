//! DECRQCRA — Request Checksum of Rectangular Area.
//!
//! `CSI Pid ; Pg ; Pt ; Pl ; Pb ; Pr * y` asks for a checksum of a rectangle
//! and is answered with `DCS Pid ! ~ XXXX ST`, four upper-case hex digits.
//!
//! This sequence earns its place for one reason: it is the only way a test
//! harness outside the process can read the screen back. esctest — around a
//! thousand tests written against xterm's behaviour — reads every cell it
//! asserts on through DECRQCRA, so without it none of that suite can run
//! against us. vttest uses it too.
//!
//! The arithmetic is xterm's and is not guessable from the standards: DEC's
//! documentation gives the wire format and omits the computation entirely,
//! and the reference pages that discuss it are placeholders. What follows
//! mirrors `xtermCheckRect` in xterm's `screen.c`, which Thomas Dickey
//! reconstructed from a physical VT520.
//!
//! Two behaviours are worth knowing before reading the code, because both
//! look like bugs:
//!
//! * The sum is **negated**. A screen of printable text checksums to a large
//!   number near 0xFFFF, not a small one.
//! * Trailing blanks are **trimmed**. A plain space contributes nothing
//!   unless it is the first cell of the rectangle — but a space carrying an
//!   attribute is not a plain space, because attributes are added to the
//!   character value before the comparison.

use super::Terminal;
use crate::grid::CellAttrs;

/// xterm's `checksumExtension` bits, selected with XTCHECKSUM
/// (`CSI Ps # y`). Zero is DEC behaviour and is what esctest expects; each
/// bit turns one part of that behaviour *off*.
pub mod ext {
    /// Leave the sum positive instead of negating it.
    pub const POSITIVE: u16 = 1 << 0;
    /// Leave character attributes out of the sum.
    pub const NO_ATTRIBS: u16 = 1 << 1;
    /// Count trailing blanks instead of trimming them.
    pub const NO_TRIM: u16 = 1 << 2;
    /// Count never-written cells as spaces instead of skipping them.
    pub const DRAWN: u16 = 1 << 3;
    /// Use the raw character value and ignore combining marks.
    pub const BYTE: u16 = 1 << 4;
}

/// A rectangle in 1-based screen coordinates, inclusive on both ends.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(super) struct Rect {
    pub top: usize,
    pub left: usize,
    pub bottom: usize,
    pub right: usize,
}

impl Terminal {
    /// Resolves `Pt ; Pl ; Pb ; Pr` against the current screen.
    ///
    /// An omitted or zero parameter takes its default — the edge of the
    /// addressable area, which under origin mode is the margin rather than
    /// the screen edge. Every value is then clamped into that area, matching
    /// xterm's `limitedParseRow` / `limitedParseCol`.
    pub(super) fn parse_rect(&self, params: &[u16]) -> Rect {
        let grid = self.active_grid();
        let (rows, cols) = (grid.rows(), grid.cols());

        let (min_row, max_row) = if self.modes.origin_mode {
            (self.scroll_top + 1, self.scroll_bottom.min(rows - 1) + 1)
        } else {
            (1, rows)
        };
        let (min_col, max_col) = if self.modes.origin_mode {
            let (left, right) = self.h_margins();
            (left + 1, right + 1)
        } else {
            (1, cols)
        };

        // Origin mode makes the parameters region-relative, so a supplied
        // row is offset by the top margin before clamping.
        let row_at = |index: usize, default: usize| -> usize {
            let raw = match params.get(index) {
                Some(&v) if v > 0 => {
                    let v = v as usize;
                    if self.modes.origin_mode {
                        v + self.scroll_top
                    } else {
                        v
                    }
                }
                _ => default,
            };
            raw.clamp(min_row, max_row)
        };
        let col_at = |index: usize, default: usize| -> usize {
            let raw = match params.get(index) {
                Some(&v) if v > 0 => {
                    let v = v as usize;
                    if self.modes.origin_mode {
                        v + self.h_margins().0
                    } else {
                        v
                    }
                }
                _ => default,
            };
            raw.clamp(min_col, max_col)
        };

        Rect {
            top: row_at(0, min_row),
            left: col_at(1, min_col),
            bottom: row_at(2, max_row),
            right: col_at(3, max_col),
        }
    }

    /// The checksum of `rect`, following `xtermCheckRect`.
    ///
    /// Returns the value already reduced to the 16 bits the reply carries.
    pub(super) fn checksum_rect(&self, rect: Rect) -> u16 {
        // A degenerate rectangle checksums to zero rather than wrapping
        // around, matching xterm's `validRect` rejecting it outright.
        if rect.top > rect.bottom || rect.left > rect.right {
            return 0;
        }

        let mode = self.checksum_ext;
        let grid = self.active_grid();
        let trimming = mode & ext::NO_TRIM == 0;

        let mut total: i64 = 0;
        let mut trimmed: i64 = 0;
        let mut embedded: i64 = 0;
        // `first` spans the whole rectangle, not each row: the very first
        // counted cell is never trimmed, wherever it falls.
        let mut first = true;

        for row in rect.top..=rect.bottom {
            for col in rect.left..=rect.right {
                let Some(cell) = grid.get(row - 1, col - 1) else {
                    continue;
                };

                // NUL marks a cell nothing has written, which is xterm's
                // cleared CHARDRAWN. By default those are skipped entirely
                // rather than counted as spaces.
                let mut ch: i64 = if cell.char == '\0' {
                    if mode & (ext::NO_TRIM | ext::DRAWN) == 0 {
                        continue;
                    }
                    i64::from(' ' as u32)
                } else {
                    i64::from(cell.char as u32)
                };

                if mode & ext::NO_ATTRIBS == 0 {
                    if cell.protected {
                        ch += 0x4;
                    }
                    if cell.attrs.contains(CellAttrs::HIDDEN) {
                        ch += 0x8;
                    }
                    if cell.attrs.contains(CellAttrs::UNDERLINE) {
                        ch += 0x10;
                    }
                    if cell.attrs.contains(CellAttrs::REVERSE) {
                        ch += 0x20;
                    }
                    if cell.attrs.contains(CellAttrs::BLINK) {
                        ch += 0x40;
                    }
                    if cell.attrs.contains(CellAttrs::BOLD) {
                        ch += 0x80;
                    }
                }

                // The comparison is against the *adjusted* value, so a space
                // wearing an attribute is not a blank and survives trimming.
                if first || ch != i64::from(' ' as u32) {
                    trimmed += ch + embedded;
                    embedded = 0;
                } else if !trimming {
                    embedded += ch;
                }
                total += ch;
                first = !trimming;
            }

            if trimming {
                embedded = 0;
                first = false;
            }
        }

        if trimming {
            total = trimmed;
        }
        if mode & ext::POSITIVE == 0 {
            total = -total;
        }

        (total & 0xffff) as u16
    }

    /// Answers DECRQCRA. `params` is the full parameter list, starting with
    /// the request id and the page number.
    pub(super) fn report_checksum(&mut self, params: &[u16]) {
        let id = params.first().copied().unwrap_or(0);
        // Pid and Pg are consumed here; the rectangle starts at Pt.
        let rect = self.parse_rect(params.get(2..).unwrap_or(&[]));
        let sum = self.checksum_rect(rect);
        self.response
            .push_str(&format!("\x1bP{id}!~{sum:04X}\x1b\\"));
    }
}
