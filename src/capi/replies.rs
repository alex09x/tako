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

use crate::response::TerminalReplyClass;

use super::types::{
    PROD_VT_ERR_NULL_ARGUMENT, PROD_VT_ERR_REPLY_OVERFLOW, PROD_VT_OK,
    PROD_VT_PROGRAM_STATUS_ABI_VERSION, ProdVt, guarded, term,
};

pub const PROD_VT_REPLY_CLASS_STANDARD_DEVICE: u8 = TerminalReplyClass::StandardDevice as u8;
pub const PROD_VT_REPLY_CLASS_PROGRAM_STATUS_CAPABILITY: u8 =
    TerminalReplyClass::ProgramStatusCapability as u8;

/// One classified consume-once terminal reply in a [`ProdVtReplyBatch`].
#[repr(C)]
pub struct ProdVtClassifiedReply {
    pub seq: u64,
    pub reply_class: u8,
    pub reserved: [u8; 7],
    pub data: *const u8,
    pub len: usize,
}

/// Ordered batch of classified replies drained from `ResponseQueue`.
///
/// Release with [`prod_vt_reply_batch_free`].
#[repr(C)]
pub struct ProdVtReplyBatch {
    pub abi_version: u32,
    pub has_more: c_int,
    pub overflow_dropped_count: u32,
    pub reserved: u32,
    pub replies: *const ProdVtClassifiedReply,
    pub replies_len: usize,
}

#[repr(C)]
struct OwnedReplyBatch {
    raw: ProdVtReplyBatch,
    _bytes: Box<[Box<[u8]>]>,
    _items: Box<[ProdVtClassifiedReply]>,
}

/// Drain up to `max_replies` classified replies in FIFO order (consume-once).
///
/// Shares the exact same underlying queue as legacy `prod_vt_drain_responses`:
/// an item consumed here is never returned again by `prod_vt_drain_responses`
/// (and vice versa). Returns `PROD_VT_OK` (`0`), `PROD_VT_ERR_NULL_ARGUMENT`
/// (`-1`), or `PROD_VT_ERR_REPLY_OVERFLOW` (`-12`) when one or more replies
/// exceeded the bounded queue (in which case `*batch_out` still receives the
/// preserved FIFO prefix and `overflow_dropped_count`).
#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_drain_classified_replies(
    vt: *mut ProdVt,
    max_replies: usize,
    batch_out: *mut *mut ProdVtReplyBatch,
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
        let drained = t.drain_classified_replies(max_replies);
        let mut backing_bytes: Vec<Box<[u8]>> = Vec::with_capacity(drained.replies.len());
        let mut raw_items: Vec<ProdVtClassifiedReply> = Vec::with_capacity(drained.replies.len());
        for item in drained.replies {
            let boxed = item.bytes.into_boxed_slice();
            let ptr = if boxed.is_empty() {
                std::ptr::null()
            } else {
                boxed.as_ptr()
            };
            let len = boxed.len();
            backing_bytes.push(boxed);
            raw_items.push(ProdVtClassifiedReply {
                seq: item.seq,
                reply_class: item.class as u8,
                reserved: [0; 7],
                data: ptr,
                len,
            });
        }
        let boxed_items = raw_items.into_boxed_slice();
        let replies_ptr = if boxed_items.is_empty() {
            std::ptr::null()
        } else {
            boxed_items.as_ptr()
        };
        let replies_len = boxed_items.len();
        let overflow = drained.overflow_dropped_count;
        let owned = Box::new(OwnedReplyBatch {
            raw: ProdVtReplyBatch {
                abi_version: PROD_VT_PROGRAM_STATUS_ABI_VERSION,
                has_more: drained.has_more as c_int,
                overflow_dropped_count: overflow,
                reserved: 0,
                replies: replies_ptr,
                replies_len,
            },
            _bytes: backing_bytes.into_boxed_slice(),
            _items: boxed_items,
        });
        unsafe {
            *batch_out = Box::into_raw(owned) as *mut ProdVtReplyBatch;
        }
        if overflow > 0 {
            PROD_VT_ERR_REPLY_OVERFLOW
        } else {
            PROD_VT_OK
        }
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_reply_batch_free(batch: *mut ProdVtReplyBatch) {
    guarded((), || {
        if !batch.is_null() {
            drop(unsafe { Box::from_raw(batch as *mut OwnedReplyBatch) });
        }
    })
}

/// Consume and reset sticky reply-queue overflow count for callers using legacy
/// `prod_vt_drain_responses()`. Returns `PROD_VT_OK` (`0`) when `dropped == 0`,
/// `PROD_VT_ERR_REPLY_OVERFLOW` (`-12`) when `dropped > 0` (populating `*dropped_out`),
/// or `PROD_VT_ERR_NULL_ARGUMENT` (`-1`) on a NULL pointer.
#[unsafe(no_mangle)]
pub extern "C" fn prod_vt_take_reply_overflow_count(
    vt: *mut ProdVt,
    dropped_out: *mut u32,
) -> c_int {
    guarded(PROD_VT_ERR_NULL_ARGUMENT, || {
        if dropped_out.is_null() {
            return PROD_VT_ERR_NULL_ARGUMENT;
        }
        unsafe { *dropped_out = 0 };
        let Some(t) = (unsafe { term(vt) }) else {
            return PROD_VT_ERR_NULL_ARGUMENT;
        };
        let dropped = t.take_reply_overflow_count();
        unsafe { *dropped_out = dropped };
        if dropped > 0 {
            PROD_VT_ERR_REPLY_OVERFLOW
        } else {
            PROD_VT_OK
        }
    })
}
