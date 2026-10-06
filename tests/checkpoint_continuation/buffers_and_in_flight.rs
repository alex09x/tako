/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::common::*;

#[test]
fn test_alternate_screen_history_styles_and_viewport() {
    let mut t = Terminal::new(15, 4);

    // Push 10 lines into scrollback with styles
    for i in 0..10 {
        let line = format!("\x1b[1;3{}mLine {}\r\n\x1b[0m", i % 8, i);
        t.feed(line.as_bytes());
    }

    // Switch to alternate screen and write text
    t.feed(b"\x1b[?1049h\x1b[1;31mAlt Screen Content\x1b[0m");
    assert_eq!(t.active_screen(), ScreenBuffer::Alternate);

    let ckpt = t.export_checkpoint().unwrap();
    let mut restored = Terminal::new(15, 4);
    restored.import_checkpoint(&ckpt).unwrap();

    assert_eq!(restored.active_screen(), ScreenBuffer::Alternate);
    assert_eq!(t.dump_text(), restored.dump_text());

    // Switch back to primary on restored
    restored.feed(b"\x1b[?1049l");
    t.feed(b"\x1b[?1049l");

    assert_eq!(restored.active_screen(), ScreenBuffer::Primary);
    assert_eq!(t.dump_text(), restored.dump_text());
    assert_eq!(
        t.active_grid().scrollback_len(),
        restored.active_grid().scrollback_len()
    );

    // Viewport scrolling
    t.scroll_viewport_up(3);
    let scrolled_ckpt = t.export_checkpoint().unwrap();
    let mut restored_scrolled = Terminal::new(15, 4);
    restored_scrolled.import_checkpoint(&scrolled_ckpt).unwrap();
    assert_eq!(restored_scrolled.viewport_offset(), 3);
    assert_eq!(t.dump_text(), restored_scrolled.dump_text());
}

// ----------------------------------------------------------------------------
// Regression Case 12: Malformed input, bounds checking, CRC and atomic rollback
// ----------------------------------------------------------------------------

#[test]
fn test_validation_malformed_and_atomic_rollback() {
    let mut term = Terminal::new(20, 6);
    term.feed(b"ORIGINAL STATE");
    let valid_ckpt = term.export_checkpoint().unwrap();

    // 1. Truncated buffers
    assert!(!Terminal::verify_checkpoint(&valid_ckpt[..10]));
    assert!(term.import_checkpoint(&valid_ckpt[..10]).is_err());
    assert_eq!(
        row_text(&term, 0),
        "ORIGINAL STATE",
        "state must be untouched"
    );

    // 2. Bad magic
    let mut bad_magic = valid_ckpt.clone();
    bad_magic[0..4].copy_from_slice(b"BAD!");
    assert!(!Terminal::verify_checkpoint(&bad_magic));
    assert!(term.import_checkpoint(&bad_magic).is_err());
    assert_eq!(row_text(&term, 0), "ORIGINAL STATE");

    // 3. Bad version
    let mut bad_version = valid_ckpt.clone();
    bad_version[4..8].copy_from_slice(&999u32.to_le_bytes());
    assert!(!Terminal::verify_checkpoint(&bad_version));
    assert!(term.import_checkpoint(&bad_version).is_err());
    assert_eq!(row_text(&term, 0), "ORIGINAL STATE");

    // 4. Corrupted CRC32
    let mut bad_crc = valid_ckpt.clone();
    let last = bad_crc.len() - 1;
    bad_crc[last] ^= 0xFF; // flip bits in payload
    assert!(!Terminal::verify_checkpoint(&bad_crc));
    assert!(term.import_checkpoint(&bad_crc).is_err());
    assert_eq!(row_text(&term, 0), "ORIGINAL STATE");

    // 5. C ABI null safety
    assert_eq!(
        prod_vt_restore(std::ptr::null_mut(), valid_ckpt.as_ptr(), valid_ckpt.len()),
        0
    );
    let vt = prod_vt_new(20, 6, 100);
    assert_eq!(prod_vt_restore(vt, std::ptr::null(), 100), 0);
    assert_eq!(prod_vt_restore(vt, valid_ckpt.as_ptr(), 0), 0);
    assert_eq!(
        prod_vt_checkpoint(
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null_mut()
        ),
        0
    );
    assert_eq!(prod_vt_checkpoint_verify(std::ptr::null(), 0), 0);
    assert_eq!(
        prod_vt_checkpoint_verify(bad_crc.as_ptr(), bad_crc.len()),
        0
    );
    assert_eq!(
        prod_vt_checkpoint_verify(valid_ckpt.as_ptr(), valid_ckpt.len()),
        1
    );

    prod_vt_free(vt);
}

