/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use crate::grid::SearchHit;
use crate::terminal::checkpoint::CheckpointError;
use crate::terminal::commands::{CommandRecord, CommandStatus};
use crate::terminal::{CommandMark, CommandMarkStatus};

#[derive(uniffi::Record, Debug, Clone, PartialEq, Eq)]
pub struct FfiSearchHit {
    pub start_line: u64,
    pub start_col: u32,
    pub end_line: u64,
    pub end_col: u32,
    pub before: String,
    pub matched: String,
    pub after: String,
    pub command: Option<FfiCommandInfo>,
}

#[derive(uniffi::Record, Debug, Clone, PartialEq, Eq)]
pub struct FfiCommandInfo {
    pub id: u64,
    pub epoch: u64,
    pub running: bool,
    pub finished: bool,
    pub abandoned: bool,
    pub exit_code: Option<i32>,
    pub cwd: Option<String>,
    pub input: Option<String>,
    pub input_truncated: bool,
    pub started_at_ms: Option<u64>,
}

impl FfiCommandInfo {
    pub fn new(rec: &CommandRecord, epoch: u64) -> Self {
        Self {
            id: rec.id,
            epoch,
            running: rec.status == CommandStatus::Running,
            finished: matches!(rec.status, CommandStatus::Completed(_)),
            abandoned: rec.status == CommandStatus::Abandoned,
            exit_code: match rec.status {
                CommandStatus::Completed(code) => code,
                _ => None,
            },
            cwd: rec.cwd.clone(),
            input: rec.input.clone(),
            input_truncated: rec.input_truncated,
            started_at_ms: rec.started_at_ms,
        }
    }
}

#[derive(uniffi::Record, Debug, Clone, PartialEq, Eq)]
pub struct FfiCommandMark {
    pub command_id: u64,
    pub prompt_line: u64,
    pub retained_row: u64,
    pub status: u8,
    pub exit_code: Option<i32>,
}

impl From<CommandMark> for FfiCommandMark {
    fn from(m: CommandMark) -> Self {
        let (status, exit_code) = match m.status {
            CommandMarkStatus::Running => (0, None),
            CommandMarkStatus::Success => (1, Some(0)),
            CommandMarkStatus::Error(code) => (2, code),
        };
        Self {
            command_id: m.command_id,
            prompt_line: m.prompt_line,
            retained_row: m.retained_row as u64,
            status,
            exit_code,
        }
    }
}

impl From<SearchHit> for FfiSearchHit {
    fn from(h: SearchHit) -> Self {
        Self {
            start_line: h.start_line,
            start_col: h.start_col,
            end_line: h.end_line,
            end_col: h.end_col,
            before: h.before,
            matched: h.matched,
            after: h.after,
            command: None,
        }
    }
}

impl From<FfiSearchHit> for SearchHit {
    fn from(h: FfiSearchHit) -> Self {
        Self {
            start_line: h.start_line,
            start_col: h.start_col,
            end_line: h.end_line,
            end_col: h.end_col,
            before: h.before,
            matched: h.matched,
            after: h.after,
            command: None,
        }
    }
}

#[derive(uniffi::Record, Debug, Clone, PartialEq, Eq)]
pub struct FfiTextTail {
    pub text: String,
    pub lines: u32,
    pub truncated: bool,
    pub more: bool,
}

pub fn command_output_record(
    record: &CommandRecord,
    out: crate::grid::CommandOutput,
    epoch: u64,
) -> FfiCommandOutput {
    FfiCommandOutput {
        command: FfiCommandInfo::new(record, epoch),
        output: out.text,
        lines: out.lines as u32,
        truncated: out.truncated,
        more: out.more,
        incomplete: out.incomplete,
    }
}

#[derive(uniffi::Record, Debug, Clone, PartialEq, Eq)]
pub struct FfiCommandOutput {
    pub command: FfiCommandInfo,
    pub output: String,
    pub lines: u32,
    pub truncated: bool,
    pub more: bool,
    pub incomplete: bool,
}

#[derive(uniffi::Record, Debug, Clone, PartialEq, Eq)]
pub struct FfiSearchChunk {
    pub hits: Vec<FfiSearchHit>,
    pub next_before: Option<u64>,
    pub first_line: u64,
    pub end_line: u64,
    pub truncated: bool,
}

#[derive(uniffi::Record, Debug, Clone, Copy, PartialEq, Eq)]
pub struct FfiRetainedLines {
    pub first_line: u64,
    pub scrollback_len: u32,
}

#[derive(uniffi::Record, Debug, Clone, Copy, PartialEq, Eq)]
pub struct FfiCheckpointInfo {
    pub version: u32,
    pub flags: u32,
    pub cols: u32,
    pub rows: u32,
    pub payload_len: u32,
}

#[derive(Debug, thiserror::Error, uniffi::Error, PartialEq, Eq)]
pub enum TakoCheckpointError {
    #[error("null argument")]
    NullArgument,
    #[error("checkpoint is {size} bytes, limit is {limit}")]
    TooLarge { size: u64, limit: u64 },
    #[error("unsupported checkpoint version {version}")]
    UnsupportedVersion { version: u32 },
    #[error("corrupt checkpoint: {reason}")]
    Corrupt { reason: String },
}

impl From<CheckpointError> for TakoCheckpointError {
    fn from(err: CheckpointError) -> Self {
        match err {
            CheckpointError::UnsupportedVersion(version) => Self::UnsupportedVersion { version },
            CheckpointError::TooLarge { size, limit } => Self::TooLarge { size, limit },
            other => Self::Corrupt {
                reason: other.to_string(),
            },
        }
    }
}
