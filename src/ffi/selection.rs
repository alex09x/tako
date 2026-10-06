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
use super::types::{FfiSelectionMode, FfiSelectionRange};

#[uniffi::export]
impl TakoCore {
    /// Begins a new selection at `(row, col)` in the given mode.
    pub fn start_selection(&self, row: u32, col: u32, mode: FfiSelectionMode) {
        lock_recover(&self.inner).start_selection(row as usize, col as usize, mode.into());
    }

    /// Updates the drag endpoint of the current selection.
    pub fn extend_selection(&self, row: u32, col: u32) {
        lock_recover(&self.inner).extend_selection(row as usize, col as usize);
    }

    /// Selects the word under `(row, col)`.
    pub fn select_word(&self, row: u32, col: u32) {
        lock_recover(&self.inner).select_word(row as usize, col as usize);
    }

    /// Selects the whole logical line under `(row, col)`.
    pub fn select_line(&self, row: u32, col: u32) {
        lock_recover(&self.inner).select_line(row as usize, col as usize);
    }

    /// Discards the current selection, if any.
    pub fn clear_selection(&self) {
        lock_recover(&self.inner).clear_selection();
    }

    /// Whether a selection is currently active.
    pub fn has_selection(&self) -> bool {
        lock_recover(&self.inner).has_selection()
    }

    /// The normalized bounds of the current selection, for highlighting.
    pub fn selection_range(&self) -> Option<FfiSelectionRange> {
        let term = lock_recover(&self.inner);
        let mode = term.selection_mode().into();
        let ((start_row, start_col), (end_row, end_col)) = term.selection_range()?;
        Some(FfiSelectionRange {
            start_row: start_row as u32,
            start_col: start_col as u32,
            end_row: end_row as u32,
            end_col: end_col as u32,
            mode,
        })
    }

    /// The plain text covered by the current selection.
    pub fn selected_text(&self) -> Option<String> {
        lock_recover(&self.inner).selected_text()
    }
}
