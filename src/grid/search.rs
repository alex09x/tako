/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

//! Text search over a grid's retained lines: scrollback, then the screen.
//!
//! Lines are addressed absolutely: line `history_evicted()` is the oldest
//! retained one, and a line keeps its number while it scrolls from the
//! screen into scrollback, so a hit can be found again after more output.
//! Search runs over logical lines -- soft-wrapped rows joined -- and compares
//! whole grapheme clusters, composed and case-folded, so a hit's cells are
//! exactly the cells its text occupies, wide characters and combining marks
//! included.
//!
//! Every step is bounded: it reads at most `max_rows` rows and keeps at most
//! one hit more than asked for, because it runs with the terminal locked.
//! A step never splits a logical line that fits in a step: one that does not
//! fit in what is left of this step is left whole for the next. Only a
//! logical line longer than a whole step is searched in step-sized pieces,
//! and a match that straddles two of those pieces is not found.

use unicode_normalization::UnicodeNormalization;
use unicode_segmentation::UnicodeSegmentation;

use super::{Cell, Grid, RowOwner};

/// Clusters of context kept before and after a hit for showing it.
const CONTEXT_BEFORE: usize = 40;
const CONTEXT_AFTER: usize = 80;

/// One occurrence of the needle. Columns are cells and inclusive; a hit
/// that continues across a soft wrap ends on a later line than it starts.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SearchHit {
    pub start_line: u64,
    pub start_col: u32,
    pub end_line: u64,
    pub end_col: u32,
    /// Up to a few dozen characters of the line before the match.
    pub before: String,
    /// The text of the match as the terminal shows it.
    pub matched: String,
    /// Some of the line after the match, trailing blanks trimmed.
    pub after: String,
    /// The command whose output holds every row of the hit, if one does
    /// (see [`super::RowOwner`]).
    pub command: Option<u64>,
}

/// What one bounded step of a search found.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SearchChunk {
    /// Newest first.
    pub hits: Vec<SearchHit>,
    /// Where the next step continues (exclusive), or `None` when the oldest
    /// retained line has been searched.
    pub next_before: Option<u64>,
    /// The oldest retained line and one past the newest, when this ran.
    pub first_line: u64,
    pub end_line: u64,
    /// True only when a hit beyond `max_hits` was actually found.
    pub truncated: bool,
}

/// One cell of a logical line: what it shows, folded for comparison, and
/// where it is.
struct Piece {
    shown: String,
    folded: String,
    line: u64,
    col: u32,
}

/// Case-folded and composed (NFC), so `é` typed either way finds `é`
/// however the program wrote it.
fn fold(text: &str) -> String {
    text.nfc().collect::<String>().to_lowercase()
}

/// The needle as the clusters a match must consist of.
fn wanted(needle: &str) -> Vec<String> {
    let composed: String = needle.nfc().collect();
    composed.graphemes(true).map(fold).collect()
}

/// What `Grid::command_output` returns.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandOutput {
    pub text: String,
    pub lines: usize,
    /// The oldest returned line was cut at its front to fit.
    pub truncated: bool,
    /// The command printed more lines than returned.
    pub more: bool,
    /// Some of what it printed is not here: rows written over by something
    /// else, or the start of its output evicted from the history.
    pub incomplete: bool,
}

impl Grid {
    /// Row `index` of the retained lines (0 = oldest), and whether it
    /// continues the row before it.
    fn retained_row(&self, index: usize) -> (&[Cell], bool) {
        let sb = self.scrollback.len();
        if index < sb {
            let row = &self.scrollback[index];
            (row.cells.as_slice(), row.wrapped)
        } else {
            let r = index - sb;
            (self.row_slice(r), self.is_line_wrapped(r))
        }
    }

