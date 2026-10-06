/*
 * tako — Terminal emulator core library
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use crate::ffi::{FfiImageFormat, TakoCore};
use crate::terminal::Terminal;
use base64::Engine as _;

#[test]
fn test_kitty_graphics_apc_transmit_and_display_records_placement() {
    let term = TakoCore::new(10, 6);
    term.feed(b"\x1b[5;5H".to_vec());

    let pixel = [0xFFu8, 0x80, 0x00, 0xFF];
    let payload = base64::engine::general_purpose::STANDARD.encode(pixel);
    let mut apc = Vec::new();
    apc.extend_from_slice(b"\x1b_Ga=T,t=d,f=32,s=1,v=1,i=7;");
    apc.extend_from_slice(payload.as_bytes());
    apc.extend_from_slice(b"\x1b\\");
    term.feed(apc);

    let placements = term.graphics_placements();
    assert_eq!(placements.len(), 1);
    assert_eq!(placements[0].image_id, 7);
    assert_eq!(placements[0].row, 4);
    assert_eq!(placements[0].col, 4);

    let image = term.graphics_image(7).unwrap();
    assert_eq!(image.pixels, pixel.to_vec());

    let metadata = term.graphics_image_metadata(7).unwrap();
    assert_eq!(metadata.format, FfiImageFormat::Rgba);
    assert_eq!(metadata.width, 1);
    assert_eq!(metadata.height, 1);
    assert_eq!(metadata.generation, 1);
}

#[test]
fn test_kitty_graphics_metadata_changes_on_replace_and_deletes_with_none() {
    let core = TakoCore::new(10, 6);
    core.feed(b"\x1b[5;5H".to_vec());

    let pixel_a = [0xFF_u8, 0x80, 0x00, 0xFF];
    let pixel_b = [0x00_u8, 0xFF, 0x80, 0x00];

    let mut apc = Vec::new();
    apc.extend_from_slice(b"\x1b_Ga=T,t=d,f=32,s=1,v=1,i=7;");
    apc.extend_from_slice(
        base64::engine::general_purpose::STANDARD
            .encode(pixel_a)
            .as_bytes(),
    );
    apc.extend_from_slice(b"\x1b\\");
    core.feed(apc);

    let first = core.graphics_image_metadata(7).unwrap();
    let first_image = core.graphics_image(7).unwrap();
    assert_eq!(first.width, 1);
    assert_eq!(first.height, 1);
    assert_eq!(first.format, FfiImageFormat::Rgba);
    assert_eq!(first.generation, 1);
    assert_eq!(first_image.pixels, pixel_a.to_vec());

    let mut apc = Vec::new();
    apc.extend_from_slice(b"\x1b_Ga=t,t=d,f=32,s=1,v=1,i=7;");
    apc.extend_from_slice(
        base64::engine::general_purpose::STANDARD
            .encode(pixel_b)
            .as_bytes(),
    );
    apc.extend_from_slice(b"\x1b\\");
    core.feed(apc);
    let second = core.graphics_image_metadata(7).unwrap();
    assert_eq!(second.generation, first.generation + 1);

    let mut delete = Vec::new();
    delete.extend_from_slice(b"\x1b_Ga=d,d=i,i=7;");
    delete.extend_from_slice(b"\x1b\\");
    core.feed(delete);

    assert!(core.graphics_image(7).is_none());
    assert!(core.graphics_image_metadata(7).is_none());

    let mut recreate = Vec::new();
    recreate.extend_from_slice(b"\x1b_Ga=t,t=d,f=32,s=1,v=1,i=7;");
    recreate.extend_from_slice(
        base64::engine::general_purpose::STANDARD
            .encode(pixel_a)
            .as_bytes(),
    );
    recreate.extend_from_slice(b"\x1b\\");
    core.feed(recreate);

    let third = core.graphics_image_metadata(7).unwrap();
    assert_eq!(third.generation, second.generation + 1);
    assert_eq!(core.graphics_image(7).unwrap().pixels, pixel_a.to_vec());
}

#[test]
fn test_kitty_graphics_query_and_response_control_drain_pty_replies() {
    let mut term = Terminal::new(80, 24);

    // Query support: a=q
    term.feed(b"\x1b_Ga=q,s=100,v=50,i=42;OK\x1b\\");
    let reply = String::from_utf8(term.take_output()).unwrap();
    assert_eq!(reply, "\x1b_Gi=42,s=100,v=50;OK\x1b\\");

    // Display image with response requested: q=2
    let pixel = [0x12_u8, 0x34, 0x56, 0x78];
    let payload = base64::engine::general_purpose::STANDARD.encode(pixel);
    let mut apc = Vec::new();
    apc.extend_from_slice(b"\x1b_Ga=T,t=d,f=32,s=1,v=1,i=99,q=2;");
    apc.extend_from_slice(payload.as_bytes());
    apc.extend_from_slice(b"\x1b\\");
    term.feed(&apc);

    let reply = String::from_utf8(term.take_output()).unwrap();
    assert_eq!(reply, "\x1b_Gi=99,p=0;OK\x1b\\");
}

#[test]
fn test_kitty_graphics_cursor_advancement_and_c1_suppression() {
    let mut term = Terminal::new(80, 24);
    term.feed(b"\x1b[2;1H"); // row 1, col 0

    let pixel = [0xFF_u8, 0x00, 0x00, 0xFF];
    let payload = base64::engine::general_purpose::STANDARD.encode(pixel);

    // 1. Placement without C=1 advances the cursor row by 2
    let mut apc = Vec::new();
    apc.extend_from_slice(b"\x1b_Ga=T,t=d,f=32,s=1,v=1,i=1,r=2;");
    apc.extend_from_slice(payload.as_bytes());
    apc.extend_from_slice(b"\x1b\\");
    term.feed(&apc);

    // Cursor should have advanced by r=2 rows: 1 + 2 = 3
    term.feed(b"NextLine");
    let snapshot = term.plain_string();
    let lines: Vec<&str> = snapshot.lines().collect();
    assert!(lines.len() >= 4);
    assert_eq!(lines[3], "NextLine");

    // 2. Placement with C=1 keeps cursor at same position
    term.feed(b"\x1b[10;1H");
    let mut apc2 = Vec::new();
    apc2.extend_from_slice(b"\x1b_Ga=T,t=d,f=32,s=1,v=1,i=2,C=1;");
    apc2.extend_from_slice(payload.as_bytes());
    apc2.extend_from_slice(b"\x1b\\");
    term.feed(&apc2);

    term.feed(b"SameRow");
    let snapshot = term.plain_string();
    let lines: Vec<&str> = snapshot.lines().collect();
    assert_eq!(lines[9], "SameRow");
}

#[test]
fn test_iterm2_inline_image_placement_and_cursor_advancement() {
    let mut term = Terminal::new(80, 24);
    term.feed(b"\x1b[3;1H"); // row 2, col 0

    // Construct a minimal PNG header (100x50)
    let mut png = b"\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR".to_vec();
    png.extend_from_slice(&100_u32.to_be_bytes());
    png.extend_from_slice(&50_u32.to_be_bytes());
    png.extend_from_slice(b"\x08\x06\x00\x00\x00\x00\x00\x00\x00");

    let b64_png = base64::engine::general_purpose::STANDARD.encode(&png);
    let osc = format!("\x1b]1337;File=inline=1;height=3:{b64_png}\x07");
    term.feed(osc.as_bytes());

    let placements = term.graphics_placements();
    assert_eq!(placements.len(), 1);
    assert_eq!(placements[0].row, 2);
    assert_eq!(placements[0].col, 0);

    let img = term
        .graphics_image(placements[0].image_id)
        .expect("image stored");
    assert_eq!(img.width, 100);
    assert_eq!(img.height, 50);

    // Cursor should have advanced by 3 rows
    term.feed(b"PromptBelow");
    let snapshot = term.plain_string();
    let lines: Vec<&str> = snapshot.lines().collect();
    assert!(lines.len() >= 6);
    assert_eq!(lines[5], "PromptBelow");
}

#[test]
fn test_iterm2_inline_image_respects_memory_cap() {
    let mut term = Terminal::new(80, 24);
    term.set_max_image_memory_bytes(1_000);

    let large_data = vec![0xAA_u8; 5_000];
    let b64 = base64::engine::general_purpose::STANDARD.encode(&large_data);
    let osc = format!("\x1b]1337;File=inline=1:{b64}\x07");
    term.feed(osc.as_bytes());

    // Because large_data exceeds 1,000 bytes cap, it was refused and not placed
    assert!(term.graphics_placements().is_empty());
}

#[test]
fn test_iterm2_huge_height_clamped_and_returns_promptly() {
    let mut term = Terminal::new(80, 24);
    let mut png = b"\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR".to_vec();
    png.extend_from_slice(&10_u32.to_be_bytes());
    png.extend_from_slice(&10_u32.to_be_bytes());
    png.extend_from_slice(b"\x08\x06\x00\x00\x00\x00\x00\x00\x00");

    let b64_png = base64::engine::general_purpose::STANDARD.encode(&png);
    // Attacker sends huge height (1,000,000,000 cells or pixels)
    let osc1 = format!("\x1b]1337;File=inline=1;height=1000000000:{b64_png}\x07");
    term.feed(osc1.as_bytes());

    let osc2 = format!("\x1b]1337;File=inline=1;height=1000000000px:{b64_png}\x07");
    term.feed(osc2.as_bytes());

    // Both should complete immediately without hanging or wrapping arithmetic
    assert_eq!(term.graphics_placements().len(), 2);
}

#[test]
fn test_kitty_graphics_huge_r_clamped_and_returns_promptly() {
    let mut term = Terminal::new(80, 24);
    let pixel = [0x55_u8, 0x66, 0x77, 0x88];
    let b64_pixel = base64::engine::general_purpose::STANDARD.encode(pixel);
    // Huge row count r=1000000000
    let apc = format!("\x1b_Ga=T,t=d,f=32,s=1,v=1,r=1000000000;{b64_pixel}\x1b\\");
    term.feed(apc.as_bytes());

    assert_eq!(term.graphics_placements().len(), 1);
}
