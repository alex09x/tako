/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

pub use std::alloc::{GlobalAlloc, Layout, System};
pub use std::cell::Cell;
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

#[global_allocator]
static ALLOCATOR: Counting = Counting;

pub fn arm_counter() {
    COUNTING.with(|on| on.set(true));
    ALLOCATED.with(|n| n.set(0));
    LIVE.with(|n| n.set(0));
}

pub fn disarm_counter() {
    COUNTING.with(|on| on.set(false));
}

pub fn live_bytes() -> i64 {
    LIVE.with(|n| n.get())
}

unsafe extern "C" {
    pub fn prod_vt_new(cols: u16, rows: u16, max_scrollback: usize) -> *mut c_void;
    pub fn prod_vt_free(vt: *mut c_void);
    pub fn prod_vt_write(vt: *mut c_void, data: *const u8, len: usize);
    pub fn prod_vt_discard_events(vt: *mut c_void);
    pub fn prod_vt_title(vt: *mut c_void, out: *mut *mut u8, out_len: *mut usize) -> c_int;
    pub fn prod_vt_viewport_text(vt: *mut c_void, out: *mut *mut u8, out_len: *mut usize) -> c_int;
    pub fn prod_vt_drain_responses(
        vt: *mut c_void,
        out: *mut *mut u8,
        out_len: *mut usize,
    ) -> c_int;
    pub fn prod_vt_buffer_free(data: *mut u8);
    pub fn prod_vt_checkpoint_export2(
        vt: *mut c_void,
        max_bytes: u64,
        buf: *mut u8,
        cap: usize,
        out_len: *mut usize,
    ) -> c_int;
    pub fn prod_vt_checkpoint_import2(vt: *mut c_void, data: *const u8, len: usize) -> c_int;
}

pub fn exported_symbol_addresses() -> Vec<*const ()> {
    use tako_core::capi as c;
    vec![
        c::prod_vt_new as *const (),
        c::prod_vt_free as *const (),
        c::prod_vt_write as *const (),
        c::prod_vt_discard_events as *const (),
        c::prod_vt_title as *const (),
        c::prod_vt_viewport_text as *const (),
        c::prod_vt_drain_responses as *const (),
        c::prod_vt_buffer_free as *const (),
        c::prod_vt_checkpoint_export2 as *const (),
        c::prod_vt_checkpoint_import2 as *const (),
    ]
}

/// Write a byte slice through the C ABI, taking the length from the slice itself.
///
/// Every write in this suite goes through here: a manually typed length is a
/// buffer overread waiting to happen, and the compiler cannot catch it.
pub unsafe fn write_seq(vt: *mut c_void, bytes: &[u8]) {
    unsafe { prod_vt_write(vt, bytes.as_ptr(), bytes.len()) };
}

/// Export a checkpoint through the two-call sizing protocol.
pub unsafe fn export_checkpoint(vt: *mut c_void) -> Vec<u8> {
    let mut needed: usize = 0;
    let st = unsafe { prod_vt_checkpoint_export2(vt, 0, std::ptr::null_mut(), 0, &mut needed) };
    assert_eq!(
        st, -2,
        "sizing probe must report PROD_VT_ERR_BUFFER_TOO_SMALL"
    );
    let mut buf = vec![0u8; needed];
    let mut written: usize = 0;
    let st =
        unsafe { prod_vt_checkpoint_export2(vt, 0, buf.as_mut_ptr(), buf.len(), &mut written) };
    assert_eq!(st, 0, "checkpoint export must succeed");
    assert_eq!(written, needed, "export must fill exactly the probed size");
    buf
}

pub unsafe fn take_buffer(f: impl FnOnce(*mut *mut u8, *mut usize) -> c_int) -> Option<Vec<u8>> {
    let mut ptr: *mut u8 = std::ptr::null_mut();
    let mut len: usize = 0;
    if f(&mut ptr, &mut len) == 0 {
        return None;
    }
    let out = if ptr.is_null() {
        Vec::new()
    } else {
        unsafe { std::slice::from_raw_parts(ptr, len) }.to_vec()
    };
    unsafe { prod_vt_buffer_free(ptr) };
    Some(out)
}
