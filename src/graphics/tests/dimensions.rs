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

fn sof(marker: u8, width: u16, height: u16) -> Vec<u8> {
    let mut seg = vec![0xFF, marker];
    seg.extend_from_slice(&11_u16.to_be_bytes());
    seg.push(8);
    seg.extend_from_slice(&height.to_be_bytes());
    seg.extend_from_slice(&width.to_be_bytes());
    seg.extend_from_slice(&[3, 1, 0x11, 0, 2, 0x11, 0]);
    seg
}

/// A JPEG's size sits in its first frame header, after whatever comes
/// before it: fill bytes, standalone markers and other segments.
#[test]
fn a_jpeg_is_measured_at_its_frame_header_past_what_precedes_it() {
    let mut jpeg = vec![0xFF, 0xD8, 0x00, 0xFF, 0xFF]; // SOI, a stray byte, fill bytes
    jpeg.extend_from_slice(&[0xD0]); // RST0, a standalone marker
    jpeg.extend_from_slice(&[0xFF, 0xE0, 0x00, 0x04, b'J', b'F']); // APP0 of 4 bytes, skipped
    jpeg.extend_from_slice(&sof(0xC2, 1024, 768)); // a progressive frame
    assert_eq!(jpeg_dimensions(&jpeg), Some((1024, 768)));

    // A frame of no size ends the search with nothing; so does running out of bytes.
    let mut empty = vec![0xFF, 0xD8];
    empty.extend_from_slice(&sof(0xC0, 0, 768));
    assert_eq!(jpeg_dimensions(&empty), None);
    assert_eq!(
        jpeg_dimensions(&[0xFF, 0xD8, 0xFF, 0xE0, 0x00]),
        None,
        "a segment cut short"
    );
    assert_eq!(
        jpeg_dimensions(&[0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x40, 1, 2]),
        None,
        "a segment longer than the data"
    );
    assert_eq!(
        jpeg_dimensions(&[0xFF, 0xD8, 0xFF, 0xFF]),
        None,
        "only fill bytes left"
    );
    assert_eq!(
        jpeg_dimensions(&[0x00, 0xD8, 0xFF, 0xC0]),
        None,
        "not a JPEG"
    );
}

fn riff(chunk: &[u8; 4], body: &[u8]) -> Vec<u8> {
    let mut webp = b"RIFF".to_vec();
    webp.extend_from_slice(&((body.len() + 8) as u32).to_le_bytes());
    webp.extend_from_slice(b"WEBP");
    webp.extend_from_slice(chunk);
    webp.extend_from_slice(&(body.len() as u32).to_le_bytes());
    webp.extend_from_slice(body);
    webp
}

#[test]
fn lossy_and_lossless_webp_report_their_frame_size() {
    // VP8: a 3-byte frame tag, the start code, then 14-bit width and height.
    let mut vp8 = vec![0x30, 0x01, 0x00, 0x9d, 0x01, 0x2a];
    vp8.extend_from_slice(&(640_u16 | 0xC000).to_le_bytes()); // scale bits are not size
    vp8.extend_from_slice(&480_u16.to_le_bytes());
    assert_eq!(webp_dimensions(&riff(b"VP8 ", &vp8)), Some((640, 480)));
    let mut no_start = vp8.clone();
    no_start[3] = 0;
    assert_eq!(
        webp_dimensions(&riff(b"VP8 ", &no_start)),
        None,
        "no start code, no size"
    );

    // VP8L: a signature byte, then width-1 in 14 bits and height-1 in the next 14.
    let (w, h) = (300_u32 - 1, 200_u32 - 1);
    let bits = w | (h << 14);
    let mut vp8l = vec![0x2f];
    vp8l.extend_from_slice(&bits.to_le_bytes());
    assert_eq!(webp_dimensions(&riff(b"VP8L", &vp8l)), Some((300, 200)));
    vp8l[0] = 0x00;
    assert_eq!(
        webp_dimensions(&riff(b"VP8L", &vp8l)),
        None,
        "no lossless signature"
    );

    // An extended canvas larger than any image Tako draws is not drawable.
    let mut vp8x = vec![0; 4];
    vp8x.extend_from_slice(&(MAX_IMAGE_SIDE).to_le_bytes()[..3]); // width MAX+1
    vp8x.extend_from_slice(&9_u32.to_le_bytes()[..3]);
    assert_eq!(webp_dimensions(&riff(b"VP8X", &vp8x)), None);
    assert_eq!(
        webp_dimensions(&riff(b"ALPH", &[0; 16])),
        None,
        "an unknown first chunk"
    );
    assert_eq!(webp_dimensions(b"RIFF\0\0\0\0WAVE"), None);
}

#[test]
fn gif_and_png_refuse_sizes_they_cannot_draw() {
    let gif = |magic: &[u8], w: u16, h: u16| {
        let mut g = magic.to_vec();
        g.extend_from_slice(&w.to_le_bytes());
        g.extend_from_slice(&h.to_le_bytes());
        g
    };
    assert_eq!(gif_dimensions(&gif(b"GIF87a", 16, 9)), Some((16, 9)));
    assert_eq!(gif_dimensions(&gif(b"GIF89a", 0, 9)), None, "no width");
    assert_eq!(
        gif_dimensions(&gif(b"GIF90a", 16, 9)),
        None,
        "not a GIF version"
    );
    assert_eq!(gif_dimensions(b"GIF89a\x10"), None, "cut short");

    assert_eq!(
        png_dimensions(&png_header(MAX_PNG_SIDE, 1)),
        Some((MAX_PNG_SIDE, 1))
    );
    assert_eq!(
        png_dimensions(&png_header(MAX_PNG_SIDE + 1, 1)),
        None,
        "too wide"
    );
    assert_eq!(detect_image_dimensions(b"plain text, not an image"), None);
}
