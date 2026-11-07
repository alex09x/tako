/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use std::os::raw::{c_char, c_int};

use crate::terminal::{
    ProgramStatusMutation, ProgramStatusRecord, ProgramStatusSnapshot, ProgramStatusUpdate,
};

use super::program_status_types::{
    PROD_VT_STATUS_KIND_NONE, PROD_VT_STATUS_MUTATION_REMOVED, PROD_VT_STATUS_MUTATION_RESET,
    PROD_VT_STATUS_MUTATION_UPSERTED, PROD_VT_STATUS_REASON_NONE, ProdVtProgramStatusDrainBatch,
    ProdVtProgramStatusMutation, ProdVtProgramStatusRecord, ProdVtProgramStatusSnapshot,
    ProdVtProgramStatusUpdate, ProdVtUtf8View,
};
use super::types::{
    PROD_VT_ERR_NULL_ARGUMENT, PROD_VT_OK, PROD_VT_PROGRAM_STATUS_ABI_VERSION, ProdVt, guarded,
    term,
};

#[derive(Default)]
struct Arena {
    strings: Vec<Box<[u8]>>,
    records: Vec<Box<[ProdVtProgramStatusRecord]>>,
    mutations: Vec<Box<[ProdVtProgramStatusMutation]>>,
    updates: Vec<Box<[ProdVtProgramStatusUpdate]>>,
}

impl Arena {
    fn alloc_str(&mut self, s: &str) -> ProdVtUtf8View {
        let mut buf = Vec::with_capacity(s.len() + 1);
        buf.extend_from_slice(s.as_bytes());
        buf.push(0);
        let boxed = buf.into_boxed_slice();
        let ptr = boxed.as_ptr() as *const c_char;
        let len = s.len();
        self.strings.push(boxed);
        ProdVtUtf8View {
            ptr,
            len,
            present: 1,
            reserved: [0; 7],
        }
    }

    fn alloc_opt_str(&mut self, s: Option<&str>) -> ProdVtUtf8View {
        match s {
            Some(val) => self.alloc_str(val),
            None => ProdVtUtf8View::NONE,
        }
    }

    fn build_record(&mut self, rec: &ProgramStatusRecord) -> ProdVtProgramStatusRecord {
        ProdVtProgramStatusRecord {
            revision: rec.revision,
            state: rec.state as u8,
            kind: rec.kind.map_or(PROD_VT_STATUS_KIND_NONE, |k| k as u8),
            has_progress: rec.progress.is_some() as u8,
            progress: rec.progress.unwrap_or(0),
            reserved: 0,
            id: self.alloc_str(&rec.id),
            app: self.alloc_opt_str(rec.app.as_deref()),
            resolved_app: self.alloc_opt_str(rec.resolved_app.as_deref()),
            title: self.alloc_opt_str(rec.title.as_deref()),
            msg: self.alloc_opt_str(rec.msg.as_deref()),
        }
    }

    fn build_snapshot(&mut self, snap: &ProgramStatusSnapshot) -> ProdVtProgramStatusSnapshot {
        let (has_effective, effective) = match &snap.effective {
            Some(eff) => (1, self.build_record(eff)),
            None => (0, ProdVtProgramStatusRecord::ZERO),
        };
        let recs: Vec<ProdVtProgramStatusRecord> =
            snap.records.iter().map(|r| self.build_record(r)).collect();
        let boxed = recs.into_boxed_slice();
        let ptr = if boxed.is_empty() {
            std::ptr::null()
        } else {
            boxed.as_ptr()
        };
        let len = boxed.len();
        self.records.push(boxed);
        ProdVtProgramStatusSnapshot {
            abi_version: PROD_VT_PROGRAM_STATUS_ABI_VERSION,
            osc7501_active: snap.osc7501_active as c_int,
            revision: snap.revision,
            has_effective,
            reserved: 0,
            effective,
            records: ptr,
            records_len: len,
        }
    }

