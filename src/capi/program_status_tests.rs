/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use std::os::raw::c_int;

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;

use crate::response::MAX_QUEUED_REPLIES;
use crate::terminal::program_status::{CAPABILITY_REPLY, MAX_PENDING_STATUS_UPDATES};

use super::*;

unsafe fn utf8_str<'a>(view: ProdVtUtf8View) -> Option<&'a str> {
    if view.present == 0 || view.ptr.is_null() {
        return None;
    }
    let slice = unsafe { std::slice::from_raw_parts(view.ptr as *const u8, view.len) };
    std::str::from_utf8(slice).ok()
}

#[test]
fn capi_program_status_drain_before_discard_and_paginated_tail() {
    assert_eq!(prod_vt_program_status_abi_version(), 1);
    let vt = prod_vt_new(80, 24, 128);
    assert!(!vt.is_null());

    let msg = STANDARD.encode(b"Allow bash?");
    let mut stream = Vec::new();
    for i in 0..5 {
        stream.extend_from_slice(
            format!("\x1b]7501;id=step{i}:state=working:app=claude\x07").as_bytes(),
        );
    }
    stream.extend_from_slice(
        format!("\x1b]7501;id=step4/ask:state=blocked:kind=permission:msg={msg}\x07\x07")
            .as_bytes(),
    );
    prod_vt_write(vt, stream.as_ptr(), stream.len());

    // Drain in small batches BEFORE prod_vt_discard_events, with no further PTY bytes.
    let mut seen_revisions = Vec::new();
    loop {
        let mut batch: *mut ProdVtProgramStatusDrainBatch = std::ptr::null_mut();
        assert_eq!(prod_vt_program_status_drain(vt, 2, &mut batch), PROD_VT_OK);
        assert!(!batch.is_null());
        let raw = unsafe { &*batch };
        assert_eq!(raw.overflow_coalesced, 0);
        let upds = unsafe { std::slice::from_raw_parts(raw.updates, raw.updates_len) };
        for u in upds {
            seen_revisions.push(u.revision);
        }
        let more = raw.has_more != 0;
        prod_vt_program_status_drain_free(batch);
        if !more {
            break;
        }
    }
    assert_eq!(seen_revisions, vec![1, 2, 3, 4, 5, 6]);

    // Discard drops bell/other events while preserving authoritative snapshot.
    prod_vt_discard_events(vt);

    let mut snap: *mut ProdVtProgramStatusSnapshot = std::ptr::null_mut();
    assert_eq!(prod_vt_program_status_snapshot(vt, &mut snap), PROD_VT_OK);
    let s = unsafe { &*snap };
    assert_eq!(s.osc7501_active, 1);
    assert_eq!(s.revision, 6);
    assert_eq!(s.has_effective, 1);
    assert_eq!(s.effective.state, PROD_VT_STATUS_STATE_BLOCKED);
    assert_eq!(s.effective.kind, PROD_VT_STATUS_KIND_PERMISSION);
    assert_eq!(
        unsafe { utf8_str(s.effective.resolved_app) },
        Some("claude")
    );
    assert_eq!(unsafe { utf8_str(s.effective.msg) }, Some("Allow bash?"));
    prod_vt_program_status_snapshot_free(snap);

    prod_vt_free(vt);
}

#[test]
fn capi_burst_overflow_returns_coalesced_resync_snapshot_in_single_turn() {
    let vt = prod_vt_new(80, 24, 64);
    let total = MAX_PENDING_STATUS_UPDATES + 12;
    let mut payload = Vec::new();
    for i in 0..total {
        payload.extend_from_slice(format!("\x1b]7501;id=r{i}:state=done\x07").as_bytes());
    }
    prod_vt_write(vt, payload.as_ptr(), payload.len());

    // No further bytes arrive; drain immediately surfaces overflow + resync snapshot.
    let mut batch: *mut ProdVtProgramStatusDrainBatch = std::ptr::null_mut();
    assert_eq!(prod_vt_program_status_drain(vt, 8, &mut batch), PROD_VT_OK);
    let raw = unsafe { &*batch };
    assert_eq!(raw.overflow_coalesced, 1);
    assert_eq!(raw.has_resync_snapshot, 1);
    assert_eq!(raw.overflow_from_revision, 1);
    assert_eq!(raw.has_more, 0);
    assert_eq!(raw.resync_snapshot.revision, total as u64);
    assert_eq!(raw.resync_snapshot.records_len, total);
    prod_vt_program_status_drain_free(batch);

    prod_vt_free(vt);
}

