/*
 * tako — Compact terminal emulator engine
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use crate::grid::SemanticPrompt;

use super::super::events::{ContextFrame, TerminalEvent};
use super::super::state::Terminal;
use super::super::types::{ScreenBuffer, SemanticContent};

impl Terminal {
    pub(crate) fn handle_osc_133(&mut self, params: &[&[u8]]) {
        let arg = params.get(1).copied().unwrap_or(b"");
        let action = arg.first().copied().unwrap_or(0);
        let continuation = params
            .iter()
            .skip(1)
            .any(|p| p.windows(3).any(|w| w == b"k=c"));
        match action {
            b'A' | b'L' => {
                if self.cursor.col > 0 {
                    self.cursor.col = self.h_margins().0;
                    self.line_feed();
                }
                if action == b'A' {
                    if !continuation {
                        self.command_prompt_started();
                        self.events.push(TerminalEvent::PromptMark);
                    } else if self.last_prompt_line.is_none()
                        && self.active == ScreenBuffer::Primary
                    {
                        self.last_prompt_line = Some(self.cursor_absolute_line());
                    }
                    self.semantic_content = SemanticContent::Prompt;
                    let row = self.cursor.row;
                    let mark = if continuation {
                        SemanticPrompt::PromptContinuation
                    } else {
                        SemanticPrompt::Prompt
                    };
                    self.active_grid_mut().set_row_semantic_prompt(row, mark);
                }
            }
            b'P' => {
                let secondary = params
                    .iter()
                    .skip(1)
                    .any(|p| p.windows(3).any(|w| w == b"k=s"));
                if !secondary && !continuation {
                    self.command_prompt_started();
                    self.events.push(TerminalEvent::PromptMark);
                } else if self.last_prompt_line.is_none() && self.active == ScreenBuffer::Primary {
                    self.last_prompt_line = Some(self.cursor_absolute_line());
                }
                self.semantic_content = SemanticContent::Prompt;
                let row = self.cursor.row;
                let mark = if continuation {
                    SemanticPrompt::PromptContinuation
                } else {
                    SemanticPrompt::Prompt
                };
                self.active_grid_mut().set_row_semantic_prompt(row, mark);
            }
            b'B' => {
                self.semantic_content = SemanticContent::Input;
                if self.active == ScreenBuffer::Primary && self.input_start.is_none() {
                    self.input_start = Some((self.cursor_absolute_line(), self.cursor.col));
                }
            }
            b'C' => {
                self.semantic_content = SemanticContent::Output;
                let id = self.command_output_started();
                self.events.push(TerminalEvent::CommandStart { id });
                if self.cursor.col == 0 {
                    let row = self.cursor.row;
                    if matches!(
                        self.active_grid().row_semantic_prompt(row),
                        SemanticPrompt::Prompt | SemanticPrompt::PromptContinuation
                    ) {
                        self.active_grid_mut()
                            .set_row_semantic_prompt(row, SemanticPrompt::Unset);
                    }
                }
            }
            b'D' => {
                self.semantic_content = SemanticContent::None;
                let exit_code = params
                    .get(2)
                    .and_then(|p| std::str::from_utf8(p).ok())
                    .and_then(|s| s.trim().parse::<i32>().ok());
                if self.active == ScreenBuffer::Primary {
                    self.commands.finish(exit_code);
                    self.primary.set_pen_owner(None);
                }
                self.events.push(TerminalEvent::CommandEnd { exit_code });
            }
            _ => {}
        }
    }

    pub(crate) fn handle_osc_3008(&mut self, params: &[&[u8]]) {
        const MAX_CONTEXT_STACK_DEPTH: usize = 32;
        const MAX_CONTEXT_FIELD_LEN: usize = 128;
        if let Some(op_bytes) = params.get(1) {
            let op = String::from_utf8_lossy(op_bytes);
            let op_lower = op.trim().to_lowercase();
            match op_lower.as_str() {
                "push" | "enter" => {
                    let mut kind = params
                        .get(2)
                        .map(|p| String::from_utf8_lossy(p).trim().to_string())
                        .unwrap_or_default();
                    let mut name = params
                        .get(3)
                        .map(|p| String::from_utf8_lossy(p).trim().to_string())
                        .unwrap_or_default();
                    let mut explicit_tint = params
                        .get(4)
                        .map(|p| String::from_utf8_lossy(p).trim().to_string())
                        .filter(|s| !s.is_empty());
                    if kind.len() > MAX_CONTEXT_FIELD_LEN {
                        kind = kind.chars().take(MAX_CONTEXT_FIELD_LEN).collect();
                    }
                    if name.len() > MAX_CONTEXT_FIELD_LEN {
                        name = name.chars().take(MAX_CONTEXT_FIELD_LEN).collect();
                    }
                    if let Some(t) = explicit_tint.as_mut()
                        && t.len() > MAX_CONTEXT_FIELD_LEN
                    {
                        *t = t.chars().take(MAX_CONTEXT_FIELD_LEN).collect();
                    }
                    let is_elevated = kind.eq_ignore_ascii_case("sudo")
                        || kind.eq_ignore_ascii_case("elevated")
                        || kind.eq_ignore_ascii_case("root")
                        || kind.eq_ignore_ascii_case("su")
                        || name.eq_ignore_ascii_case("root");
                    let tint = explicit_tint.or_else(|| {
                        if is_elevated {
                            Some("#ea580c".to_string())
                        } else {
                            None
                        }
                    });
                    let frame = ContextFrame {
                        kind,
                        name,
                        tint,
                        is_elevated,
                    };
                    if self.context_stack.len() >= MAX_CONTEXT_STACK_DEPTH {
                        if let Some(idx) = self.context_stack.iter().position(|f| !f.is_elevated) {
                            self.context_stack.remove(idx);
                        } else {
                            self.evicted_elevated += 1;
                            self.context_stack.remove(0);
                        }
                    }
                    self.context_stack.push(frame.clone());
                    self.events.push(TerminalEvent::ContextPush(frame));
                }
                "pop" | "exit" => {
                    if self.context_stack.pop().is_some() {
                        self.events.push(TerminalEvent::ContextPop);
                    } else if self.evicted_elevated > 0 {
                        self.evicted_elevated -= 1;
                        self.events.push(TerminalEvent::ContextPop);
                    }
                }
                "clear" | "reset" => {
                    if !self.context_stack.is_empty() || self.evicted_elevated > 0 {
                        self.context_stack.clear();
                        self.evicted_elevated = 0;
                        self.events.push(TerminalEvent::ContextClear);
                    }
                }
                "set" => {
                    if !self.context_stack.is_empty() || self.evicted_elevated > 0 {
                        self.context_stack.clear();
                        self.evicted_elevated = 0;
                        self.events.push(TerminalEvent::ContextClear);
                    }
                    if params.len() > 2 {
                        let mut kind = params
                            .get(2)
                            .map(|p| String::from_utf8_lossy(p).trim().to_string())
                            .unwrap_or_default();
                        let mut name = params
                            .get(3)
                            .map(|p| String::from_utf8_lossy(p).trim().to_string())
                            .unwrap_or_default();
                        let mut explicit_tint = params
                            .get(4)
                            .map(|p| String::from_utf8_lossy(p).trim().to_string())
                            .filter(|s| !s.is_empty());
                        if kind.len() > MAX_CONTEXT_FIELD_LEN {
                            kind = kind.chars().take(MAX_CONTEXT_FIELD_LEN).collect();
                        }
                        if name.len() > MAX_CONTEXT_FIELD_LEN {
                            name = name.chars().take(MAX_CONTEXT_FIELD_LEN).collect();
                        }
                        if let Some(t) = explicit_tint.as_mut()
                            && t.len() > MAX_CONTEXT_FIELD_LEN
                        {
                            *t = t.chars().take(MAX_CONTEXT_FIELD_LEN).collect();
                        }
                        let is_elevated = kind.eq_ignore_ascii_case("sudo")
                            || kind.eq_ignore_ascii_case("elevated")
                            || kind.eq_ignore_ascii_case("root")
                            || kind.eq_ignore_ascii_case("su")
                            || name.eq_ignore_ascii_case("root");
                        let tint = explicit_tint.or_else(|| {
                            if is_elevated {
                                Some("#ea580c".to_string())
                            } else {
                                None
                            }
                        });
                        let frame = ContextFrame {
                            kind,
                            name,
                            tint,
                            is_elevated,
                        };
                        self.context_stack.push(frame.clone());
                        self.events.push(TerminalEvent::ContextPush(frame));
                    }
                }
                _ => {}
            }
        }
    }
}
