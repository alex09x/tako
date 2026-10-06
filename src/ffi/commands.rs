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
use super::event_types::FfiContextFrame;
use super::query_types::{FfiCommandInfo, FfiCommandMark, FfiCommandOutput, command_output_record};
use super::types::FfiTerminalModes;
use crate::terminal::ScreenBuffer;

#[uniffi::export]
impl TakoCore {
    /// Give command `id` its start time in unix milliseconds.
    pub fn set_command_time(&self, epoch: u64, id: u64, unix_ms: u64) -> bool {
        let mut engine = lock_recover(&self.inner);
        engine.epoch == epoch && engine.terminal.set_command_started_at(id, unix_ms)
    }

    /// The current engine generation. Bumped by every checkpoint import.
    pub fn state_epoch(&self) -> u64 {
        lock_recover(&self.inner).epoch
    }

    /// Returns the current context frames in stack order.
    pub fn context_stack(&self) -> Vec<FfiContextFrame> {
        lock_recover(&self.inner)
            .context_stack()
            .iter()
            .cloned()
            .map(Into::into)
            .collect()
    }

    /// Whether any frame in the context stack represents an elevated context.
    pub fn is_elevated(&self) -> bool {
        lock_recover(&self.inner).is_elevated()
    }

    /// Returns the active tint color hex/string, if any.
    pub fn active_tint(&self) -> Option<String> {
        lock_recover(&self.inner).active_tint().map(String::from)
    }

    /// Current DEC private-mode state.
    pub fn modes(&self) -> FfiTerminalModes {
        let terminal = lock_recover(&self.inner);
        let modes = terminal.modes();
        FfiTerminalModes {
            autowrap: modes.autowrap,
            origin_mode: modes.origin_mode,
            cursor_key_app_mode: modes.cursor_key_app_mode,
            mouse_tracking: modes.mouse_tracking.into(),
            mouse_utf8: modes.mouse_utf8,
            mouse_sgr: modes.mouse_sgr,
            focus_events: modes.focus_events,
            bracketed_paste: modes.bracketed_paste,
            alternate_screen: terminal.active_screen() == ScreenBuffer::Alternate,
            alternate_scroll: modes.alternate_scroll,
        }
    }

    /// Whether a Synchronized Output frame (mode 2026) is currently open.
    pub fn is_synchronized_output_active(&self) -> bool {
        lock_recover(&self.inner).is_synchronized_output()
    }

    pub fn mouse_shift_capture(&self) -> Option<bool> {
        lock_recover(&self.inner).modes().shift_capture
    }

    /// Whether the cursor sits on an OSC 133 prompt row.
    pub fn cursor_is_at_prompt(&self) -> bool {
        lock_recover(&self.inner).cursor_is_at_prompt()
    }

    /// The OSC 133 semantic mark of `row`.
    pub fn row_semantic_prompt(&self, row: u32) -> u8 {
        use crate::grid::SemanticPrompt;
        match lock_recover(&self.inner)
            .active_grid()
            .row_semantic_prompt(row as usize)
        {
            SemanticPrompt::Unset => 0,
            SemanticPrompt::Prompt => 1,
            SemanticPrompt::PromptContinuation => 2,
        }
    }

    /// The OSC 133 semantic mark of retained line `row`.
    pub fn retained_semantic_prompt(&self, row: u64) -> u8 {
        use crate::grid::SemanticPrompt;
        match lock_recover(&self.inner)
            .active_grid()
            .retained_semantic_prompt(row as usize)
        {
            SemanticPrompt::Unset => 0,
            SemanticPrompt::Prompt => 1,
            SemanticPrompt::PromptContinuation => 2,
        }
    }

    /// Jumps the viewport up to the previous OSC 133 prompt mark.
    pub fn scroll_to_previous_prompt(&self) -> bool {
        lock_recover(&self.inner).scroll_to_previous_prompt()
    }

    /// Jumps the viewport down to the next OSC 133 prompt mark.
    pub fn scroll_to_next_prompt(&self) -> bool {
        lock_recover(&self.inner).scroll_to_next_prompt()
    }

    /// Selects the entire output of the current or previous command.
    pub fn select_command_output(&self) -> bool {
        lock_recover(&self.inner).select_command_output()
    }

    /// Returns command marks for all recorded commands whose prompt line is retained.
    pub fn command_marks(&self) -> Vec<FfiCommandMark> {
        let terminal = lock_recover(&self.inner);
        terminal
            .command_marks()
            .into_iter()
            .map(Into::into)
            .collect()
    }

    /// The absolute line index of the oldest retained line in the primary buffer.
    pub fn first_retained_line(&self) -> u64 {
        let terminal = lock_recover(&self.inner);
        terminal.first_retained_line()
    }

    /// The newest command the shell marked (OSC 133).
    pub fn last_command(&self, max_lines: u32, max_bytes: u32) -> Option<FfiCommandOutput> {
        let terminal = lock_recover(&self.inner);
        let (record, out) = terminal.last_command(max_lines as usize, max_bytes as usize)?;
        Some(command_output_record(&record, out, terminal.epoch))
    }

    /// The newest command record's id.
    pub fn newest_command_id(&self) -> Option<u64> {
        lock_recover(&self.inner)
            .commands()
            .records()
            .next_back()
            .map(|r| r.id)
    }

    /// The first command recorded after `after`.
    pub fn first_command_after(&self, after: u64) -> Option<FfiCommandInfo> {
        let terminal = lock_recover(&self.inner);
        terminal
            .commands()
            .records()
            .find(|r| r.id > after)
            .map(|r| FfiCommandInfo::new(r, terminal.epoch))
    }

    /// Command `id` of engine generation `epoch`.
    pub fn command_output(
        &self,
        id: u64,
        epoch: u64,
        max_lines: u32,
        max_bytes: u32,
    ) -> Option<FfiCommandOutput> {
        let terminal = lock_recover(&self.inner);
        if terminal.epoch != epoch {
            return None;
        }
        let (record, out) = terminal.command(id, max_lines as usize, max_bytes as usize)?;
        Some(command_output_record(&record, out, terminal.epoch))
    }
}