#[test]
fn test_parser_intermediates_overflow_prevention_and_checkpoint_continuation() {
    let mut term = Terminal::new(20, 6);
    // Feed CSI with 300 intermediate characters (0x20 space).
    // Prior to fix, intermediate count exceeded 255 and wrapped u8 mod 256,
    // corrupting the wire format and reader stream.
    let mut seq = Vec::new();
    seq.extend_from_slice(b"\x1b[");
    seq.extend(std::iter::repeat_n(b' ', 300));
    term.feed(&seq);

    let ckpt = term.export_checkpoint().unwrap();
    assert!(Terminal::verify_checkpoint(&ckpt));

    let mut restored = Terminal::new(20, 6);
    assert!(restored.import_checkpoint(&ckpt).is_ok());

    // Verify parser state in restored terminal accepts further input cleanly:
    // 'm' completes the in-flight CSI sequence (which is ignored), returning parser to Ground,
    // and 'A' prints normally.
    restored.feed(b"mA");
    assert_eq!(row_text(&restored, 0), "A");
}

#[test]
fn test_kitty_graphics_lossless_checkpoint_continuation() {
    use base64::Engine as _;
    let mut term = Terminal::new(20, 6);

    // Position cursor at row 4, col 4
    term.feed(b"\x1b[5;5H");

    let pixel_orange = [0xFF_u8, 0x80, 0x00, 0xFF];
    let b64_orange = base64::engine::general_purpose::STANDARD.encode(pixel_orange);

    // 1. Transmit and display image ID 7
    let mut apc = Vec::new();
    apc.extend_from_slice(b"\x1b_Ga=T,t=d,f=32,s=1,v=1,i=7;");
    apc.extend_from_slice(b64_orange.as_bytes());
    apc.extend_from_slice(b"\x1b\\");
    term.feed(&apc);

    // 2. Transmit chunk 1 of a multi-chunk image (ID 9, m=1)
    let chunk1 = [0x11_u8, 0x22];
    let b64_chunk1 = base64::engine::general_purpose::STANDARD.encode(chunk1);
    let mut apc_chunk = Vec::new();
    apc_chunk.extend_from_slice(b"\x1b_Ga=t,t=d,f=24,s=1,v=1,i=9,m=1;");
    apc_chunk.extend_from_slice(b64_chunk1.as_bytes());
    apc_chunk.extend_from_slice(b"\x1b\\");
    term.feed(&apc_chunk);

    // Verify source terminal has placements and image 7
    let placements_src = term.graphics_placements();
    assert_eq!(placements_src.len(), 1);
    assert_eq!(placements_src[0].image_id, 7);
    assert_eq!(placements_src[0].row, 4);
    assert_eq!(placements_src[0].col, 4);
    assert_eq!(
        term.graphics_image(7).unwrap().pixels,
        pixel_orange.to_vec()
    );

    // Export checkpoint
    let ckpt = term.export_checkpoint().unwrap();
    assert!(Terminal::verify_checkpoint(&ckpt));

    // Restore into a fresh terminal
    let mut restored = Terminal::new(80, 24);
    assert!(restored.import_checkpoint(&ckpt).is_ok());

    // Verify restored terminal retains placements AND image data
    let placements_res = restored.graphics_placements();
    assert_eq!(placements_res.len(), 1);
    assert_eq!(placements_res[0].image_id, 7);
    assert_eq!(placements_res[0].row, 4);
    assert_eq!(placements_res[0].col, 4);

    let img_res = restored
        .graphics_image(7)
        .expect("image 7 must be restored");
    assert_eq!(img_res.pixels, pixel_orange.to_vec());
    assert_eq!(img_res.width, 1);
    assert_eq!(img_res.height, 1);
    assert_eq!(img_res.generation, 1);

    // 3. Complete chunk 2 for image 9 on the restored terminal (m=0)
    let chunk2 = [0x33_u8];
    let b64_chunk2 = base64::engine::general_purpose::STANDARD.encode(chunk2);
    let mut apc_chunk2 = Vec::new();
    apc_chunk2.extend_from_slice(b"\x1b_Ga=t,t=d,i=9,m=0;");
    apc_chunk2.extend_from_slice(b64_chunk2.as_bytes());
    apc_chunk2.extend_from_slice(b"\x1b\\");
    restored.feed(&apc_chunk2);

    let img9 = restored
        .graphics_image(9)
        .expect("image 9 should complete after restore");
    assert_eq!(img9.pixels, vec![0x11, 0x22, 0x33]);

    // Display image 9
    restored.feed(b"\x1b_Ga=p,i=9,p=2\x1b\\");
    assert_eq!(restored.graphics_placements().len(), 2);

    // 4. Delete image 7
    restored.feed(b"\x1b_Ga=d,d=i,i=7\x1b\\");
    assert!(restored.graphics_image(7).is_none());
    assert_eq!(restored.graphics_placements().len(), 1);
    assert_eq!(restored.graphics_placements()[0].image_id, 9);
}

