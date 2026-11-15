/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

//! The C host's side of OSC 7501 removals: clears, resets and the host's own
//! lifecycle calls reach a drain with their mutation type and reason, an
//! empty table is an empty snapshot, and every entry point refuses NULL.

use std::os::raw::c_int;

use super::*;

fn write(vt: *mut ProdVt, bytes: &[u8]) {
    prod_vt_write(vt, bytes.as_ptr(), bytes.len());
}

fn report(vt: *mut ProdVt, fields: &str) {
    write(vt, format!("\x1b]7501;{fields}\x07").as_bytes());
}

/// Every mutation of one drain, as (type, reason, removed_count, id).
fn drain(vt: *mut ProdVt) -> Vec<(u8, u8, u32, Option<String>)> {
    let mut batch: *mut ProdVtProgramStatusDrainBatch = std::ptr::null_mut();
    assert_eq!(prod_vt_program_status_drain(vt, 64, &mut batch), PROD_VT_OK);
    let raw = unsafe { &*batch };
    assert_eq!(raw.abi_version, PROD_VT_PROGRAM_STATUS_ABI_VERSION);
    assert_eq!(raw.has_more, 0);
    let mut out = vec![];
    let updates = if raw.updates_len == 0 {
        assert!(raw.updates.is_null(), "an empty drain has no update array");
        &[][..]
    } else {
        unsafe { std::slice::from_raw_parts(raw.updates, raw.updates_len) }
    };
    for u in updates {
        let muts = if u.mutations_len == 0 {
            &[][..]
        } else {
            unsafe { std::slice::from_raw_parts(u.mutations, u.mutations_len) }
        };
        for m in muts {
            let id = (m.id.present != 0).then(|| {
                let s = unsafe { std::slice::from_raw_parts(m.id.ptr as *const u8, m.id.len) };
                String::from_utf8(s.to_vec()).unwrap()
            });
            out.push((m.mutation_type, m.reason, m.removed_count, id));
        }
    }
    prod_vt_program_status_drain_free(batch);
    out
}

#[test]
fn removals_resets_and_lifecycle_calls_reach_the_c_drain_with_their_reasons() {
    let vt = prod_vt_new(80, 24, 64);
    report(vt, "id=w:state=working");
    report(vt, "id=b:state=blocked:kind=question");
    report(vt, "id=d:state=done");
    report(vt, "id=e:state=error");
    let upserts = drain(vt);
    assert_eq!(upserts.len(), 4);
    assert!(
        upserts
            .iter()
            .all(|m| m.0 == PROD_VT_STATUS_MUTATION_UPSERTED && m.1 == PROD_VT_STATUS_REASON_NONE)
    );

    // Interrupt: the working and blocked records go, sorted by id.
    assert_eq!(prod_vt_program_status_interrupted(vt), PROD_VT_OK);
    let removed = drain(vt);
    assert_eq!(
        removed,
        [
            (
                PROD_VT_STATUS_MUTATION_REMOVED,
                PROD_VT_STATUS_REASON_INTERRUPTED,
                1,
                Some("b".into())
            ),
            (
                PROD_VT_STATUS_MUTATION_REMOVED,
                PROD_VT_STATUS_REASON_INTERRUPTED,
                1,
                Some("w".into())
            ),
        ]
    );
    // Acknowledge: the outcomes go.
    assert_eq!(prod_vt_program_status_acknowledged(vt), PROD_VT_OK);
    assert_eq!(
        drain(vt),
        [
            (
                PROD_VT_STATUS_MUTATION_REMOVED,
                PROD_VT_STATUS_REASON_ACKNOWLEDGED,
                1,
                Some("d".into())
            ),
            (
                PROD_VT_STATUS_MUTATION_REMOVED,
                PROD_VT_STATUS_REASON_ACKNOWLEDGED,
                1,
                Some("e".into())
            ),
        ]
    );
    // Nothing left to end: a call is fine and the drain is empty.
    assert_eq!(prod_vt_program_status_process_exited(vt), PROD_VT_OK);
    assert!(drain(vt).is_empty());

    // Process exit ends an idle record.
    report(vt, "id=i:state=idle");
    drain(vt);
    assert_eq!(prod_vt_program_status_process_exited(vt), PROD_VT_OK);
    assert_eq!(
        drain(vt),
        [(
            PROD_VT_STATUS_MUTATION_REMOVED,
            PROD_VT_STATUS_REASON_PROCESS_EXIT,
            1,
            Some("i".into())
        )]
    );

    // A whole-table clear and a hard reset are resets, with a count and no id.
    report(vt, "id=x:state=done");
    report(vt, "id=y:state=done");
    drain(vt);
    report(vt, "state=clear");
    assert_eq!(
        drain(vt),
        [(
            PROD_VT_STATUS_MUTATION_RESET,
            PROD_VT_STATUS_REASON_EXPLICIT_CLEAR,
            2,
            None
        )]
    );
    report(vt, "id=z:state=working");
    drain(vt);
    write(vt, b"\x1bc");
    let reset = drain(vt);
    assert_eq!(reset.len(), 1);
    assert_eq!(
        (reset[0].0, reset[0].1, reset[0].3.clone()),
        (
            PROD_VT_STATUS_MUTATION_RESET,
            PROD_VT_STATUS_REASON_HARD_RESET,
            None
        )
    );

    // After the reset the table is empty: no effective record, no record array.
    let mut snap: *mut ProdVtProgramStatusSnapshot = std::ptr::null_mut();
    assert_eq!(prod_vt_program_status_snapshot(vt, &mut snap), PROD_VT_OK);
    let s = unsafe { &*snap };
    assert_eq!((s.has_effective, s.records_len), (0, 0));
    assert!(s.records.is_null());
    assert_eq!(s.effective.state, PROD_VT_STATUS_STATE_NONE);
    prod_vt_program_status_snapshot_free(snap);
    prod_vt_free(vt);
}

