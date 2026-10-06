/*
 * Tako — Terminal Emulation Engine
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use crate::grid::{RowOwner, SemanticPrompt};

use super::commands::CommandStatus;
use super::state::Terminal;
use super::types::{
    CommandMarkStatus, ScreenBuffer, Selection, SelectionMode, StickyCommandHeader,
};

impl Terminal {
    /// Returns the sticky command header for the currently visible viewport, if any.
    pub fn sticky_command_header(&self) -> Option<StickyCommandHeader> {
        if self.active == ScreenBuffer::Alternate {
            return None;
        }

        let total_retained = self.primary.retained_rows();
        if total_retained == 0 {
            return None;
        }

        let sb_len = self.primary.scrollback_len();
        let vp_top = sb_len.saturating_sub(self.viewport_offset);
        if vp_top >= total_retained {
            return None;
        }

        let mut candidate_id = match self.primary.retained_owner(vp_top) {
            RowOwner::Command(id) => Some(id),
            _ => {
                let mut found = None;
                for r in (0..vp_top).rev() {
                    if let RowOwner::Command(id) = self.primary.retained_owner(r) {
                        found = Some(id);
                        break;
                    }
                }
                found
            }
        };

        if candidate_id.is_none() {
            candidate_id = self.commands.running();
        }

        let cmd_id = candidate_id?;
        let rec = self.commands.get(cmd_id)?;
        let command_text = rec.input.as_ref()?.trim();
        if command_text.is_empty() {
            return None;
        }

        let first = self.primary.first_retained_line();
        let prompt_retained_row = match rec.prompt_line {
            Some(prompt_line) if prompt_line >= first => {
                let r = (prompt_line - first) as usize;
                if r < total_retained { Some(r) } else { None }
            }
            _ => None,
        };

        if prompt_retained_row.is_some_and(|p_row| p_row >= vp_top) {
            return None;
        }

        let mut max_r = None;
        for r in 0..total_retained {
            if self.primary.retained_owner(r) == RowOwner::Command(cmd_id) {
                max_r = Some(r);
            }
        }

        let last_output_row = match rec.status {
            CommandStatus::Running => {
                (sb_len + self.cursor.row).min(total_retained.saturating_sub(1))
            }
            _ => max_r?,
        };

        if vp_top > last_output_row {
            return None;
        }

        let p_row = prompt_retained_row.unwrap_or(0);
        let p_line = rec.prompt_line.unwrap_or(first);

        let status = match rec.status {
            CommandStatus::Running => CommandMarkStatus::Running,
            CommandStatus::Completed(Some(0)) => CommandMarkStatus::Success,
            CommandStatus::Completed(code) => CommandMarkStatus::Error(code),
            CommandStatus::Abandoned => CommandMarkStatus::Error(None),
        };

        Some(StickyCommandHeader {
            command_id: cmd_id,
            command: command_text.to_string(),
            prompt_line: p_line,
            prompt_retained_row: p_row,
            status,
        })
    }

    /// Jumps the viewport to make the prompt at `prompt_retained_row` visible at the top.
    pub fn scroll_to_prompt(&mut self, prompt_retained_row: usize) -> bool {
        if self.active == ScreenBuffer::Alternate {
            return false;
        }
        let total_retained = self.primary.retained_rows();
        if prompt_retained_row >= total_retained {
            return false;
        }
        let sb_len = self.primary.scrollback_len();
        let target_offset = sb_len.saturating_sub(prompt_retained_row);
        if self.viewport_offset == target_offset {
            return false;
        }
        self.viewport_offset = target_offset;
        self.primary.mark_all_dirty();
        true
    }

    /// Jumps the viewport up to the previous OSC 133 prompt mark.
    pub fn scroll_to_previous_prompt(&mut self) -> bool {
        if self.active == ScreenBuffer::Alternate {
            return false;
        }
        let sb_len = self.primary.scrollback_len();
        let current_top = sb_len.saturating_sub(self.viewport_offset);
        if current_top == 0 {
            return false;
        }
        for i in (0..current_top).rev() {
            if self.primary.retained_semantic_prompt(i) == SemanticPrompt::Prompt {
                self.viewport_offset = sb_len.saturating_sub(i);
                self.primary.mark_all_dirty();
                return true;
            }
        }
        false
    }

    /// Jumps the viewport down to the next OSC 133 prompt mark.
    pub fn scroll_to_next_prompt(&mut self) -> bool {
        if self.active == ScreenBuffer::Alternate || self.viewport_offset == 0 {
            return false;
        }
        let sb_len = self.primary.scrollback_len();
        let current_top = sb_len.saturating_sub(self.viewport_offset);
        let total_retained = self.primary.retained_rows();
        for i in (current_top + 1)..total_retained {
            if self.primary.retained_semantic_prompt(i) == SemanticPrompt::Prompt {
                if i < sb_len {
                    self.viewport_offset = sb_len - i;
                } else {
                    self.viewport_offset = 0;
                }
                self.primary.mark_all_dirty();
                return true;
            }
        }
        false
    }

    /// Select the entire output of the current or previous command cleanly bounded
    /// by OSC 133 prompt marks.
    pub fn select_command_output(&mut self) -> bool {
        if self.active == ScreenBuffer::Alternate {
            return false;
        }

        let total_retained = self.primary.retained_rows();
        let cols = self.primary.cols();
        if total_retained == 0 || cols == 0 {
            return false;
        }

        let sb_len = self.primary.scrollback_len();
        let vp_top = sb_len.saturating_sub(self.viewport_offset);
        let vp_bottom = (vp_top + self.primary.rows()).min(total_retained);

        let mut target_cmd_id = None;
        let mut target_row = None;
        if let Some(running_id) = self.commands.running() {
            target_cmd_id = Some(running_id);
            target_row = Some((sb_len + self.cursor.row).min(total_retained.saturating_sub(1)));
        } else if self.viewport_offset > 0 {
            for r in (vp_top..vp_bottom).rev() {
                if let RowOwner::Command(id) = self.primary.retained_owner(r) {
                    target_cmd_id = Some(id);
                    target_row = Some(r);
                    break;
                }
            }
        }

        if target_cmd_id.is_none() {
            target_cmd_id = self
                .commands
                .records()
                .rev()
                .find(|r| !matches!(r.status, CommandStatus::Abandoned))
                .map(|r| r.id);
            target_row = Some((sb_len + self.cursor.row).min(total_retained.saturating_sub(1)));
        }

        let mut output_start = None;
        let mut output_end = None;

        if let Some(id) = target_cmd_id {
            let mut runs: Vec<(usize, usize)> = Vec::new();
            let mut current_run: Option<(usize, usize)> = None;

            for r in 0..total_retained {
                if self.primary.retained_owner(r) == RowOwner::Command(id) {
                    match current_run {
                        Some((start, _)) => current_run = Some((start, r)),
                        None => current_run = Some((r, r)),
                    }
                } else if let Some(run) = current_run.take() {
                    runs.push(run);
                }
            }
            if let Some(run) = current_run {
                runs.push(run);
            }

            if !runs.is_empty() {
                let selected_run = if let Some(focal) = target_row {
                    if let Some(&run) = runs.iter().find(|(s, e)| *s <= focal && focal <= *e) {
                        Some(run)
                    } else {
                        runs.iter()
                            .rev()
                            .find(|(_, e)| *e <= focal)
                            .copied()
                            .or_else(|| runs.first().copied())
                    }
                } else {
                    runs.last().copied()
                };

                if let Some((start, end)) = selected_run {
                    output_start = Some(start);
                    output_end = Some(end);
                }
            }
        }

        if output_start.is_none() {
            let search_from = if self.viewport_offset == 0 {
                sb_len + self.cursor.row
            } else {
                vp_bottom.min(total_retained)
            };

            let mut prompt_row = None;
            for r in (0..search_from).rev() {
                if self.primary.retained_semantic_prompt(r) == SemanticPrompt::Prompt {
                    prompt_row = Some(r);
                    break;
                }
            }

            if let Some(p_row) = prompt_row {
                let mut start_candidate = p_row + 1;
                while start_candidate < total_retained
                    && self.primary.retained_semantic_prompt(start_candidate)
                        == SemanticPrompt::PromptContinuation
                {
                    start_candidate += 1;
                }

                let mut next_prompt_row = None;
                for r in start_candidate..total_retained {
                    if self.primary.retained_semantic_prompt(r) == SemanticPrompt::Prompt {
                        next_prompt_row = Some(r);
                        break;
                    }
                }

                let end_bound = next_prompt_row.unwrap_or(total_retained);
                let mut end_candidate = end_bound.saturating_sub(1);
                while end_candidate >= start_candidate
                    && self.primary.retained_owner(end_candidate) == RowOwner::Empty
                {
                    if end_candidate == 0 {
                        break;
                    }
                    end_candidate -= 1;
                }

                if start_candidate <= end_candidate
                    && self.primary.retained_owner(end_candidate) != RowOwner::Empty
                {
                    output_start = Some(start_candidate);
                    output_end = Some(end_candidate);
                }
            }
        }

        let (first_row, last_row) = match (output_start, output_end) {
            (Some(s), Some(e)) if s <= e => (s, e),
            _ => return false,
        };

        let evicted = self.primary.history_evicted();
        let anchor = (evicted + first_row, 0);
        let active = (evicted + last_row, cols.saturating_sub(1));
        self.selection = Some(Selection {
            anchor,
            active,
            mode: SelectionMode::Linear,
        });

        if last_row < vp_top {
            self.viewport_offset = sb_len.saturating_sub(first_row);
        }

        self.primary.mark_all_dirty();
        true
    }
}
