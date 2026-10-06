/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::grid::{owner_tag, read_opt_string, read_opt_u64, write_opt_string, write_opt_u64};
use super::reader::Reader;
use super::types::{COMMAND_RECORD_SPINE, CheckpointError, OWNER_RUN_SPINE};
use super::writer::Writer;
use crate::grid::{Grid, RowOwner};
use crate::terminal::Terminal;
use crate::terminal::commands::{
    CommandLog, CommandRecord, CommandStatus, MAX_COMMAND_RECORDS, MAX_CWD_BYTES,
};

/// What v4 writes about commands: the owner runs, and only the records some
/// retained row still names (or the running one). The exporter and the cost
/// estimate both read it, so they cannot disagree.
pub(crate) struct CommandBlock<'a> {
    pub(crate) runs: Vec<(RowOwner, u32)>,
    pub(crate) records: Vec<&'a CommandRecord>,
}

impl<'a> CommandBlock<'a> {
    pub(crate) fn of(term: &'a Terminal) -> Self {
        let grid = &term.primary;
        let log = &term.commands;
        let owners = (0..grid.scrollback_len())
            .map(|i| grid.scrollback_owner(i))
            .chain((0..grid.rows()).map(|r| grid.row_owner(r)));
        let mut runs: Vec<(RowOwner, u32)> = Vec::new();
        for owner in owners {
            match runs.last_mut() {
                Some((last, n)) if *last == owner => *n += 1,
                _ => runs.push((owner, 1)),
            }
        }
        let records = log.records().collect();
        Self { runs, records }
    }
}

/// v4's tail: row owners of the primary grid as runs, then the command
/// table. An owner naming a record the table no longer has is written as
/// unowned -- it would group nothing anyway.
pub(crate) fn write_commands(w: &mut Writer, term: &Terminal, version: u32) {
    let grid = &term.primary;
    let log = &term.commands;
    let block = CommandBlock::of(term);
    w.write_u32(block.runs.len() as u32);
    for &(owner, n) in &block.runs {
        let (tag, id) = owner_tag(owner);
        w.write_u8(tag);
        w.write_u64(id);
        w.write_u32(n);
    }
    let pen = grid.pen_owner().filter(|id| log.get(*id).is_some());
    write_opt_u64(w, pen);
    write_opt_u64(w, log.next_id());
    write_opt_u64(w, log.running());
    w.write_u32(block.records.len() as u32);
    for rec in &block.records {
        w.write_u64(rec.id);
        let (status, code) = match rec.status {
            CommandStatus::Running => (0, 0),
            CommandStatus::Completed(None) => (1, 0),
            CommandStatus::Completed(Some(code)) => (2, code),
            CommandStatus::Abandoned => (3, 0),
        };
        w.write_u8(status);
        w.write_u32(code as u32);
        write_opt_string(w, rec.cwd.as_deref());
        write_opt_string(w, rec.input.as_deref());
        w.write_bool(rec.input_truncated);
        write_opt_u64(w, rec.started_at_ms);
        if version >= 6 {
            write_opt_u64(w, rec.prompt_line);
        }
    }
    write_opt_string(w, term.last_cwd.as_deref());
    write_opt_u64(w, term.input_start.map(|(line, _)| line));
    w.write_u32(term.input_start.map_or(0, |(_, col)| col as u32));
    if version >= 6 {
        write_opt_u64(w, term.last_prompt_line);
    }
}

/// What [`read_commands`] decoded, checked against itself and the grid.
pub(crate) struct CommandState {
    pub(crate) log: CommandLog,
    pub(crate) last_cwd: Option<String>,
    pub(crate) input_start: Option<(u64, usize)>,
    pub(crate) last_prompt_line: Option<u64>,
}