#[test]
fn capi_classified_replies_consume_once_overflow_and_checkpoint_restore() {
    let vt = prod_vt_new(80, 24, 64);

    let probe_and_da1 = b"\x1b]7501;?\x1b\\\x1b[c";
    prod_vt_write(vt, probe_and_da1.as_ptr(), probe_and_da1.len());

    let mut rbatch: *mut ProdVtReplyBatch = std::ptr::null_mut();
    assert_eq!(
        prod_vt_drain_classified_replies(vt, 1, &mut rbatch),
        PROD_VT_OK
    );
    let b1 = unsafe { &*rbatch };
    assert_eq!(b1.has_more, 1);
    assert_eq!(b1.replies_len, 1);
    let r0 = unsafe { &*b1.replies };
    assert_eq!(r0.seq, 1);
    assert_eq!(
        r0.reply_class,
        PROD_VT_REPLY_CLASS_PROGRAM_STATUS_CAPABILITY
    );
    let r0_bytes = unsafe { std::slice::from_raw_parts(r0.data, r0.len) };
    assert_eq!(r0_bytes, CAPABILITY_REPLY.as_bytes());
    prod_vt_reply_batch_free(rbatch);

    // Legacy flat drain sees ONLY the remaining DA1 reply — never duplicates reply #1.
    let mut flat: *mut u8 = std::ptr::null_mut();
    let mut flat_len: usize = 0;
    assert_eq!(prod_vt_drain_responses(vt, &mut flat, &mut flat_len), 1);
    let flat_slice = unsafe { std::slice::from_raw_parts(flat, flat_len) };
    assert_eq!(flat_slice, b"\x1b[?62;22c");
    prod_vt_buffer_free(flat);

    // Reply overflow returns PROD_VT_ERR_REPLY_OVERFLOW (-12) with preserved FIFO prefix.
    let mut spam = Vec::new();
    for _ in 0..(MAX_QUEUED_REPLIES + 3) {
        spam.extend_from_slice(b"\x1b[5n");
    }
    prod_vt_write(vt, spam.as_ptr(), spam.len());
    let mut over_batch: *mut ProdVtReplyBatch = std::ptr::null_mut();
    assert_eq!(
        prod_vt_drain_classified_replies(vt, MAX_QUEUED_REPLIES + 10, &mut over_batch),
        PROD_VT_ERR_REPLY_OVERFLOW
    );
    let ob = unsafe { &*over_batch };
    assert_eq!(ob.replies_len, MAX_QUEUED_REPLIES);
    assert_eq!(ob.overflow_dropped_count, 3);
    prod_vt_reply_batch_free(over_batch);

    // Checkpoint restore after queued reply + status drops stale queued replies and preserves policy.
    assert_eq!(
        prod_vt_set_program_status_probe_reply_enabled(vt, 0),
        PROD_VT_OK
    );
    let mut cp_buf = vec![0u8; 256 * 1024];
    let mut cp_len: usize = 0;
    assert_eq!(
        prod_vt_checkpoint_export2(
            vt,
            16 * 1024 * 1024,
            cp_buf.as_mut_ptr(),
            cp_buf.len(),
            &mut cp_len
        ),
        PROD_VT_OK
    );

    let queued = b"\x1b[c\x1b]7501;state=working\x07";
    prod_vt_write(vt, queued.as_ptr(), queued.len());
    assert_eq!(
        prod_vt_checkpoint_import2(vt, cp_buf.as_ptr(), cp_len),
        PROD_VT_OK
    );

    let mut enabled: c_int = 1;
    assert_eq!(
        prod_vt_is_program_status_probe_reply_enabled(vt, &mut enabled),
        PROD_VT_OK
    );
    assert_eq!(enabled, 0);

    let mut post_restore_replies: *mut ProdVtReplyBatch = std::ptr::null_mut();
    assert_eq!(
        prod_vt_drain_classified_replies(vt, 16, &mut post_restore_replies),
        PROD_VT_OK
    );
    assert_eq!(unsafe { (*post_restore_replies).replies_len }, 0);
    prod_vt_reply_batch_free(post_restore_replies);

    // Null pointer safety.
    assert_eq!(
        prod_vt_program_status_drain(std::ptr::null_mut(), 8, std::ptr::null_mut()),
        PROD_VT_ERR_NULL_ARGUMENT
    );
    assert_eq!(
        prod_vt_program_status_snapshot(std::ptr::null(), std::ptr::null_mut()),
        PROD_VT_ERR_NULL_ARGUMENT
    );
    prod_vt_program_status_drain_free(std::ptr::null_mut());
    prod_vt_program_status_snapshot_free(std::ptr::null_mut());
    prod_vt_reply_batch_free(std::ptr::null_mut());

    prod_vt_free(vt);
}

#[test]
fn capi_overflow_then_legacy_drain_preserves_sticky_loss_count() {
    let vt = prod_vt_new(80, 24, 128);
    assert!(!vt.is_null());

    let mut spam = Vec::new();
    for _ in 0..(MAX_QUEUED_REPLIES + 44) {
        spam.extend_from_slice(b"\x1b[5n");
    }
    prod_vt_write(vt, spam.as_ptr(), spam.len());

    // Legacy caller drains preserved reply bytes first.
    let mut flat: *mut u8 = std::ptr::null_mut();
    let mut flat_len: usize = 0;
    assert_eq!(prod_vt_drain_responses(vt, &mut flat, &mut flat_len), 1);
    assert_eq!(flat_len, MAX_QUEUED_REPLIES * 4);
    prod_vt_buffer_free(flat);

    // Sticky overflow loss count (44) must NOT be erased by legacy prod_vt_drain_responses.
    let mut loss_batch: *mut ProdVtReplyBatch = std::ptr::null_mut();
    assert_eq!(
        prod_vt_drain_classified_replies(vt, 16, &mut loss_batch),
        PROD_VT_ERR_REPLY_OVERFLOW
    );
    let lb = unsafe { &*loss_batch };
    assert_eq!(lb.replies_len, 0);
    assert_eq!(lb.overflow_dropped_count, 44);
    prod_vt_reply_batch_free(loss_batch);

    // Also verify explicit sticky loss accessor prod_vt_take_reply_overflow_count after legacy drain.
    prod_vt_write(vt, spam.as_ptr(), spam.len());
    let mut flat2: *mut u8 = std::ptr::null_mut();
    let mut flat2_len: usize = 0;
    assert_eq!(prod_vt_drain_responses(vt, &mut flat2, &mut flat2_len), 1);
    prod_vt_buffer_free(flat2);
    let mut dropped: u32 = 0;
    assert_eq!(
        prod_vt_take_reply_overflow_count(vt, &mut dropped),
        PROD_VT_ERR_REPLY_OVERFLOW
    );
    assert_eq!(dropped, 44);
    assert_eq!(
        prod_vt_take_reply_overflow_count(vt, &mut dropped),
        PROD_VT_OK
    );
    assert_eq!(dropped, 0);

    prod_vt_free(vt);
}