    fn build_update(&mut self, upd: &ProgramStatusUpdate) -> ProdVtProgramStatusUpdate {
        let (has_effective, effective) = match &upd.effective {
            Some(eff) => (1, self.build_record(eff)),
            None => (0, ProdVtProgramStatusRecord::ZERO),
        };
        let muts: Vec<ProdVtProgramStatusMutation> = upd
            .mutations
            .iter()
            .map(|m| match m {
                ProgramStatusMutation::Upserted { record } => ProdVtProgramStatusMutation {
                    mutation_type: PROD_VT_STATUS_MUTATION_UPSERTED,
                    reason: PROD_VT_STATUS_REASON_NONE,
                    reserved: 0,
                    removed_count: 0,
                    id: self.alloc_str(&record.id),
                    record: self.build_record(record),
                },
                ProgramStatusMutation::Removed {
                    id,
                    previous,
                    reason,
                } => ProdVtProgramStatusMutation {
                    mutation_type: PROD_VT_STATUS_MUTATION_REMOVED,
                    reason: *reason as u8,
                    reserved: 0,
                    removed_count: 1,
                    id: self.alloc_str(id),
                    record: self.build_record(previous),
                },
                ProgramStatusMutation::Reset {
                    removed_count,
                    reason,
                } => ProdVtProgramStatusMutation {
                    mutation_type: PROD_VT_STATUS_MUTATION_RESET,
                    reason: *reason as u8,
                    reserved: 0,
                    removed_count: *removed_count,
                    id: ProdVtUtf8View::NONE,
                    record: ProdVtProgramStatusRecord::ZERO,
                },
            })
            .collect();
        let boxed = muts.into_boxed_slice();
        let ptr = if boxed.is_empty() {
            std::ptr::null()
        } else {
            boxed.as_ptr()
        };
        let len = boxed.len();
        self.mutations.push(boxed);
        ProdVtProgramStatusUpdate {
            revision: upd.revision,
            has_effective,
            reserved: 0,
            effective,
            mutations: ptr,
            mutations_len: len,
        }
    }
}

#[repr(C)]
struct OwnedSnapshot {
    raw: ProdVtProgramStatusSnapshot,
    _arena: Arena,
}

#[repr(C)]
struct OwnedDrainBatch {
    raw: ProdVtProgramStatusDrainBatch,
    _arena: Arena,
}

#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_program_status_abi_version() -> u32 {
    PROD_VT_PROGRAM_STATUS_ABI_VERSION
}