    /// What command `id` printed: the retained rows it owns, soft wraps
    /// rejoined into lines, trailing blanks dropped, oldest first -- the
    /// last `max_lines` of them, at most `max_bytes`.
    ///
    /// Read from the newest row back, and only as far as needed: it stops
    /// once it has more than it can return, or at a row of an older command
    /// or the oldest retained row. So the work is bounded by what is
    /// returned plus what later commands printed, not by the history.
    pub fn command_output(&self, id: u64, max_lines: usize, max_bytes: usize) -> CommandOutput {
        let mut lines: Vec<String> = Vec::new(); // newest first
        let mut rows: Vec<&[Cell]> = Vec::new(); // the line being read, newest row first
        let mut seen = false;
        let mut gaps = false;
        // Rows written over by something else, just below the row being read.
        let mut mixed_below = false;
        let mut stopped = false;
        let mut bytes = 0usize;
        let mut index = self.retained_rows();
        while index > 0 {
            index -= 1;
            match self.retained_owner(index) {
                RowOwner::Command(owner) if owner == id => {
                    // Its output went on below, into rows something else
                    // wrote over too.
                    gaps |= mixed_below;
                    mixed_below = false;
                    let (cells, wrapped) = self.retained_row(index);
                    rows.push(cells);
                    seen = true;
                    if !wrapped {
                        // The first row of a line: the line is whole.
                        let mut line = String::new();
                        for cells in rows.drain(..).rev() {
                            for cell in cells {
                                if !(cell.is_wide_spacer || cell.is_wide_spacer_head) {
                                    self.push_cell_text(&mut line, cell);
                                }
                            }
                        }
                        let trimmed = line.trim_end_matches(' ').len();
                        line.truncate(trimmed);
                        bytes += line.len() + 1;
                        lines.push(line);
                        if lines.len() > max_lines || bytes > max_bytes.saturating_add(1) {
                            stopped = true;
                            break;
                        }
                    }
                }
                // An older command's row: this one's output is all below.
                RowOwner::Command(owner) if owner < id => break,
                // Written over by something else: not this command's, and
                // what it held is not known.
                RowOwner::Mixed => {
                    gaps |= seen;
                    mixed_below = true;
                }
                _ => {
                    mixed_below = false;
                    // The prompt or command line above the output: done.
                    if seen && rows.is_empty() {
                        break;
                    }
                }
            }
        }
        // Reached the oldest row still inside the output: older rows of it
        // may have been evicted.
        let evicted = !stopped && seen && index == 0 && self.retained_owner(0) == RowOwner::Command(id)
            && self.first_retained_line() > 0;
        if !rows.is_empty() {
            gaps = true; // a wrapped line whose first row is gone
        }
        // Trailing blank lines are output's padding, not output.
        let mut newest = 0;
        while newest < lines.len() && lines[newest].is_empty() {
            newest += 1;
        }
        lines.drain(..newest);
        // Stopped early: there was more than was read.
        let mut more = stopped || lines.len() > max_lines;
        lines.truncate(max_lines);
        lines.reverse(); // oldest first
        // From the newest back, as many bytes as fit; the oldest kept line
        // may be cut at its front.
        let mut truncated = false;
        let mut budget = max_bytes;
        let mut start = lines.len();
        while start > 0 {
            let sep = usize::from(start < lines.len());
            let len = lines[start - 1].len() + sep;
            if len > budget {
                if budget > sep {
                    let line = &lines[start - 1];
                    let mut cut = line.len() - (budget - sep);
                    while !line.is_char_boundary(cut) {
                        cut += 1;
                    }
                    lines[start - 1] = line[cut..].to_string();
                    truncated = true;
                    start -= 1;
                }
                break;
            }
            budget -= len;
            start -= 1;
        }
        if start > 0 {
            more = true;
        }
        let kept = lines.split_off(start);
        CommandOutput { lines: kept.len(), text: kept.join("\n"), truncated, more, incomplete: gaps || evicted }
    }

    /// The command that owns every line in `[start, end]`, if one does.
    pub fn command_of_lines(&self, start: u64, end: u64) -> Option<u64> {
        let first = self.first_retained_line();
        if start < first || end >= self.end_retained_line() || end < start {
            return None;
        }
        let mut found = None;
        for line in start..=end {
            match self.retained_owner((line - first) as usize) {
                RowOwner::Command(id) if found.is_none_or(|f| f == id) => found = Some(id),
                _ => return None,
            }
        }
        found
    }

    /// The absolute number of the oldest retained line.
    pub fn first_retained_line(&self) -> u64 {
        self.history_evicted as u64
    }

    /// One past the absolute number of the newest line.
    pub fn end_retained_line(&self) -> u64 {
        self.first_retained_line() + self.retained_rows() as u64
    }

    /// The cells of rows `[lo, hi)` that have text of their own.
    fn pieces(&self, lo: u64, hi: u64) -> Vec<Piece> {
        let first = self.first_retained_line();
        let mut pieces = Vec::new();
        for line in lo..hi {
            let (cells, _) = self.retained_row((line - first) as usize);
            for (col, cell) in cells.iter().enumerate() {
                // The right half of a wide character, or the blank left at
                // the end of a row when one did not fit: no text of its own.
                if cell.is_wide_spacer || cell.is_wide_spacer_head {
                    continue;
                }
                let mut shown = String::new();
                self.push_cell_text(&mut shown, cell);
                pieces.push(Piece { folded: fold(&shown), shown, line, col: col as u32 });
            }
        }
        pieces
    }

