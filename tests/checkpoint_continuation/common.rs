/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

pub(crate) use std::os::raw::c_int;
pub(crate) use tako_core::capi::*;
pub(crate) use tako_core::terminal::{ScreenBuffer, Terminal};

pub(crate) unsafe fn take_buffer(
    f: impl FnOnce(*mut *mut u8, *mut usize) -> c_int,
) -> Option<Vec<u8>> {
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
    prod_vt_buffer_free(ptr);
    Some(out)
}

pub(crate) fn row_text(term: &Terminal, row: usize) -> String {
    let grid = term.active_grid();
    (0..grid.cols())
        .map(|col| {
            let ch = grid.get(row, col).map(|c| c.char).unwrap_or(' ');
            if ch == '\0' { ' ' } else { ch }
        })
        .collect::<String>()
        .trim_end()
        .to_string()
}

pub(crate) fn reseal(mut ckpt: Vec<u8>) -> Vec<u8> {
    let crc = tako_core::terminal::checkpoint::crc32(&ckpt[20..]);
    ckpt[16..20].copy_from_slice(&crc.to_le_bytes());
    ckpt
}

pub(crate) fn peak_rss_bytes() -> u64 {
    unsafe {
        let mut usage: libc::rusage = std::mem::zeroed();
        if libc::getrusage(libc::RUSAGE_SELF, &mut usage) != 0 {
            return 0;
        }
        let raw = usage.ru_maxrss as u64;
        if cfg!(target_os = "macos") {
            raw
        } else {
            raw * 1024
        }
    }
}

pub(crate) fn as_v1_with_selection(
    v2: &[u8],
    anchor: (u32, u32),
    active: (u32, u32),
    mode: u8,
) -> Vec<u8> {
    let mut out = v2.to_vec();
    out.push(1); // selection present
    for v in [anchor.0, anchor.1, active.0, active.1] {
        out.extend_from_slice(&v.to_le_bytes());
    }
    out.push(mode);
    let payload_len = (out.len() - 20) as u32;
    out[4..8].copy_from_slice(&1u32.to_le_bytes());
    out[12..16].copy_from_slice(&payload_len.to_le_bytes());
    reseal(out)
}