#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_set_program_status_probe_reply_enabled(
    vt: *mut ProdVt,
    enabled: c_int,
) -> c_int {
    guarded(PROD_VT_ERR_NULL_ARGUMENT, || {
        let Some(t) = (unsafe { term(vt) }) else {
            return PROD_VT_ERR_NULL_ARGUMENT;
        };
        t.set_program_status_probe_reply_enabled(enabled != 0);
        PROD_VT_OK
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_is_program_status_probe_reply_enabled(
    vt: *const ProdVt,
    enabled_out: *mut c_int,
) -> c_int {
    guarded(PROD_VT_ERR_NULL_ARGUMENT, || {
        if vt.is_null() || enabled_out.is_null() {
            return PROD_VT_ERR_NULL_ARGUMENT;
        }
        let on = unsafe { (*vt).terminal.is_program_status_probe_reply_enabled() };
        unsafe { *enabled_out = on as c_int };
        PROD_VT_OK
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_program_status_snapshot(
    vt: *const ProdVt,
    snapshot_out: *mut *mut ProdVtProgramStatusSnapshot,
) -> c_int {
    guarded(PROD_VT_ERR_NULL_ARGUMENT, || {
        if !snapshot_out.is_null() {
            unsafe { *snapshot_out = std::ptr::null_mut() };
        }
        if vt.is_null() || snapshot_out.is_null() {
            return PROD_VT_ERR_NULL_ARGUMENT;
        }
        let snap = unsafe { (*vt).terminal.program_status_snapshot() };
        let mut arena = Arena::default();
        let raw = arena.build_snapshot(&snap);
        let owned = Box::new(OwnedSnapshot { raw, _arena: arena });
        unsafe {
            *snapshot_out = Box::into_raw(owned) as *mut ProdVtProgramStatusSnapshot;
        }
        PROD_VT_OK
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_program_status_snapshot_free(snapshot: *mut ProdVtProgramStatusSnapshot) {
    guarded((), || {
        if !snapshot.is_null() {
            drop(unsafe { Box::from_raw(snapshot as *mut OwnedSnapshot) });
        }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_program_status_drain(
    vt: *mut ProdVt,
    max_updates: usize,
    batch_out: *mut *mut ProdVtProgramStatusDrainBatch,
) -> c_int {
    guarded(PROD_VT_ERR_NULL_ARGUMENT, || {
        if !batch_out.is_null() {
            unsafe { *batch_out = std::ptr::null_mut() };
        }
        let Some(t) = (unsafe { term(vt) }) else {
            return PROD_VT_ERR_NULL_ARGUMENT;
        };
        if batch_out.is_null() {
            return PROD_VT_ERR_NULL_ARGUMENT;
        }
        let batch = t.drain_program_status_updates(max_updates);
        let mut arena = Arena::default();
        let upds: Vec<ProdVtProgramStatusUpdate> = batch
            .updates
            .iter()
            .map(|u| arena.build_update(u))
            .collect();
        let boxed_upds = upds.into_boxed_slice();
        let updates_ptr = if boxed_upds.is_empty() {
            std::ptr::null()
        } else {
            boxed_upds.as_ptr()
        };
        let updates_len = boxed_upds.len();
        arena.updates.push(boxed_upds);
        let (has_resync, resync_snapshot) = match &batch.resync_snapshot {
            Some(snap) => (1, arena.build_snapshot(snap)),
            None => (
                0,
                ProdVtProgramStatusSnapshot {
                    abi_version: PROD_VT_PROGRAM_STATUS_ABI_VERSION,
                    osc7501_active: 0,
                    revision: batch.snapshot_revision,
                    has_effective: 0,
                    reserved: 0,
                    effective: ProdVtProgramStatusRecord::ZERO,
                    records: std::ptr::null(),
                    records_len: 0,
                },
            ),
        };
        let owned = Box::new(OwnedDrainBatch {
            raw: ProdVtProgramStatusDrainBatch {
                abi_version: PROD_VT_PROGRAM_STATUS_ABI_VERSION,
                has_more: batch.has_more as c_int,
                overflow_coalesced: batch.overflow_coalesced as c_int,
                has_resync_snapshot: has_resync,
                snapshot_revision: batch.snapshot_revision,
                overflow_from_revision: batch.overflow_from_revision,
                updates: updates_ptr,
                updates_len,
                resync_snapshot,
            },
            _arena: arena,
        });
        unsafe {
            *batch_out = Box::into_raw(owned) as *mut ProdVtProgramStatusDrainBatch;
        }
        PROD_VT_OK
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_program_status_drain_free(batch: *mut ProdVtProgramStatusDrainBatch) {
    guarded((), || {
        if !batch.is_null() {
            drop(unsafe { Box::from_raw(batch as *mut OwnedDrainBatch) });
        }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_program_status_process_exited(vt: *mut ProdVt) -> c_int {
    guarded(PROD_VT_ERR_NULL_ARGUMENT, || {
        let Some(t) = (unsafe { term(vt) }) else {
            return PROD_VT_ERR_NULL_ARGUMENT;
        };
        let _ = t.program_status_process_exited();
        PROD_VT_OK
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_program_status_interrupted(vt: *mut ProdVt) -> c_int {
    guarded(PROD_VT_ERR_NULL_ARGUMENT, || {
        let Some(t) = (unsafe { term(vt) }) else {
            return PROD_VT_ERR_NULL_ARGUMENT;
        };
        let _ = t.program_status_interrupted();
        PROD_VT_OK
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_program_status_acknowledged(vt: *mut ProdVt) -> c_int {
    guarded(PROD_VT_ERR_NULL_ARGUMENT, || {
        let Some(t) = (unsafe { term(vt) }) else {
            return PROD_VT_ERR_NULL_ARGUMENT;
        };
        let _ = t.program_status_acknowledged();
        PROD_VT_OK
    })
}