// ----------------------------------------------------------------------------
// Regression Case 13: export/import symmetry for large in-flight parser buffers
//
// The parser accumulates an OSC or an APC payload with no size limit of its
// own. Export wrote those buffers unbounded while import read them back under
// fixed per-field ceilings (1 MiB / 16 MiB), so an honest checkpoint taken mid
// a large OSC 1337 inline image, or mid an unchunked Kitty APC transfer,
// exported fine, passed `verify_checkpoint` -- which only checks header and
// CRC -- and then deterministically failed to import.
//
// The rule proved here: for a state the parser can actually reach, either
// export succeeds and import accepts it, or export fails explicitly and the
// terminal is untouched. There is no third outcome.
// ----------------------------------------------------------------------------

/// A checkpoint taken while a >1 MiB OSC is still in flight round-trips.
#[test]
fn test_large_in_flight_osc_round_trips() {
    let mut term = Terminal::new(80, 24);
    // OSC 1337 inline image: opened, never terminated. 2 MiB of payload sits
    // in the parser's osc_raw when the checkpoint is taken.
    let mut seq = Vec::from(&b"\x1b]1337;File=inline=1;"[..]);
    seq.extend(std::iter::repeat_n(b'A', 2 * 1024 * 1024));
    term.feed(&seq);

    let ckpt = term.export_checkpoint().expect("export must succeed");
    assert!(Terminal::verify_checkpoint(&ckpt));

    let mut restored = Terminal::new(20, 6);
    restored
        .import_checkpoint(&ckpt)
        .expect("a checkpoint this build wrote must be one it can read");

    // The sequence still completes against the restored parser, and the
    // 2 MiB payload was neither truncated nor clipped: appending a further
    // marker and the terminator dispatches one whole OSC, printing nothing.
    restored.feed(b"MARKER\x07");
    assert_eq!(
        row_text(&restored, 0),
        "",
        "the OSC dispatched; nothing was printed"
    );
    assert_eq!(
        term.export_checkpoint().unwrap(),
        ckpt,
        "export does not mutate"
    );
}

