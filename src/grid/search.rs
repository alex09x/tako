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

impl Grid {
    fn retained_rows(&self) -> usize {
        self.scrollback.len() + self.rows
    }

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

    fn retained_owner(&self, index: usize) -> RowOwner {
        let sb = self.scrollback.len();
        if index < sb {
            self.scrollback[index].owner
        } else {
            self.row_owner(index - sb)
        }
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