#[test]
fn the_probe_switch_round_trips_through_the_c_abi() {
    let vt = prod_vt_new(80, 24, 64);
    let mut on: c_int = -1;
    assert_eq!(
        prod_vt_is_program_status_probe_reply_enabled(vt, &mut on),
        PROD_VT_OK
    );
    assert_eq!(on, 1);
    assert_eq!(
        prod_vt_set_program_status_probe_reply_enabled(vt, 0),
        PROD_VT_OK
    );
    assert_eq!(
        prod_vt_is_program_status_probe_reply_enabled(vt, &mut on),
        PROD_VT_OK
    );
    assert_eq!(on, 0);
    assert_eq!(
        prod_vt_set_program_status_probe_reply_enabled(vt, 7),
        PROD_VT_OK
    );
    assert_eq!(
        prod_vt_is_program_status_probe_reply_enabled(vt, &mut on),
        PROD_VT_OK
    );
    assert_eq!(on, 1, "any nonzero turns it on");
    prod_vt_free(vt);
}

#[test]
fn every_program_status_entry_point_refuses_null() {
    let null = std::ptr::null_mut::<ProdVt>();
    let vt = prod_vt_new(80, 24, 64);
    assert_eq!(
        prod_vt_set_program_status_probe_reply_enabled(null, 1),
        PROD_VT_ERR_NULL_ARGUMENT
    );
    let mut on: c_int = 0;
    assert_eq!(
        prod_vt_is_program_status_probe_reply_enabled(null, &mut on),
        PROD_VT_ERR_NULL_ARGUMENT
    );
    assert_eq!(
        prod_vt_is_program_status_probe_reply_enabled(vt, std::ptr::null_mut()),
        PROD_VT_ERR_NULL_ARGUMENT
    );

    // A snapshot or drain asked of no terminal clears its out pointer.
    let mut snap = std::ptr::dangling_mut::<ProdVtProgramStatusSnapshot>();
    assert_eq!(
        prod_vt_program_status_snapshot(null, &mut snap),
        PROD_VT_ERR_NULL_ARGUMENT
    );
    assert!(snap.is_null());
    assert_eq!(
        prod_vt_program_status_snapshot(vt, std::ptr::null_mut()),
        PROD_VT_ERR_NULL_ARGUMENT
    );
    let mut batch = std::ptr::dangling_mut::<ProdVtProgramStatusDrainBatch>();
    assert_eq!(
        prod_vt_program_status_drain(null, 8, &mut batch),
        PROD_VT_ERR_NULL_ARGUMENT
    );
    assert!(batch.is_null());
    assert_eq!(
        prod_vt_program_status_drain(vt, 8, std::ptr::null_mut()),
        PROD_VT_ERR_NULL_ARGUMENT
    );

    assert_eq!(
        prod_vt_program_status_process_exited(null),
        PROD_VT_ERR_NULL_ARGUMENT
    );
    assert_eq!(
        prod_vt_program_status_interrupted(null),
        PROD_VT_ERR_NULL_ARGUMENT
    );
    assert_eq!(
        prod_vt_program_status_acknowledged(null),
        PROD_VT_ERR_NULL_ARGUMENT
    );
    // Freeing nothing is fine.
    prod_vt_program_status_snapshot_free(std::ptr::null_mut());
    prod_vt_program_status_drain_free(std::ptr::null_mut());
    prod_vt_free(vt);
}
