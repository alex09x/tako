/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;
pub use std::os::raw::{c_int, c_void};

thread_local! {
    static ALLOCATED: Cell<u64> = const { Cell::new(0) };
    static LIVE: Cell<i64> = const { Cell::new(0) };
    static COUNTING: Cell<bool> = const { Cell::new(false) };
}

pub struct Counting;

unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let _ = COUNTING.try_with(|on| {
            if on.get() {
                let _ = ALLOCATED.try_with(|n| n.set(n.get().saturating_add(layout.size() as u64)));
                let _ = LIVE.try_with(|n| n.set(n.get().saturating_add(layout.size() as i64)));
            }
        });
        unsafe { System.alloc(layout) }
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        let _ = COUNTING.try_with(|on| {
            if on.get() {
                let _ = LIVE.try_with(|n| n.set(n.get().saturating_sub(layout.size() as i64)));
            }
        });
        unsafe { System.dealloc(ptr, layout) }
    }

    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        let _ = COUNTING.try_with(|on| {
            if on.get() {
                let grown = new_size.saturating_sub(layout.size());
                let _ = ALLOCATED.try_with(|n| n.set(n.get().saturating_add(grown as u64)));
                let delta = new_size as i64 - layout.size() as i64;
                let _ = LIVE.try_with(|n| n.set(n.get().saturating_add(delta)));
            }
        });
        unsafe { System.realloc(ptr, layout, new_size) }
    }
}

pub fn bytes_allocated_by<T>(body: impl FnOnce() -> T) -> (T, u64) {
    arm_counter();
    let out = body();
    disarm_counter();
    (out, ALLOCATED.with(|n| n.get()))
}

pub fn arm_counter() {
    ALLOCATED.with(|n| n.set(0));
    LIVE.with(|n| n.set(0));
    COUNTING.with(|on| on.set(true));
}

pub fn disarm_counter() {
    COUNTING.with(|on| on.set(false));
}

pub fn live_bytes() -> i64 {
    LIVE.with(|n| n.get())
}

pub const PROD_VT_OK: c_int = 0;
pub const PROD_VT_ERR_BUFFER_TOO_SMALL: c_int = -2;

unsafe extern "C" {
    pub fn prod_vt_new(cols: u16, rows: u16, max_scrollback: usize) -> *mut c_void;
    pub fn prod_vt_free(vt: *mut c_void);
    pub fn prod_vt_write(vt: *mut c_void, data: *const u8, len: usize);
    pub fn prod_vt_checkpoint_export2(
        vt: *mut c_void,
        max_bytes: u64,
        buf: *mut u8,
        cap: usize,
        out_len: *mut usize,
    ) -> c_int;
    pub fn prod_vt_checkpoint_measure2(
        vt: *mut c_void,
        max_bytes: u64,
        out_len: *mut usize,
    ) -> c_int;
    pub fn prod_vt_checkpoint_import2(vt: *mut c_void, data: *const u8, len: usize) -> c_int;
}

pub fn keep_symbols() -> Vec<*const ()> {
    use tako_core::capi as c;
    vec![
        c::prod_vt_new as *const (),
        c::prod_vt_free as *const (),
        c::prod_vt_write as *const (),
        c::prod_vt_checkpoint_export2 as *const (),
        c::prod_vt_checkpoint_measure2 as *const (),
        c::prod_vt_checkpoint_import2 as *const (),
    ]
}

pub fn filled_terminal(lines: u32) -> *mut c_void {
    let vt = unsafe { prod_vt_new(120, 40, 20_000) };
    assert!(!vt.is_null());
    let mut text = Vec::new();
    for line in 0..lines {
        for col in 0..110u32 {
            text.push(
                b'a' + ((line.wrapping_mul(31).wrapping_add(col.wrapping_mul(7))) % 26) as u8,
            );
        }
        text.extend_from_slice(
            b"
",
        );
    }
    unsafe { prod_vt_write(vt, text.as_ptr(), text.len()) };
    vt
}

pub fn terminal_in_flight(intro: &[u8], payload: usize) -> *mut c_void {
    let vt = unsafe { prod_vt_new(80, 24, 100) };
    assert!(!vt.is_null());
    unsafe { prod_vt_write(vt, intro.as_ptr(), intro.len()) };
    let body = vec![b'x'; payload];
    unsafe { prod_vt_write(vt, body.as_ptr(), body.len()) };
    vt
}

pub fn export_exactly(vt: *mut c_void, size: usize) -> Vec<u8> {
    let mut buf = vec![0u8; size];
    let mut written: usize = 0;
    let status =
        unsafe { prod_vt_checkpoint_export2(vt, 0, buf.as_mut_ptr(), buf.len(), &mut written) };
    assert_eq!(
        status, PROD_VT_OK,
        "export of a {size}-byte checkpoint failed"
    );
    assert_eq!(written, size, "the size query and the export disagreed");
    buf
}

pub fn size_query(vt: *mut c_void) -> (c_int, usize, u64) {
    let mut size: usize = 0;
    let (status, cost) = bytes_allocated_by(|| unsafe {
        prod_vt_checkpoint_export2(vt, 0, std::ptr::null_mut(), 0, &mut size)
    });
    (status, size, cost)
}
