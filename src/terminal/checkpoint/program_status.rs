/*
 * tako — Checkpoint serialization for OSC 7501 program status
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use std::collections::{HashMap, HashSet, VecDeque};

use super::reader::Reader;
use super::types::{CheckpointError, map_spine};
use super::writer::Writer;
use crate::terminal::program_status::parse::{
    is_valid_app_name, is_valid_clean_text, is_valid_record_id,
};
use crate::terminal::program_status::{
    MAX_APP_BYTES, MAX_ID_BYTES, MAX_MSG_DECODED_BYTES, MAX_RECORDS, MAX_TITLE_DECODED_BYTES,
    ProgramStatusBlockedKind, ProgramStatusState, ProgramStatusTable, StoredRecord,
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

fn read_bounded_str(
    r: &mut Reader<'_>,
    max_bytes: usize,
    err_msg: &'static str,
) -> Result<String, CheckpointError> {
    let bytes = r.read_bytes_budgeted()?;
    if bytes.len() > max_bytes {
        return Err(CheckpointError::InvalidData(err_msg));
    }
    String::from_utf8(bytes.to_vec())
        .map_err(|_| CheckpointError::InvalidData("non-utf8 string in checkpoint"))
}

fn read_opt_bounded_str(
    r: &mut Reader<'_>,
    max_bytes: usize,
    err_msg: &'static str,
) -> Result<Option<String>, CheckpointError> {
    if r.read_bool()? {
        Ok(Some(read_bounded_str(r, max_bytes, err_msg)?))
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
    if !osc7501_active {
        return Err(CheckpointError::InvalidData(
            "inactive program status trailer",
        ));
    }
    let revision = r.read_u64()?;
    if revision == 0 {
        return Err(CheckpointError::InvalidData(
            "zero revision in active program status trailer",
        ));
    }
    let lru_clock = r.read_u64()?;
    let count = r.read_u32()? as usize;
    if count > MAX_RECORDS {
        return Err(CheckpointError::InvalidData(
            "program status record count exceeds cap",
        ));
    }
    if (count as u64) > revision || (count as u64) > lru_clock {
        return Err(CheckpointError::InvalidData(
            "program status clocks precede record count",
        ));
    }
    r.check_count(count, MIN_BYTES_PER_RECORD)?;
    r.charge(map_spine(count as u64, PROGRAM_STATUS_ENTRY))?;

    let mut records = HashMap::with_capacity(count);
    let mut seen_revisions = HashSet::with_capacity(count);
    let mut seen_lru_ticks = HashSet::with_capacity(count);
    for _ in 0..count {
        let id = read_bounded_str(r, MAX_ID_BYTES, "program status id exceeds cap")?;
        if !is_valid_record_id(&id) {
            return Err(CheckpointError::InvalidData("invalid program status id"));
        }
        if records.contains_key(&id) {
            return Err(CheckpointError::InvalidData(
                "duplicate program status record id",
            ));
        }
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
        if kind.is_some() && state != ProgramStatusState::Blocked {
            return Err(CheckpointError::InvalidData(
                "program status kind on non-blocked state",
            ));
        }
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
        if progress.is_some()
            && !matches!(
                state,
                ProgramStatusState::Working | ProgramStatusState::Blocked
            )
        {
            return Err(CheckpointError::InvalidData(
                "program status progress on non-progress state",
            ));
        }
        let app = read_opt_bounded_str(r, MAX_APP_BYTES, "program status app exceeds cap")?;
        if let Some(ref app_str) = app
            && !is_valid_app_name(app_str)
        {
            return Err(CheckpointError::InvalidData("invalid program status app"));
        }
        let title = read_opt_bounded_str(
            r,
            MAX_TITLE_DECODED_BYTES,
            "program status title exceeds cap",
        )?;
        if let Some(ref title_str) = title
            && !is_valid_clean_text(title_str, MAX_TITLE_DECODED_BYTES)
        {
            return Err(CheckpointError::InvalidData("invalid program status title"));
        }
        let msg = read_opt_bounded_str(r, MAX_MSG_DECODED_BYTES, "program status msg exceeds cap")?;
        if let Some(ref msg_str) = msg
            && !is_valid_clean_text(msg_str, MAX_MSG_DECODED_BYTES)
        {
            return Err(CheckpointError::InvalidData("invalid program status msg"));
        }
        let rec_rev = r.read_u64()?;
        if rec_rev == 0 || rec_rev > revision || !seen_revisions.insert(rec_rev) {
            return Err(CheckpointError::InvalidData(
                "inconsistent program status record revision",
            ));
        }
        let lru_tick = r.read_u64()?;
        if lru_tick == 0 || lru_tick > lru_clock || !seen_lru_ticks.insert(lru_tick) {
            return Err(CheckpointError::InvalidData(
                "inconsistent program status lru_tick",
            ));
        }
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
