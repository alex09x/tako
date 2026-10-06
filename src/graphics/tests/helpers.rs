/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD as BASE64;

pub fn b64(bytes: &[u8]) -> String {
    BASE64.encode(bytes)
}

/// A PNG's first 33 bytes: signature, then the IHDR chunk with the size.
/// Enough for the header read; nothing here decodes pixels.
pub fn png_header(width: u32, height: u32) -> Vec<u8> {
    let mut png = b"\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR".to_vec();
    png.extend_from_slice(&width.to_be_bytes());
    png.extend_from_slice(&height.to_be_bytes());
    png.extend_from_slice(b"\x08\x06\x00\x00\x00\x00\x00\x00\x00");
    png
}
