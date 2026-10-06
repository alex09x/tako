/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

/// The largest image side taken from its own header: Metal's texture limit on
/// Apple GPUs. A few hundred bytes of PNG/JPEG/GIF can claim any size, and
/// downstream allocation must stay bounded.
pub const MAX_PNG_SIDE: u32 = 16_384;
pub const MAX_IMAGE_SIDE: u32 = MAX_PNG_SIDE;

/// Width and height from a PNG's IHDR chunk, which the format puts first:
/// the 8-byte signature, the chunk length, "IHDR", then width and height as
/// big-endian u32s. None for anything that is not a PNG of a drawable size.
pub fn png_dimensions(data: &[u8]) -> Option<(u32, u32)> {
    if data.len() < 24 || &data[..8] != b"\x89PNG\r\n\x1a\n" || &data[12..16] != b"IHDR" {
        return None;
    }
    let width = u32::from_be_bytes(data[16..20].try_into().ok()?);
    let height = u32::from_be_bytes(data[20..24].try_into().ok()?);
    let drawable = |side: u32| (1..=MAX_IMAGE_SIDE).contains(&side);
    (drawable(width) && drawable(height)).then_some((width, height))
}

/// Width and height from a GIF header (GIF87a / GIF89a).
/// Bytes 6..8 width (little-endian u16), bytes 8..10 height (little-endian u16).
pub fn gif_dimensions(data: &[u8]) -> Option<(u32, u32)> {
    if data.len() < 10 {
        return None;
    }
    if &data[..6] != b"GIF87a" && &data[..6] != b"GIF89a" {
        return None;
    }
    let width = u16::from_le_bytes(data[6..8].try_into().ok()?) as u32;
    let height = u16::from_le_bytes(data[8..10].try_into().ok()?) as u32;
    let drawable = |side: u32| (1..=MAX_IMAGE_SIDE).contains(&side);
    (drawable(width) && drawable(height)).then_some((width, height))
}

/// Width and height parsed from a JPEG Start Of Frame (SOF) marker.
pub fn jpeg_dimensions(data: &[u8]) -> Option<(u32, u32)> {
    if data.len() < 4 || data[0] != 0xFF || data[1] != 0xD8 {
        return None;
    }
    let mut i = 2;
    while i + 1 < data.len() {
        if data[i] != 0xFF {
            i += 1;
            continue;
        }
        while i < data.len() && data[i] == 0xFF {
            i += 1;
        }
        if i >= data.len() {
            break;
        }
        let marker = data[i];
        i += 1;
        if marker == 0xD8 || marker == 0xD9 || (0xD0..=0xD7).contains(&marker) || marker == 0x01 {
            continue;
        }
        if i + 2 > data.len() {
            break;
        }
        let len = u16::from_be_bytes(data[i..i + 2].try_into().ok()?) as usize;
        if len < 2 || i + len > data.len() {
            break;
        }
        if matches!(marker, 0xC0..=0xC3 | 0xC5..=0xC7 | 0xC9..=0xCB | 0xCD..=0xCF) {
            if len >= 7 && i + 7 <= data.len() {
                let height = u16::from_be_bytes(data[i + 3..i + 5].try_into().ok()?) as u32;
                let width = u16::from_be_bytes(data[i + 5..i + 7].try_into().ok()?) as u32;
                let drawable = |side: u32| (1..=MAX_IMAGE_SIDE).contains(&side);
                if drawable(width) && drawable(height) {
                    return Some((width, height));
                }
            }
            break;
        }
        i += len;
    }
    None
}

/// Width and height parsed from a WebP container.
pub fn webp_dimensions(data: &[u8]) -> Option<(u32, u32)> {
    if data.len() < 16 || &data[..4] != b"RIFF" || &data[8..12] != b"WEBP" {
        return None;
    }
    let chunk_type = &data[12..16];
    let drawable = |side: u32| (1..=MAX_IMAGE_SIDE).contains(&side);
    if chunk_type == b"VP8 " && data.len() >= 30 {
        if &data[23..26] == b"\x9d\x01\x2a" {
            let width = (u16::from_le_bytes(data[26..28].try_into().ok()?) & 0x3fff) as u32;
            let height = (u16::from_le_bytes(data[28..30].try_into().ok()?) & 0x3fff) as u32;
            if drawable(width) && drawable(height) {
                return Some((width, height));
            }
        }
    } else if chunk_type == b"VP8L" && data.len() >= 25 {
        if data[20] == 0x2f {
            let b1 = data[21] as u32;
            let b2 = data[22] as u32;
            let b3 = data[23] as u32;
            let b4 = data[24] as u32;
            let width = 1 + (b1 | ((b2 & 0x3f) << 8));
            let height = 1 + ((b2 >> 6) | (b3 << 2) | ((b4 & 0x0f) << 10));
            if drawable(width) && drawable(height) {
                return Some((width, height));
            }
        }
    } else if chunk_type == b"VP8X" && data.len() >= 30 {
        let width = 1 + (data[24] as u32 | ((data[25] as u32) << 8) | ((data[26] as u32) << 16));
        let height = 1 + (data[27] as u32 | ((data[28] as u32) << 8) | ((data[29] as u32) << 16));
        if drawable(width) && drawable(height) {
            return Some((width, height));
        }
    }
    None
}

/// Detect image dimensions from supported image formats (PNG, GIF, JPEG, WebP).
pub fn detect_image_dimensions(data: &[u8]) -> Option<(u32, u32)> {
    png_dimensions(data)
        .or_else(|| gif_dimensions(data))
        .or_else(|| jpeg_dimensions(data))
        .or_else(|| webp_dimensions(data))
}