/// [`write_commands`]' block. The runs must cover the grid's retained rows
/// exactly; every owner must name a record; the pen must be the running
/// command. Anything else is corrupt.
pub(crate) fn read_commands(
    r: &mut Reader<'_>,
    grid: &mut Grid,
    written_history: usize,
    version: u32,
) -> Result<CommandState, CheckpointError> {
    let bad = CheckpointError::InvalidData;
    let run_count = r.read_u32()? as usize;
    // tag, id, length: 13 bytes each.
    r.check_count(run_count, 13)?;
    let total = written_history + grid.rows();
    r.charge_spine(run_count, OWNER_RUN_SPINE)?;
    let mut runs = Vec::with_capacity(run_count.min(total));
    let mut covered = 0usize;
    for _ in 0..run_count {
        let tag = r.read_u8()?;
        let id = r.read_u64()?;
        let n = r.read_u32()? as usize;
        if n == 0 {
            return Err(bad("empty owner run"));
        }
        covered = covered.checked_add(n).ok_or(bad("owner runs overflow"))?;
        if covered > total {
            return Err(bad("owner runs exceed rows"));
        }
        let owner = match tag {
            0 => RowOwner::Empty,
            1 => RowOwner::Unowned,
            2 => RowOwner::Mixed,
            3 => RowOwner::Command(id),
            _ => return Err(bad("invalid row owner")),
        };
        if tag != 3 && id != 0 {
            return Err(bad("invalid row owner"));
        }
        runs.push((owner, n));
    }
    if covered != total {
        return Err(bad("owner runs do not cover rows"));
    }
    let pen = read_opt_u64(r)?;
    let next_id = read_opt_u64(r)?;
    let running = read_opt_u64(r)?;
    let count = r.read_u32()? as usize;
    // id, status, code, two presence flags, the truncation flag, the time.
    r.check_count(count, 8 + 1 + 4 + 1 + 1 + 1 + 9)?;
    if count > MAX_COMMAND_RECORDS {
        return Err(bad("too many command records"));
    }
    r.charge_spine(count, COMMAND_RECORD_SPINE)?;
    let mut records = Vec::with_capacity(count);
    for _ in 0..count {
        let id = r.read_u64()?;
        let status = r.read_u8()?;
        let code = r.read_u32()? as i32;
        let status = match status {
            0 => CommandStatus::Running,
            1 => CommandStatus::Completed(None),
            2 => CommandStatus::Completed(Some(code)),
            3 => CommandStatus::Abandoned,
            _ => return Err(bad("invalid command status")),
        };
        let cwd = read_opt_string(r)?;
        let input = read_opt_string(r)?;
        let input_truncated = r.read_bool()?;
        let started_at_ms = read_opt_u64(r)?;
        let prompt_line = if version >= 6 { read_opt_u64(r)? } else { None };
        records.push(CommandRecord {
            id,
            status,
            prompt_line,
            cwd,
            input,
            input_truncated,
            started_at_ms,
        });
    }
    for (owner, _) in &runs {
        if matches!(*owner, RowOwner::Command(id) if id == 0 || next_id.is_some_and(|n| id >= n)) {
            return Err(bad("invalid row owner id"));
        }
    }
    let log = CommandLog::from_parts(records, next_id, running).map_err(bad)?;
    if pen != running {
        return Err(bad("command pen is not the running command"));
    }

    let last_cwd = read_opt_string(r)?;
    if last_cwd.as_ref().is_some_and(|c| c.len() > MAX_CWD_BYTES) {
        return Err(bad("cwd too long"));
    }
    let input_line = read_opt_u64(r)?;
    let input_col = r.read_u32()? as usize;
    if input_col >= grid.cols() && input_line.is_some() {
        return Err(bad("input start outside the grid"));
    }
    let last_prompt_line = if version >= 6 { read_opt_u64(r)? } else { None };

    // The grid may hold fewer history rows than were written (its capacity
    // dropped the oldest); their owners go with them.
    let mut skip = written_history - grid.scrollback_len().min(written_history);
    let mut index = 0usize;
    for (owner, n) in runs {
        let mut n = n;
        let skipped = skip.min(n);
        skip -= skipped;
        n -= skipped;
        for _ in 0..n {
            if index < grid.scrollback_len() {
                grid.set_scrollback_owner(index, owner);
            } else {
                grid.set_row_owner(index - grid.scrollback_len(), owner);
            }
            index += 1;
        }
    }
    grid.set_pen_owner(pen);
    Ok(CommandState {
        log,
        last_cwd,
        input_start: input_line.map(|line| (line, input_col)),
        last_prompt_line,
    })
}
