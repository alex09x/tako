/*
 * tako — Checkpoint serialization for OSC 7501 program status
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use std::collections::{HashMap, VecDeque};

use super::reader::Reader;
use super::types::{CheckpointError, map_spine};
use super::writer::Writer;
use crate::terminal::program_status::{
    MAX_RECORDS, ProgramStatusBlockedKind, ProgramStatusState, ProgramStatusTable, StoredRecord,
};

pub const PS75_MAGIC: [u8; 4] = *b"PS75";
pub const PROGRAM_STATUS_ENTRY: u64 = std::mem::size_of::<(String, StoredRecord)>() as u64;
const MIN_BYTES_PER_RECORD: usize = 26;

pub(crate) fn should_encode(table: &ProgramStatusTable, version: u32) -> bool {
    version >= 7 && (table.osc7501_active || !table.records.is_empty())
}

pub(crate) fn import_cost_bytes(table: &ProgramStatusTable, version: u32) -> u64 {
    if !should_encode(table, version) {
        return 0;
    }
    let mut bytes = map_spine(table.records.len() as u64, PROGRAM_STATUS_ENTRY);
    for rec in table.records.values() {
        let id_len = rec.id.len() as u64;
        bytes = bytes
            .saturating_add(id_len.saturating_mul(2))
            .saturating_add(rec.app.as_ref().map_or(0, |s| s.len() as u64))
            .saturating_add(rec.title.as_ref().map_or(0, |s| s.len() as u64))
            .saturating_add(rec.msg.as_ref().map_or(0, |s| s.len() as u64));
    }
    bytes
}

fn write_opt_str(w: &mut Writer, opt: Option<&str>) {
    if let Some(s) = opt {
        w.write_bool(true);
        w.write_string(s);
    } else {
        w.write_bool(false);
    }
}

fn read_opt_str(r: &mut Reader<'_>) -> Result<Option<String>, CheckpointError> {
    if r.read_bool()? {
        Ok(Some(r.read_string_budgeted()?))
    } else {
        Ok(None)
    }
}

pub(crate) fn write_program_status(w: &mut Writer, table: &ProgramStatusTable, version: u32) {
    if !should_encode(table, version) {
        return;
    }
    w.push(&PS75_MAGIC);
    w.write_bool(table.osc7501_active);
    w.write_u64(table.revision);
    w.write_u64(table.lru_clock);

    let mut ordered: Vec<&StoredRecord> = table.records.values().collect();
    ordered.sort_by(|a, b| a.id.cmp(&b.id));
    w.write_u32(ordered.len() as u32);
    for rec in ordered {
        w.write_string(&rec.id);
        w.write_u8(match rec.state {
            ProgramStatusState::Idle => 0,
            ProgramStatusState::Working => 1,
            ProgramStatusState::Done => 2,
            ProgramStatusState::Blocked => 3,
            ProgramStatusState::Error => 4,
        });
        w.write_u8(match rec.kind {
            None => 0,
            Some(ProgramStatusBlockedKind::Permission) => 1,
            Some(ProgramStatusBlockedKind::Question) => 2,
            Some(ProgramStatusBlockedKind::Auth) => 3,
        });
        if let Some(pct) = rec.progress {
            w.write_bool(true);
            w.write_u8(pct);
        } else {
            w.write_bool(false);
        }
        write_opt_str(w, rec.app.as_deref());
        write_opt_str(w, rec.title.as_deref());
        write_opt_str(w, rec.msg.as_deref());
        w.write_u64(rec.revision);
        w.write_u64(rec.lru_tick);
    }
}

pub(crate) fn read_program_status(
    r: &mut Reader<'_>,
    version: u32,
) -> Result<ProgramStatusTable, CheckpointError> {
    if version < 7 || r.remaining() < PS75_MAGIC.len() {
        return Ok(ProgramStatusTable::new());
    }
    if r.data[r.pos..r.pos + PS75_MAGIC.len()] != PS75_MAGIC {
        return Ok(ProgramStatusTable::new());
    }
    r.pos += PS75_MAGIC.len();

    let osc7501_active = r.read_bool()?;
    let revision = r.read_u64()?;
    let lru_clock = r.read_u64()?;
    let count = r.read_u32()? as usize;
    if count > MAX_RECORDS {
        return Err(CheckpointError::InvalidData(
            "program status record count exceeds cap",
        ));
    }
    r.check_count(count, MIN_BYTES_PER_RECORD)?;
    r.charge(map_spine(count as u64, PROGRAM_STATUS_ENTRY))?;

    let mut records = HashMap::with_capacity(count);
    for _ in 0..count {
        let id = r.read_string_budgeted()?;
        r.charge(id.len() as u64)?;
        let state = match r.read_u8()? {
            0 => ProgramStatusState::Idle,
            1 => ProgramStatusState::Working,
            2 => ProgramStatusState::Done,
            3 => ProgramStatusState::Blocked,
            4 => ProgramStatusState::Error,
            _ => return Err(CheckpointError::InvalidData("invalid program status state")),
        };
        let kind = match r.read_u8()? {
            0 => None,
            1 => Some(ProgramStatusBlockedKind::Permission),
            2 => Some(ProgramStatusBlockedKind::Question),
            3 => Some(ProgramStatusBlockedKind::Auth),
            _ => return Err(CheckpointError::InvalidData("invalid program status kind")),
        };
        let progress = if r.read_bool()? {
            let pct = r.read_u8()?;
            if pct > 100 {
                return Err(CheckpointError::InvalidData(
                    "program status progress > 100",
                ));
            }
            Some(pct)
        } else {
            None
        };
        let app = read_opt_str(r)?;
        let title = read_opt_str(r)?;
        let msg = read_opt_str(r)?;
        let rec_rev = r.read_u64()?;
        let lru_tick = r.read_u64()?;
        let key = id.clone();
        records.insert(
            key,
            StoredRecord {
                id,
                state,
                kind,
                progress,
                app,
                title,
                msg,
                revision: rec_rev,
                lru_tick,
            },
        );
    }

    Ok(ProgramStatusTable {
        records,
        pending_updates: VecDeque::new(),
        overflow_from_revision: None,
        events_emitted_since_take: 0,
        revision,
        lru_clock,
        osc7501_active,
        probe_reply_enabled: true,
    })
}
