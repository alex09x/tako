/*
 * Tako — Terminal Emulation Engine
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use crate::grid::{CommandOutput, SemanticPrompt};

use super::commands::{CommandLog, CommandRecord, CommandStatus, MAX_INPUT_CHARS};
use super::events::TerminalEvent;
use super::state::Terminal;
use super::types::{CommandMark, CommandMarkStatus, ScreenBuffer};

impl Terminal {
    pub(crate) fn cursor_absolute_line(&self) -> u64 {
        let grid = self.active_grid();
        (grid.history_evicted() + grid.scrollback_len() + self.cursor.row) as u64
    }

    /// `133;A`/`P`: a new prompt. A command still running never got its
    /// `D`; what follows is not its output.
    pub(crate) fn command_prompt_started(&mut self) {
        self.input_start = None;
        if self.active == ScreenBuffer::Primary {
            if self.commands.running().is_some() {
                self.commands.abandon_running();
                self.events
                    .push(TerminalEvent::CommandEnd { exit_code: None });
            }
            self.primary.set_pen_owner(None);
            self.last_prompt_line = Some(self.cursor_absolute_line());
        }
    }

    /// `133;C`: open a record and claim what is written from here on for
    /// it. `None` on the alternate screen or once ids ran out.
    pub(crate) fn command_output_started(&mut self) -> Option<u64> {
        if self.active != ScreenBuffer::Primary {
            return None;
        }
        let (input, truncated) = match self.input_start.take() {
            Some(start) => self.command_line_text(start),
            None => (None, false),
        };
        let prompt_line = self.last_prompt_line.take();
        let id = self
            .commands
            .start(self.last_cwd.clone(), input, truncated, prompt_line);
        self.primary.set_pen_owner(id);
        id
    }

    /// The text from `start` up to the cursor: the command line just
    /// entered. `None` when its first line was evicted or nothing is there.
    pub(crate) fn command_line_text(&self, start: (u64, usize)) -> (Option<String>, bool) {
        let grid = &self.primary;
        let first = grid.history_evicted() as u64;
        let history = grid.scrollback_len() as u64;
        let (start_line, start_col) = start;
        let end_line = self.cursor_absolute_line();
        if start_line < first || start_line > end_line {
            return (None, false);
        }
        let mut text = String::new();
        let mut count = 0usize;
        let mut truncated = false;
        'lines: for line in start_line..=end_line {
            let index = line - first;
            let (cells, wrapped) = if index < history {
                let i = (history - 1 - index) as usize;
                match grid.scrollback_line(i) {
                    Some(cells) => (cells, grid.scrollback_line_wrapped(i)),
                    None => break,
                }
            } else {
                let row = (index - history) as usize;
                (grid.row_cells(row), grid.is_line_wrapped(row))
            };
            if line > start_line && !wrapped {
                text.truncate(text.trim_end_matches(' ').len());
                count = text.chars().count();
                if count == MAX_INPUT_CHARS {
                    truncated = true;
                    break;
                }
                text.push('\n');
                count += 1;
            }
            let from = if line == start_line {
                start_col.min(cells.len())
            } else {
                0
            };
            let to = if line == end_line {
                self.cursor.col.min(cells.len())
            } else {
                cells.len()
            };
            for cell in cells.get(from..to.max(from)).unwrap_or(&[]) {
                if cell.is_wide_spacer || cell.is_wide_spacer_head {
                    continue;
                }
                if count == MAX_INPUT_CHARS {
                    truncated = true;
                    break 'lines;
                }
                let before = text.len();
                grid.push_cell_text(&mut text, cell);
                count += text[before..].chars().count();
                if count > MAX_INPUT_CHARS {
                    text.truncate(before);
                    truncated = true;
                    break 'lines;
                }
            }
        }
        let trimmed = text.trim_end();
        if trimmed.is_empty() {
            return (None, false);
        }
        (Some(trimmed.to_string()), truncated)
    }

    /// The commands recorded on the primary screen.
    pub fn commands(&self) -> &CommandLog {
        &self.commands
    }

    /// The newest command the shell marked that was not abandoned --
    /// running or finished -- with what it printed on the primary screen
    /// (see `Grid::command_output`).
    pub fn last_command(
        &self,
        max_lines: usize,
        max_bytes: usize,
    ) -> Option<(CommandRecord, CommandOutput)> {
        let record = self
            .commands
            .records()
            .rev()
            .find(|r| r.status != CommandStatus::Abandoned)?
            .clone();
        let output = self.primary.command_output(record.id, max_lines, max_bytes);
        Some((record, output))
    }

    /// Command `id` and what it printed, while its record is kept.
    pub fn command(
        &self,
        id: u64,
        max_lines: usize,
        max_bytes: usize,
    ) -> Option<(CommandRecord, CommandOutput)> {
        let record = self.commands.get(id)?.clone();
        let output = self.primary.command_output(id, max_lines, max_bytes);
        Some((record, output))
    }

    /// Give command `id` its start time (unix ms), once.
    pub fn set_command_started_at(&mut self, id: u64, unix_ms: u64) -> bool {
        self.commands.set_started_at(id, unix_ms)
    }

    /// Returns marks for all recorded commands whose prompt line is currently retained
    /// in the primary buffer (scrollback or live screen).
    pub fn command_marks(&self) -> Vec<CommandMark> {
        if self.active == ScreenBuffer::Alternate {
            return Vec::new();
        }
        let grid = &self.primary;
        let first = grid.first_retained_line();
        let end = grid.end_retained_line();
        let total_retained = grid.retained_rows();
        let mut marks = Vec::new();

        for rec in self.commands.records() {
            let Some(prompt_line) = rec.prompt_line else {
                continue;
            };
            if prompt_line < first || prompt_line >= end {
                continue;
            }
            let mut retained_row = (prompt_line - first) as usize;
            if retained_row >= total_retained {
                continue;
            }

            if grid.retained_semantic_prompt(retained_row) != SemanticPrompt::Prompt {
                let min_r = retained_row.saturating_sub(1);
                let max_r = (retained_row + 1).min(total_retained.saturating_sub(1));
                if let Some(r) = (min_r..=max_r)
                    .find(|&r| grid.retained_semantic_prompt(r) == SemanticPrompt::Prompt)
                {
                    retained_row = r;
                } else {
                    continue;
                }
            }

            let status = match rec.status {
                CommandStatus::Running => CommandMarkStatus::Running,
                CommandStatus::Completed(Some(0)) => CommandMarkStatus::Success,
                CommandStatus::Completed(code) => CommandMarkStatus::Error(code),
                CommandStatus::Abandoned => CommandMarkStatus::Error(None),
            };

            marks.push(CommandMark {
                command_id: rec.id,
                prompt_line,
                retained_row,
                status,
            });
        }
        marks
    }

    /// The absolute line index of the oldest retained line in the primary buffer.
    pub fn first_retained_line(&self) -> u64 {
        self.primary.first_retained_line()
    }
}
