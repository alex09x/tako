/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::{Cell, Grid, RowOwner};

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
        let evicted = !stopped
            && seen
            && index == 0
            && self.retained_owner(0) == RowOwner::Command(id)
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
        CommandOutput {
            lines: kept.len(),
            text: kept.join("\n"),
            truncated,
            more,
            incomplete: gaps || evicted,
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
}