    /// Whether the cell at `line`/`col` is the left half of a wide pair.
    fn wide_at(&self, line: u64, col: u32) -> bool {
        let row = self.retained_row((line - self.first_retained_line()) as usize).0;
        row.get(col as usize).is_some_and(|cell| self.cell_is_wide(cell))
    }

    /// Searches backwards from `before` (exclusive; `None` = the newest line)
    /// over at most `max_rows` rows, and stops at `max_hits`.
    pub fn search_chunk(
        &self,
        needle: &str,
        before: Option<u64>,
        max_rows: usize,
        max_hits: usize,
    ) -> SearchChunk {
        let first = self.first_retained_line();
        let end = self.end_retained_line();
        let mut chunk = SearchChunk {
            hits: Vec::new(),
            next_before: None,
            first_line: first,
            end_line: end,
            truncated: false,
        };
        let wanted = wanted(needle);
        if wanted.is_empty() || max_hits == 0 {
            return chunk;
        }

        let mut hi = before.map_or(end, |b| b.clamp(first, end));
        let step = max_rows.max(1) as u64;
        let mut budget = step;
        while hi > first && budget > 0 && chunk.hits.len() < max_hits {
            // The logical line that ends at `hi - 1`, or its last `step`
            // rows when it is longer than a whole step.
            let mut lo = hi - 1;
            while lo > first && hi - lo < step && self.retained_row((lo - first) as usize).1 {
                lo -= 1;
            }
            if hi - lo > budget && budget < step {
                // It fits a step, but not what is left of this one.
                break;
            }
            budget -= (hi - lo).min(budget);
            let room = max_hits - chunk.hits.len();
            let mut found = self.search_line(lo, hi, &wanted, room.saturating_add(1));
            if found.len() > room {
                found.truncate(room);
                chunk.hits.extend(found);
                chunk.truncated = true;
                return chunk;
            }
            chunk.hits.extend(found);
            hi = lo;
        }
        chunk.next_before = (hi > first).then_some(hi);
        chunk
    }

    /// Up to `limit` hits in rows `[lo, hi)`, newest (rightmost) first.
    fn search_line(&self, lo: u64, hi: u64, wanted: &[String], limit: usize) -> Vec<SearchHit> {
        let pieces = self.pieces(lo, hi);
        let n = wanted.len();
        let mut hits = Vec::new();
        if pieces.len() < n {
            return hits;
        }
        let text = |range: std::ops::Range<usize>| -> String {
            pieces[range].iter().map(|p| p.shown.as_str()).collect()
        };
        let mut i = pieces.len() - n;
        loop {
            if pieces[i..i + n].iter().zip(wanted).all(|(p, w)| &p.folded == w) {
                let start = &pieces[i];
                let last = &pieces[i + n - 1];
                hits.push(SearchHit {
                    start_line: start.line,
                    start_col: start.col,
                    end_line: last.line,
                    end_col: last.col + u32::from(self.wide_at(last.line, last.col)),
                    before: text(i.saturating_sub(CONTEXT_BEFORE)..i),
                    matched: text(i..i + n),
                    after: text(i + n..(i + n + CONTEXT_AFTER).min(pieces.len()))
                        .trim_end_matches(' ')
                        .to_string(),
                    command: self.command_of_lines(start.line, last.line),
                });
                if hits.len() == limit || i < n {
                    break;
                }
                i -= n;
            } else {
                if i == 0 {
                    break;
                }
                i -= 1;
            }
        }
        hits
    }

    /// Whether the cells of `hit` still show `needle`. Reads only the rows
    /// the hit covers. False when they were evicted or no longer match.
    pub fn search_hit_is_current(&self, needle: &str, hit: &SearchHit) -> bool {
        if hit.start_line < self.first_retained_line()
            || hit.end_line >= self.end_retained_line()
            || hit.end_line < hit.start_line
        {
            return false;
        }
        let wanted = wanted(needle);
        if wanted.is_empty() {
            return false;
        }
        // Every row boundary the hit crosses must still be a soft wrap: one
        // that became a real line break splits the text the hit was.
        let first = self.first_retained_line();
        if (hit.start_line + 1..=hit.end_line)
            .any(|line| !self.retained_row((line - first) as usize).1)
        {
            return false;
        }
        let pieces = self.pieces(hit.start_line, hit.end_line + 1);
        let Some(i) = pieces
            .iter()
            .position(|p| p.line == hit.start_line && p.col == hit.start_col)
        else {
            return false;
        };
        let Some(span) = pieces.get(i..i + wanted.len()) else {
            return false;
        };
        let last = &span[span.len() - 1];
        span.iter().zip(&wanted).all(|(p, w)| &p.folded == w)
            && last.line == hit.end_line
            && last.col + u32::from(self.wide_at(last.line, last.col)) == hit.end_col
    }
}