/// The same for an unchunked Kitty APC transfer past the old 16 MiB ceiling.
#[test]
fn test_large_in_flight_apc_round_trips() {
    let mut term = Terminal::new(80, 24);
    let mut seq = Vec::from(&b"\x1b_Ga=T,f=32,s=1,v=1;"[..]);
    seq.extend(std::iter::repeat_n(b'B', 17 * 1024 * 1024));
    term.feed(&seq);

    let ckpt = term.export_checkpoint().expect("export must succeed");
    let mut restored = Terminal::new(20, 6);
    restored
        .import_checkpoint(&ckpt)
        .expect("an unchunked APC transfer must survive a round trip");

    restored.feed(b"\x1b\\");
    assert_eq!(
        row_text(&restored, 0),
        "",
        "the APC dispatched; nothing was printed"
    );
}

/// Export refuses, explicitly and without mutating, when the state cannot be
/// written under the declared limits -- rather than emitting a checkpoint that
/// import would reject.
#[test]
fn test_export_refuses_over_the_wire_cap_without_mutating() {
    use tako_core::terminal::checkpoint::{CheckpointError, MAX_CONTAINER_LEN, MAX_PAYLOAD_LEN};

    let mut term = Terminal::new(80, 24);
    let mut seq = Vec::from(&b"\x1b_G"[..]);
    seq.extend(std::iter::repeat_n(b'C', MAX_PAYLOAD_LEN + 1024));
    term.feed(&seq);

    let before = term.dump_text();
    match term.export_checkpoint() {
        Err(CheckpointError::TooLarge { size, limit }) => {
            // The cap is the whole container, header included -- the same
            // number import measures against, so a blob one side calls legal
            // is never one the other side refuses.
            assert_eq!(limit, MAX_CONTAINER_LEN as u64);
            assert!(size > limit, "the reported size is the real one: {size}");
        }
        other => panic!("expected TooLarge, got {other:?}"),
    }
    // Not truncated, not cleared, not reset: the parser still holds every byte,
    // and a second attempt reports exactly the same size.
    assert_eq!(term.dump_text(), before);
    let second = term.export_checkpoint();
    assert_eq!(second, term.export_checkpoint());
    assert!(matches!(second, Err(CheckpointError::TooLarge { .. })));
    // The terminal still works: the APC completes and prints nothing.
    term.feed(b"\x1b\\X");
    assert_eq!(row_text(&term, 0), "X");
}

/// A caller-supplied cap composes with the wire cap and fails the same way.
#[test]
fn test_export_refuses_at_a_caller_supplied_cap() {
    use tako_core::terminal::checkpoint::CheckpointError;

    let mut term = Terminal::new(80, 24);
    term.feed(b"bounded export");
    let full = term.export_checkpoint().unwrap();

    match term.export_checkpoint_limited(64) {
        Err(CheckpointError::TooLarge { size, limit }) => {
            assert_eq!(limit, 64);
            assert!(size > 64);
        }
        other => panic!("expected TooLarge, got {other:?}"),
    }
    // The refusal changed nothing: the same export comes back byte-identical.
    assert_eq!(term.export_checkpoint().unwrap(), full);

    // A cap above the payload is no obstacle.
    let ok = term
        .export_checkpoint_limited(full.len() as u64 * 4)
        .expect("a generous cap exports");
    assert_eq!(ok, full);

    // The C ABI carries the same bound.
    let vt = prod_vt_new(80, 24, 100);
    prod_vt_write(vt, b"bounded export".as_ptr(), 14);
    assert_eq!(
        unsafe { take_buffer(|o, l| prod_vt_checkpoint_export_limited(vt, 64, o, l)) },
        None
    );
    let big = unsafe { take_buffer(|o, l| prod_vt_checkpoint_export_limited(vt, 1 << 20, o, l)) }
        .expect("a generous cap exports through the C ABI too");
    assert!(Terminal::verify_checkpoint(&big));
    prod_vt_free(vt);
}
