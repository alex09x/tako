/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

#[inline]
pub(crate) fn scan_printable_ascii_run(bytes: &[u8], start: usize) -> usize {
    if start >= bytes.len() {
        return start;
    }

    #[cfg(target_arch = "x86_64")]
    return unsafe { scan_printable_ascii_run_x86_64(bytes, start) };

    #[cfg(target_arch = "aarch64")]
    return scan_printable_ascii_run_aarch64(bytes, start);

    #[cfg(not(any(target_arch = "x86_64", target_arch = "aarch64")))]
    return scan_printable_ascii_run_scalar(bytes, start);
}

#[inline]
fn scan_printable_ascii_run_scalar(bytes: &[u8], mut offset: usize) -> usize {
    while offset < bytes.len() && matches!(bytes[offset], 0x20..=0x7F) {
        offset += 1;
    }
    offset
}

#[cfg(target_arch = "x86_64")]
#[inline]
unsafe fn scan_printable_ascii_run_x86_64(bytes: &[u8], mut offset: usize) -> usize {
    use std::arch::x86_64::{
        __m128i, _mm_cmpeq_epi8, _mm_loadu_si128, _mm_max_epu8, _mm_min_epu8, _mm_movemask_epi8,
        _mm_set1_epi8,
    };

    // SAFETY: SSE2 is part of the x86_64 baseline target feature set.
    let lower = unsafe { _mm_set1_epi8(0x20) };
    let upper = unsafe { _mm_set1_epi8(0x7F) };
    let len = bytes.len();
    let ptr = bytes.as_ptr();

    while offset + 16 <= len {
        // SAFETY: offset + 16 <= len guarantees the unaligned load is in-bounds;
        // all intrinsics used here require only baseline SSE2 on x86_64.
        let chunk = unsafe { _mm_loadu_si128(ptr.add(offset) as *const __m128i) };
        let run_high = unsafe { _mm_max_epu8(chunk, lower) };
        let run_in_range = unsafe { _mm_cmpeq_epi8(_mm_min_epu8(run_high, upper), chunk) };
        let mask = unsafe { _mm_movemask_epi8(run_in_range) as u32 };
        if mask == 0xFFFF {
            offset += 16;
            continue;
        }

        let first_invalid = (!mask & 0xFFFF).trailing_zeros() as usize;
        return offset + first_invalid;
    }

    scan_printable_ascii_run_scalar(bytes, offset)
}

#[cfg(target_arch = "aarch64")]
#[inline]
fn scan_printable_ascii_run_aarch64(bytes: &[u8], mut offset: usize) -> usize {
    use std::arch::aarch64::{
        uint8x16_t, vceqq_u8, vdupq_n_u8, vld1q_u8, vmaxq_u8, vminq_u8, vst1q_u8,
    };

    let lower = unsafe { vdupq_n_u8(0x20) };
    let upper = unsafe { vdupq_n_u8(0x7F) };
    let len = bytes.len();
    let mut block = [0u8; 16];
    let ptr = bytes.as_ptr();

    while offset + 16 <= len {
        // SAFETY: offset + 16 <= len guarantees this unaligned 16-byte load is in-bounds.
        let chunk: uint8x16_t = unsafe { vld1q_u8(ptr.add(offset)) };
        let run_high = unsafe { vmaxq_u8(chunk, lower) };
        let run_in_range = unsafe { vceqq_u8(chunk, vminq_u8(run_high, upper)) };

        // SAFETY: `block` is a valid 16-byte destination; this is only temporary stack storage.
        unsafe { vst1q_u8(block.as_mut_ptr(), run_in_range) };
        for (index, byte) in block.iter().enumerate() {
            if *byte == 0 {
                return offset + index;
            }
        }

        offset += 16;
    }

    scan_printable_ascii_run_scalar(bytes, offset)
}
