/*
 * tako — Terminal emulator core library
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use flate2::{Decompress, FlushDecompress, Status};

/// Inflate into a bounded allocation; a client controls both the compressed
/// stream and its expansion, so neither size is trusted.
pub(super) fn inflate(data: &[u8], limit: u64) -> Result<Vec<u8>, String> {
    let mut decoder = Decompress::new(true);
    let mut result = Vec::new();
    let mut chunk = [0u8; 16 * 1024];
    let mut consumed = 0usize;
    loop {
        let before_in = decoder.total_in();
        let before_out = decoder.total_out();
        let status = decoder
            .decompress(&data[consumed..], &mut chunk, FlushDecompress::None)
            .map_err(|_| "invalid zlib image data".to_string())?;
        let used = (decoder.total_in() - before_in) as usize;
        let n = (decoder.total_out() - before_out) as usize;
        consumed += used;
        let next = (result.len() as u64).saturating_add(n as u64);
        if next > limit {
            return Err("decompressed image exceeds per-pane memory cap".to_string());
        }
        result
            .try_reserve_exact(n)
            .map_err(|_| "cannot allocate decompressed image".to_string())?;
        if result.capacity() as u64 > limit {
            return Err("decompressed image exceeds per-pane memory cap".to_string());
        }
        result.extend_from_slice(&chunk[..n]);
        if status == Status::StreamEnd {
            break;
        }
        if used == 0 && n == 0 {
            return Err("truncated zlib image data".to_string());
        }
    }
    Ok(result)
}
