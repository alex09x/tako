/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::helpers::png_header;
use crate::graphics::*;

#[test]
fn detect_image_dimensions_handles_png_gif_jpeg_webp() {
    let png = png_header(120, 80);
    assert_eq!(detect_image_dimensions(&png), Some((120, 80)));

    let mut gif = b"GIF89a".to_vec();
    gif.extend_from_slice(&200_u16.to_le_bytes());
    gif.extend_from_slice(&150_u16.to_le_bytes());
    assert_eq!(detect_image_dimensions(&gif), Some((200, 150)));

    // Minimal valid JPEG SOF0 stream
    let mut jpeg = vec![0xFF, 0xD8]; // SOI
    jpeg.extend_from_slice(&[0xFF, 0xC0]); // SOF0
    let sof_len = 11_u16;
    jpeg.extend_from_slice(&sof_len.to_be_bytes());
    jpeg.push(8); // precision
    jpeg.extend_from_slice(&320_u16.to_be_bytes()); // height
    jpeg.extend_from_slice(&640_u16.to_be_bytes()); // width
    jpeg.push(3); // components
    jpeg.extend_from_slice(&[1, 0x11, 0, 2, 0x11, 0, 3, 0x11, 0]);
    assert_eq!(detect_image_dimensions(&jpeg), Some((640, 320)));

    // WebP VP8X extended header
    let mut webp = b"RIFF".to_vec();
    webp.extend_from_slice(&30_u32.to_le_bytes());
    webp.extend_from_slice(b"WEBPVP8X");
    webp.extend_from_slice(&10_u32.to_le_bytes()); // chunk size
    webp.extend_from_slice(&[0, 0, 0, 0]); // flags
    let w_minus_1 = 499_u32;
    let h_minus_1 = 299_u32;
    webp.extend_from_slice(&w_minus_1.to_le_bytes()[..3]);
    webp.extend_from_slice(&h_minus_1.to_le_bytes()[..3]);
    assert_eq!(detect_image_dimensions(&webp), Some((500, 300)));
}
