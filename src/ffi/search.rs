/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::core::{TakoCore, lock_recover};
use super::query_types::{FfiCommandInfo, FfiRetainedLines, FfiSearchChunk, FfiSearchHit};
use super::types::FfiSelectionMode;

#[uniffi::export]
impl TakoCore {
    /// Whole logical lines, whole grapheme clusters, case-insensitive.
    pub fn search_chunk(
        &self,
        needle: String,
        before: Option<u64>,
        max_rows: u32,
        max_hits: u32,
    ) -> FfiSearchChunk {
        let terminal = lock_recover(&self.inner);
        let chunk = terminal.active_grid().search_chunk(
            &needle,
            before,
            max_rows as usize,
            max_hits as usize,
        );
        let log = (terminal.active_screen() == crate::terminal::ScreenBuffer::Primary)
            .then(|| terminal.commands());
        let epoch = terminal.epoch;
        FfiSearchChunk {
            hits: chunk
                .hits
                .into_iter()
                .map(|hit| {
                    let command = hit
                        .command
                        .and_then(|id| log.and_then(|log| log.get(id)))
                        .map(|rec| FfiCommandInfo::new(rec, epoch));
                    FfiSearchHit {
                        command,
                        ..FfiSearchHit::from(hit)
                    }
                })
                .collect(),
            next_before: chunk.next_before,
            first_line: chunk.first_line,
            end_line: chunk.end_line,
            truncated: chunk.truncated,
        }
    }

    /// Whether `hit` is still where it was found, with the same text.
    pub fn search_hit_is_current(&self, needle: String, hit: FfiSearchHit) -> bool {
        lock_recover(&self.inner)
            .active_grid()
            .search_hit_is_current(&needle, &hit.into())
    }

    /// Checks `hit` and selects it, scrolling it into view.
    pub fn select_search_hit(&self, needle: String, hit: FfiSearchHit) -> bool {
        let mut term = lock_recover(&self.inner);
        let hit: crate::grid::SearchHit = hit.into();
        if !term.active_grid().search_hit_is_current(&needle, &hit) {
            return false;
        }
        let grid = term.active_grid();
        let first = grid.first_retained_line();
        let scrollback = grid.scrollback_len() as u64;
        let rows = grid.rows() as u64;
        let start = hit.start_line - first;
        let end = hit.end_line - first;
        let mut top = scrollback - term.viewport_offset() as u64;
        if start < top || end >= top + rows {
            top = start.saturating_sub(rows / 3).min(scrollback);
            term.scroll_viewport_bottom();
            let offset = (scrollback - top) as usize;
            if offset > 0 {
                term.scroll_viewport_up(offset);
            }
        }
        let (start_row, end_row) = ((start - top) as usize, (end - top) as usize);
        term.start_selection(
            start_row,
            hit.start_col as usize,
            FfiSelectionMode::Linear.into(),
        );
        term.extend_selection(end_row, hit.end_col as usize);
        true
    }

    /// Oldest retained line and scrollback length.
    pub fn search_first_line(&self) -> FfiRetainedLines {
        let terminal = lock_recover(&self.inner);
        let grid = terminal.active_grid();
        FfiRetainedLines {
            first_line: grid.first_retained_line(),
            scrollback_len: grid.scrollback_len() as u32,
        }
    }
}
