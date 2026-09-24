//! Deterministic regression and continuation test suite for TakoCore checkpoint/import
//! and ANSI snapshot fidelity.
//!
//! Covers:
//! 1. 20x6: twenty ASCII 'x', pending wrap, restored cursor position and next 'Y' wrap to (0, 1).
//! 2. 258x55: 55 rows joined CRLF, snapshot/checkpoint, then ASCII ' progress', tab stop safety,
//!    and zero extra history rows.
//! 3. 20x6: parser state continuation across snapshot/checkpoint (feed 'abcdefghijklmnop' + ESC[2,
//!    checkpoint, feed 'K' -> line erase, no literal 'K').
//! 4. 20x6: custom tab stops (CSI 3g CSI 5G HTS CSI 12G HTS CSI 3;2H foo, checkpoint, TAB Z).
//! 5. 20x6: scroll margins (rows one/two/three/four CRLF, CSI 2;5r CSI 4;3H, checkpoint, LF Z).
//! 6. 20x6: origin mode 6 with scroll margins and relative positioning.
//! 7. 20x6: saved cursor (CSI 2;3H ESC 7 CSI 4;5H, checkpoint, ESC 8 Z).
//! 8. Split chunks: chunks 1, 7, whole, and every single byte split of sequences across checkpoint.
//! 9. Partial UTF-8 multibyte sequences split across checkpoint boundary.
//! 10. Partial OSC title sequences split across checkpoint boundary.
//! 11. Alternate screen buffer, scrollback history with styles, and viewport offset preservation.
//! 12. Robust input validation, limits, corrupted CRC, bad magic/version, and atomic rollback on failure.

use std::os::raw::c_int;

use tako_core::capi::*;
use tako_core::terminal::{ScreenBuffer, Terminal};

unsafe fn take_buffer(f: impl FnOnce(*mut *mut u8, *mut usize) -> c_int) -> Option<Vec<u8>> {
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

fn row_text(term: &Terminal, row: usize) -> String {
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

// ----------------------------------------------------------------------------
// Regression Case 1: 20x6 twenty 'x' characters, pending wrap, and next 'Y'
// ----------------------------------------------------------------------------

#[test]
fn test_case_1_prod_vt_snapshot_ansi_preserves_legacy_byte_compatibility() {
    let vt = prod_vt_new(20, 6, 1000);
    assert!(!vt.is_null());

    let input = b"xxxxxxxxxxxxxxxxxxxx"; // 20 chars
    prod_vt_write(vt, input.as_ptr(), input.len());

    let mut cursor = ProdVtCursor { x: 0, y: 0, visible: 0 };
    assert_eq!(prod_vt_cursor_state(vt, &mut cursor), 1);
    assert_eq!((cursor.x, cursor.y), (19, 0), "source cursor must be at col 19, row 0");

    let snap = unsafe { take_buffer(|o, l| prod_vt_snapshot_ansi(vt, o, l)) }.expect("snapshot_ansi");

    // Existing Prod contract: prod_vt_snapshot_ansi emits all 6 rows separated by CRLF without
    // omitting trailing blank lines and without appending cursor positioning escape sequences.
    let crlf_count = snap.windows(2).filter(|&w| w == b"\r\n").count();
    assert_eq!(crlf_count, 5, "legacy snapshot_ansi must emit all rows (5 CRLFs for 6 rows)");
    assert!(!snap.ends_with(b"H"), "must not append cursor position escape");
    assert!(!snap.ends_with(b"?25l"), "must not append cursor visibility escape");

    // Replay of pure ANSI lines leaves cursor at (0, 5) — the exact historical baseline in operator finding #1.
    let restored_vt = prod_vt_new(20, 6, 1000);
    prod_vt_write(restored_vt, snap.as_ptr(), snap.len());
    let mut rest_cursor = ProdVtCursor { x: 0, y: 0, visible: 0 };
    assert_eq!(prod_vt_cursor_state(restored_vt, &mut rest_cursor), 1);
    assert_eq!(
        (rest_cursor.x, rest_cursor.y),
        (0, 5),
        "legacy ANSI replay moves cursor to (0, 5); native checkpoint is used for lossless continuation"
    );

    // Feeding 'Y' places it at (0, 5), matching the operator's documented finding #1
    prod_vt_write(restored_vt, b"Y".as_ptr(), 1);
    assert_eq!(prod_vt_cursor_state(restored_vt, &mut rest_cursor), 1);
    assert_eq!(
        (rest_cursor.x, rest_cursor.y),
        (1, 5),
        "next Y placed at row 5 in legacy ANSI replay, reproducing operator finding #1"
    );

    prod_vt_free(vt);
    prod_vt_free(restored_vt);
}

#[test]
fn test_case_1_twenty_x_pending_wrap_and_next_y_via_c_abi_snapshot_v2() {
    let vt = prod_vt_new(20, 6, 1000);
    assert!(!vt.is_null());

    let input = b"xxxxxxxxxxxxxxxxxxxx"; // 20 chars
    prod_vt_write(vt, input.as_ptr(), input.len());

    let mut cursor = ProdVtCursor { x: 0, y: 0, visible: 0 };
    assert_eq!(prod_vt_cursor_state(vt, &mut cursor), 1);
    assert_eq!((cursor.x, cursor.y), (19, 0), "source cursor must be at col 19, row 0");

    let snap = unsafe { take_buffer(|o, l| prod_vt_snapshot_ansi_v2(vt, o, l)) }.expect("snapshot_ansi_v2");

    // Replay snapshot_v2 into a fresh TakoCore
    let restored_vt = prod_vt_new(20, 6, 1000);
    prod_vt_write(restored_vt, snap.as_ptr(), snap.len());

    let mut rest_cursor = ProdVtCursor { x: 0, y: 0, visible: 0 };
    assert_eq!(prod_vt_cursor_state(restored_vt, &mut rest_cursor), 1);
    assert_eq!(
        (rest_cursor.x, rest_cursor.y),
        (19, 0),
        "restored cursor must be at col 19, row 0 with pending wrap, not (0, 5)"
    );

    // Feed next 'Y' into both source and restored
    prod_vt_write(vt, b"Y".as_ptr(), 1);
    prod_vt_write(restored_vt, b"Y".as_ptr(), 1);

    assert_eq!(prod_vt_cursor_state(vt, &mut cursor), 1);
    assert_eq!(prod_vt_cursor_state(restored_vt, &mut rest_cursor), 1);
    assert_eq!(
        (cursor.x, cursor.y),
        (1, 1),
        "source cursor after wrap must be at col 1, row 1"
    );
    assert_eq!(
        (rest_cursor.x, rest_cursor.y),
        (cursor.x, cursor.y),
        "restored cursor must match source cursor at col 1, row 1"
    );

    let src_text = unsafe { take_buffer(|o, l| prod_vt_viewport_text(vt, o, l)) }.unwrap();
    let rest_text = unsafe { take_buffer(|o, l| prod_vt_viewport_text(restored_vt, o, l)) }.unwrap();
    assert_eq!(src_text, rest_text);
    assert_eq!(String::from_utf8(rest_text).unwrap(), "xxxxxxxxxxxxxxxxxxxx\nY");

    prod_vt_free(vt);
    prod_vt_free(restored_vt);
}

#[test]
fn test_case_1_twenty_x_pending_wrap_and_next_y_via_native_checkpoint() {
    let vt = prod_vt_new(20, 6, 1000);
    let input = b"xxxxxxxxxxxxxxxxxxxx";
    prod_vt_write(vt, input.as_ptr(), input.len());

    let ckpt = unsafe { take_buffer(|o, l| prod_vt_checkpoint(vt, o, l)) }.expect("checkpoint");
    assert!(prod_vt_checkpoint_verify(ckpt.as_ptr(), ckpt.len()) == 1);

    let restored_vt = prod_vt_new(20, 6, 1000);
    assert_eq!(prod_vt_restore(restored_vt, ckpt.as_ptr(), ckpt.len()), 1);

    // Feed 'Y'
    prod_vt_write(vt, b"Y".as_ptr(), 1);
    prod_vt_write(restored_vt, b"Y".as_ptr(), 1);

    let mut cur1 = ProdVtCursor { x: 0, y: 0, visible: 0 };
    let mut cur2 = ProdVtCursor { x: 0, y: 0, visible: 0 };
    assert_eq!(prod_vt_cursor_state(vt, &mut cur1), 1);
    assert_eq!(prod_vt_cursor_state(restored_vt, &mut cur2), 1);
    assert_eq!((cur1.x, cur1.y), (1, 1));
    assert_eq!((cur2.x, cur2.y), (1, 1));

    let src_text = unsafe { take_buffer(|o, l| prod_vt_viewport_text(vt, o, l)) }.unwrap();
    let rest_text = unsafe { take_buffer(|o, l| prod_vt_viewport_text(restored_vt, o, l)) }.unwrap();
    assert_eq!(src_text, rest_text);

    prod_vt_free(vt);
    prod_vt_free(restored_vt);
}

// ----------------------------------------------------------------------------
// Regression Case 2: 258x55 row 0..54 joined CRLF, snapshot, then ' progress'
// ----------------------------------------------------------------------------

#[test]
fn test_case_2_258x55_rows_progress_no_extra_history_row() {
    let vt = prod_vt_new(258, 55, 10000);
    assert!(!vt.is_null());

    let mut lines = Vec::new();
    for i in 0..55 {
        lines.push(i.to_string());
    }
    let joined = lines.join("\r\n");
    prod_vt_write(vt, joined.as_bytes().as_ptr(), joined.len());

    let mut scrollbar = ProdVtScrollbar { total: 0, offset: 0, len: 0 };
    assert_eq!(prod_vt_scrollbar_state(vt, &mut scrollbar), 1);
    assert_eq!(scrollbar.len, 55);
    assert_eq!(scrollbar.total, 55, "initial scrollback must be 0");

    let mut cursor = ProdVtCursor { x: 0, y: 0, visible: 0 };
    assert_eq!(prod_vt_cursor_state(vt, &mut cursor), 1);
    assert_eq!(cursor.y, 54, "cursor row must be 54 (last row)");
    assert_eq!(cursor.x, 2, "cursor col must be 2 after '54'");

    // Test native checkpoint, legacy snapshot_ansi, and snapshot_ansi_v2
    let ckpt = unsafe { take_buffer(|o, l| prod_vt_checkpoint(vt, o, l)) }.expect("checkpoint");
    let snap = unsafe { take_buffer(|o, l| prod_vt_snapshot_ansi(vt, o, l)) }.expect("snapshot_ansi");
    let snap_v2 = unsafe { take_buffer(|o, l| prod_vt_snapshot_ansi_v2(vt, o, l)) }.expect("snapshot_ansi_v2");

    for (desc, is_ckpt, payload) in [
        ("native_checkpoint", true, ckpt),
        ("snapshot_ansi", false, snap),
        ("snapshot_ansi_v2", false, snap_v2),
    ] {
        let restored_vt = prod_vt_new(258, 55, 10000);
        if is_ckpt {
            assert_eq!(prod_vt_restore(restored_vt, payload.as_ptr(), payload.len()), 1);
        } else {
            prod_vt_write(restored_vt, payload.as_ptr(), payload.len());
        }

        let mut rest_cursor = ProdVtCursor { x: 0, y: 0, visible: 0 };
        assert_eq!(prod_vt_cursor_state(restored_vt, &mut rest_cursor), 1);
        assert_ne!(rest_cursor.x, 256, "{desc}: cursor must NOT be at final tab stop 256");
        assert_eq!(
            (rest_cursor.x, rest_cursor.y),
            (2, 54),
            "{desc}: cursor must be at col 2, row 54"
        );

        let mut rest_bar = ProdVtScrollbar { total: 0, offset: 0, len: 0 };
        assert_eq!(prod_vt_scrollbar_state(restored_vt, &mut rest_bar), 1);
        assert_eq!(rest_bar.total, 55, "{desc}: restored scrollback must be 0");

        // Feed ASCII ' progress' (9 chars)
        let prog = b" progress";
        prod_vt_write(restored_vt, prog.as_ptr(), prog.len());

        assert_eq!(prod_vt_scrollbar_state(restored_vt, &mut rest_bar), 1);
        assert_eq!(
            rest_bar.total, 55,
            "{desc}: space+progress must NOT create an extra history row!"
        );

        assert_eq!(prod_vt_cursor_state(restored_vt, &mut rest_cursor), 1);
        assert_eq!(
            (rest_cursor.x, rest_cursor.y),
            (11, 54),
            "{desc}: cursor must advance to col 11 on row 54"
        );

        prod_vt_free(restored_vt);
    }

    prod_vt_free(vt);
}

// ----------------------------------------------------------------------------
// Regression Case 3: Parser state continuation across checkpoint inside sequence
// ----------------------------------------------------------------------------

#[test]
fn test_case_3_snapshot_boundary_inside_parser_sequence_preserves_erase() {
    let mut source = Terminal::new(20, 6);
    let mut restored = Terminal::new(20, 6);

    // Feed 16 characters plus ESC [ 2
    let prefix = b"abcdefghijklmnop\x1b[2";
    source.feed(prefix);

    // Export checkpoint with parser in CsiParam state
    let checkpoint = source.export_checkpoint().unwrap();
    assert!(Terminal::verify_checkpoint(&checkpoint));

    // Restore into fresh terminal
    assert!(restored.import_checkpoint(&checkpoint).is_ok());

    // Feed 'K' to both source and restored
    source.feed(b"K");
    restored.feed(b"K");

    // Both must execute CSI 2 K (erase entire line)
    assert_eq!(
        row_text(&source, 0),
        "",
        "source row 0 must be erased by CSI 2 K"
    );
    assert_eq!(
        row_text(&restored, 0),
        "",
        "restored row 0 must be erased by CSI 2 K, not hold literal 'K'"
    );

    assert_eq!(source.cursor(), (0, 16));
    assert_eq!(restored.cursor(), (0, 16));
    assert_eq!(source.dump_text(), restored.dump_text());
}

// ----------------------------------------------------------------------------
// Regression Cases 4-7: Custom tabs, scroll margins, origin mode, saved cursor
// ----------------------------------------------------------------------------

#[test]
fn test_case_4_custom_tabs_preserved() {
    let mut source = Terminal::new(20, 6);
    // custom tabs: CSI3g CSI5G HTS CSI12G HTS CSI3;2H foo
    source.feed(b"\x1b[3g\x1b[5G\x1bH\x1b[12G\x1bH\x1b[3;2Hfoo");

    let ckpt = source.export_checkpoint().unwrap();
    let mut restored = Terminal::new(20, 6);
    restored.import_checkpoint(&ckpt).unwrap();

    // then TAB Z
    source.feed(b"\tZ");
    restored.feed(b"\tZ");

    assert_eq!(source.cursor(), restored.cursor());
    assert_eq!(row_text(&source, 2), row_text(&restored, 2));
    assert_eq!(source.dump_text(), restored.dump_text());
}

#[test]
fn test_case_5_scroll_margins_preserved() {
    let mut source = Terminal::new(20, 6);
    // rows one/two/three/four joined CRLF then CSI2;5r CSI4;3H
    source.feed(b"one\r\ntwo\r\nthree\r\nfour\x1b[2;5r\x1b[4;3H");

    let ckpt = source.export_checkpoint().unwrap();
    let mut restored = Terminal::new(20, 6);
    restored.import_checkpoint(&ckpt).unwrap();

    // then LF Z
    source.feed(b"\nZ");
    restored.feed(b"\nZ");

    assert_eq!(source.cursor(), restored.cursor());
    assert_eq!(source.dump_text(), restored.dump_text());
}

#[test]
fn test_case_6_origin_mode_with_scroll_margins() {
    let mut source = Terminal::new(20, 6);
    // origin mode 6: CSI ? 6 h, margins 2..5, relative CSI 3;3H
    source.feed(b"one\r\ntwo\r\nthree\r\nfour\x1b[?6h\x1b[2;5r\x1b[3;3H");

    let ckpt = source.export_checkpoint().unwrap();
    let mut restored = Terminal::new(20, 6);
    restored.import_checkpoint(&ckpt).unwrap();

    // then LF Z
    source.feed(b"\nZ");
    restored.feed(b"\nZ");

    assert_eq!(source.cursor(), restored.cursor());
    assert_eq!(source.dump_text(), restored.dump_text());
}

#[test]
fn test_case_7_saved_cursor_preserved() {
    let mut source = Terminal::new(20, 6);
    // saved cursor: CSI 2;3H ESC 7 CSI 4;5H
    source.feed(b"\x1b[2;3H\x1b7\x1b[4;5H");

    let ckpt = source.export_checkpoint().unwrap();
    let mut restored = Terminal::new(20, 6);
    restored.import_checkpoint(&ckpt).unwrap();

    // then ESC 8 Z
    source.feed(b"\x1b8Z");
    restored.feed(b"\x1b8Z");

    assert_eq!(source.cursor(), (1, 3));
    assert_eq!(restored.cursor(), (1, 3));
    assert_eq!(source.dump_text(), restored.dump_text());
}

// ----------------------------------------------------------------------------
// Regression Case 8: Chunks 1, 7, whole and every single split boundary
// ----------------------------------------------------------------------------

#[test]
fn test_every_split_boundary_across_checkpoint() {
    // Test the minimal sequence split at every possible byte boundary
    let seq = b"abcdefghijklmnop\x1b[2K";

    for split in 1..seq.len() {
        let (first, second) = seq.split_at(split);

        let mut source = Terminal::new(20, 6);
        source.feed(seq);

        let mut stream = Terminal::new(20, 6);
        stream.feed(first);

        let ckpt = stream.export_checkpoint().unwrap();
        assert!(Terminal::verify_checkpoint(&ckpt));

        let mut restored = Terminal::new(20, 6);
        restored.import_checkpoint(&ckpt).unwrap();
        restored.feed(second);

        assert_eq!(
            source.dump_text(),
            restored.dump_text(),
            "mismatch when split at byte index {split}"
        );
        assert_eq!(
            source.cursor(),
            restored.cursor(),
            "cursor mismatch when split at byte index {split}"
        );
    }
}

#[test]
fn test_chunks_1_and_7_feed() {
    let seq = b"\x1b[3g\x1b[5G\x1bH\x1b[12G\x1bH\x1b[3;2Hfoo\tZ\x1b[2;5r\x1b[4;3H\nZ\x1b[2;3H\x1b7\x1b[4;5H\x1b8W";

    for chunk_size in [1usize, 7, seq.len()] {
        let mut t1 = Terminal::new(20, 6);
        for chunk in seq.chunks(chunk_size) {
            t1.feed(chunk);
            // Checkpoint and restore mid-stream
            let ckpt = t1.export_checkpoint().unwrap();
            let mut t2 = Terminal::new(20, 6);
            t2.import_checkpoint(&ckpt).unwrap();
            assert_eq!(t1.dump_text(), t2.dump_text());
            assert_eq!(t1.cursor(), t2.cursor());
            t1 = t2;
        }
    }
}

// ----------------------------------------------------------------------------
// Regression Case 9 & 10: Partial UTF-8 and OSC sequences split across checkpoint
// ----------------------------------------------------------------------------

#[test]
fn test_partial_utf8_split_across_checkpoint() {
    // 4-byte UTF-8 emoji: 🦀 (crab) = [0xF0, 0x9F, 0xA6, 0x80]
    let crab = "🦀".as_bytes();
    assert_eq!(crab.len(), 4);

    for split in 1..4 {
        let (p1, p2) = crab.split_at(split);

        let mut t1 = Terminal::new(20, 6);
        t1.feed(p1);

        let ckpt = t1.export_checkpoint().unwrap();
        let mut t2 = Terminal::new(20, 6);
        t2.import_checkpoint(&ckpt).unwrap();
        t2.feed(p2);

        assert_eq!(row_text(&t2, 0), "🦀");
    }

    // 3-byte UTF-8 Euro symbol: € = [0xE2, 0x82, 0xAC]
    let euro = "€".as_bytes();
    for split in 1..3 {
        let (p1, p2) = euro.split_at(split);

        let mut t1 = Terminal::new(20, 6);
        t1.feed(p1);

        let ckpt = t1.export_checkpoint().unwrap();
        let mut t2 = Terminal::new(20, 6);
        t2.import_checkpoint(&ckpt).unwrap();
        t2.feed(p2);

        assert_eq!(row_text(&t2, 0), "€");
    }
}

#[test]
fn test_partial_osc_title_split_across_checkpoint() {
    let part1 = b"\x1b]0;checkpoint ";
    let part2 = b"title test\x07";

    let mut t1 = Terminal::new(20, 6);
    t1.feed(part1);

    let ckpt = t1.export_checkpoint().unwrap();
    let mut t2 = Terminal::new(20, 6);
    t2.import_checkpoint(&ckpt).unwrap();
    t2.feed(part2);

    assert_eq!(t2.title(), "checkpoint title test");
}

// ----------------------------------------------------------------------------
// Regression Case 11: Alternate screen, scrollback history, styles, viewport
// ----------------------------------------------------------------------------

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
    assert_eq!(t.active_grid().scrollback_len(), restored.active_grid().scrollback_len());

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
    assert_eq!(row_text(&term, 0), "ORIGINAL STATE", "state must be untouched");

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
    assert_eq!(prod_vt_restore(std::ptr::null_mut(), valid_ckpt.as_ptr(), valid_ckpt.len()), 0);
    let vt = prod_vt_new(20, 6, 100);
    assert_eq!(prod_vt_restore(vt, std::ptr::null(), 100), 0);
    assert_eq!(prod_vt_restore(vt, valid_ckpt.as_ptr(), 0), 0);
    assert_eq!(prod_vt_checkpoint(std::ptr::null_mut(), std::ptr::null_mut(), std::ptr::null_mut()), 0);
    assert_eq!(prod_vt_checkpoint_verify(std::ptr::null(), 0), 0);
    assert_eq!(prod_vt_checkpoint_verify(bad_crc.as_ptr(), bad_crc.len()), 0);
    assert_eq!(prod_vt_checkpoint_verify(valid_ckpt.as_ptr(), valid_ckpt.len()), 1);

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
    assert_eq!(term.graphics_image(7).unwrap().pixels, pixel_orange.to_vec());

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

    let img_res = restored.graphics_image(7).expect("image 7 must be restored");
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

    let img9 = restored.graphics_image(9).expect("image 9 should complete after restore");
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
    assert_eq!(row_text(&restored, 0), "", "the OSC dispatched; nothing was printed");
    assert_eq!(term.export_checkpoint().unwrap(), ckpt, "export does not mutate");
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
    assert_eq!(row_text(&restored, 0), "", "the APC dispatched; nothing was printed");
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
    let big = unsafe {
        take_buffer(|o, l| prod_vt_checkpoint_export_limited(vt, 1 << 20, o, l))
    }
    .expect("a generous cap exports through the C ABI too");
    assert!(Terminal::verify_checkpoint(&big));
    prod_vt_free(vt);
}

// ----------------------------------------------------------------------------
// Regression Case 14: every declared count is bounded before it allocates
// ----------------------------------------------------------------------------

/// Re-stamp the CRC so a forged payload is indistinguishable from an honest
/// one to every check but the ones under test. CRC32 is an integrity check,
/// not an authenticity one.
fn reseal(mut ckpt: Vec<u8>) -> Vec<u8> {
    let crc = tako_core::terminal::checkpoint::crc32(&ckpt[20..]);
    ckpt[16..20].copy_from_slice(&crc.to_le_bytes());
    ckpt
}

/// A forged out-of-range tab-stop column count is rejected by the same bound
/// the geometry gets, before it reserves anything.
#[test]
fn test_forged_tab_cols_is_rejected_before_allocating() {
    use tako_core::terminal::checkpoint::{self, CheckpointError, MAX_DIM};

    let mut term = Terminal::new(200, 50);
    term.feed(b"forged tab cols");
    let valid = term.export_checkpoint().unwrap();

    // Where the decoder itself found the field -- no offset arithmetic that
    // could drift from the format.
    let (_, offsets) = checkpoint::import_traced(&valid).expect("the honest checkpoint imports");
    assert_eq!(
        u32::from_le_bytes(valid[offsets.tab_cols..offsets.tab_cols + 4].try_into().unwrap()),
        200,
        "export writes tab_cols == cols"
    );

    // A count the payload can still satisfy bitset-wise, but far past MAX_DIM.
    let mut forged = valid.clone();
    forged[offsets.tab_cols..offsets.tab_cols + 4].copy_from_slice(&30_000u32.to_le_bytes());
    let forged = reseal(forged);
    assert!(Terminal::verify_checkpoint(&forged), "header and CRC still check out");

    let mut dest = Terminal::new(20, 6);
    dest.feed(b"DESTINATION");
    assert_eq!(
        dest.import_checkpoint(&forged),
        Err(CheckpointError::DimensionOutOfBounds {
            cols: 30_000,
            rows: 50
        })
    );
    const { assert!(30_000 > MAX_DIM) };
    assert_eq!(row_text(&dest, 0), "DESTINATION", "fail-intact");

    // And a count that would drive a gigabyte allocation is refused too.
    let mut huge = valid.clone();
    huge[offsets.tab_cols..offsets.tab_cols + 4].copy_from_slice(&1_000_000_000u32.to_le_bytes());
    assert!(matches!(
        dest.import_checkpoint(&reseal(huge)),
        Err(CheckpointError::DimensionOutOfBounds { .. })
    ));
}

/// A forged scrollback row count cannot outrun the payload that declares it.
#[test]
fn test_forged_scrollback_count_is_bounded_by_the_payload() {
    use tako_core::terminal::checkpoint::CheckpointError;

    let mut term = Terminal::new(80, 24);
    term.feed(b"scrollback bound");
    let valid = term.export_checkpoint().unwrap();

    // The primary grid's scrollback length is the third u32 after the
    // geometry/margins block; find it by value rather than by arithmetic.
    let payload = &valid[20..];
    let cap_off = payload
        .windows(4)
        .position(|w| w == 10_000u32.to_le_bytes())
        .expect("scrollback capacity is in the payload");
    let sb_len_off = 20 + cap_off + 4 + 8;
    assert_eq!(
        u32::from_le_bytes(valid[sb_len_off..sb_len_off + 4].try_into().unwrap()),
        0,
        "a fresh terminal has no scrollback"
    );

    let mut forged = valid.clone();
    forged[sb_len_off..sb_len_off + 4].copy_from_slice(&900_000u32.to_le_bytes());
    let forged = reseal(forged);

    let mut dest = Terminal::new(20, 6);
    dest.feed(b"DESTINATION");
    assert_eq!(dest.import_checkpoint(&forged), Err(CheckpointError::UnexpectedEof));
    assert_eq!(row_text(&dest, 0), "DESTINATION", "fail-intact");
}

// ----------------------------------------------------------------------------
// Regression Case 15: explicit version negotiation
// ----------------------------------------------------------------------------

#[test]
fn test_version_negotiation_is_explicit() {
    use tako_core::terminal::checkpoint::CheckpointError;

    assert_eq!(Terminal::checkpoint_version(), 3);
    // v1 and v2 stay readable -- a peer holding an older container is not
    // forced to discard it -- while v3 is what this build writes.
    assert!(Terminal::checkpoint_supports(1));
    assert!(Terminal::checkpoint_supports(2));
    assert!(Terminal::checkpoint_supports(3));
    assert!(!Terminal::checkpoint_supports(0));
    assert!(!Terminal::checkpoint_supports(4));
    assert!(!Terminal::checkpoint_supports(u32::MAX));

    assert_eq!(prod_vt_checkpoint_version(), 3);
    assert_eq!(prod_vt_checkpoint_supports(1), 1);
    assert_eq!(prod_vt_checkpoint_supports(2), 1);
    assert_eq!(prod_vt_checkpoint_supports(3), 1);
    assert_eq!(prod_vt_checkpoint_supports(4), 0);

    let mut term = Terminal::new(40, 10);
    term.feed(b"negotiate");
    let valid = term.export_checkpoint().unwrap();

    // A container from a newer peer: intact, correctly checksummed, and
    // unreadable here. That has to come back as a version failure, not as
    // corruption -- the two call for different decisions.
    let mut newer = valid.clone();
    newer[4..8].copy_from_slice(&4u32.to_le_bytes());
    let newer = reseal(newer);

    let mut dest = Terminal::new(20, 6);
    dest.feed(b"DESTINATION");
    assert_eq!(
        dest.import_checkpoint(&newer),
        Err(CheckpointError::UnsupportedVersion(4))
    );
    assert_eq!(
        Terminal::inspect_checkpoint(&newer),
        Err(CheckpointError::UnsupportedVersion(4))
    );
    assert_eq!(row_text(&dest, 0), "DESTINATION", "fail-intact");

    // Corruption is still corruption, and says so differently.
    let mut corrupt = valid.clone();
    let last = corrupt.len() - 1;
    corrupt[last] ^= 0xFF;
    assert!(matches!(
        dest.import_checkpoint(&corrupt),
        Err(CheckpointError::ChecksumMismatch { .. })
    ));

    // Inspect reports what an honest container declares, without decoding it.
    let info = Terminal::inspect_checkpoint(&valid).unwrap();
    assert_eq!((info.version, info.cols, info.rows), (3, 40, 10));
    assert_eq!(info.payload_len as usize, valid.len() - 20);

    let mut c_version = 0u32;
    let mut c_cols = 0u32;
    let mut c_rows = 0u32;
    let mut c_len = 0u32;
    assert_eq!(
        prod_vt_checkpoint_inspect(
            valid.as_ptr(),
            valid.len(),
            &mut c_version,
            &mut c_cols,
            &mut c_rows,
            &mut c_len,
        ),
        1
    );
    assert_eq!((c_version, c_cols, c_rows), (3, 40, 10));
    assert_eq!(
        prod_vt_checkpoint_inspect(
            newer.as_ptr(),
            newer.len(),
            &mut c_version,
            &mut c_cols,
            &mut c_rows,
            &mut c_len,
        ),
        0
    );
}

// ----------------------------------------------------------------------------
// Regression Case 16: fail-intact, proven by comparing exports
// ----------------------------------------------------------------------------

#[test]
fn test_rejected_import_leaves_the_destination_byte_identical() {
    let mut dest = Terminal::new(60, 20);
    dest.feed(b"\x1b[31mred\x1b[m normal\r\nsecond line\x1b]0;title\x07\x1b[3;4H\x1b[2");
    let before = dest.export_checkpoint().unwrap();

    let mut good = Terminal::new(40, 10);
    good.feed(b"a valid but unrelated state");
    let valid = good.export_checkpoint().unwrap();

    let rejects: Vec<Vec<u8>> = vec![
        Vec::new(),
        vec![1, 2, 3, 4, 5],
        valid[..valid.len() / 2].to_vec(),
        {
            let mut v = valid.clone();
            v[0..4].copy_from_slice(b"BAD!");
            v
        },
        {
            let mut v = valid.clone();
            v[4..8].copy_from_slice(&7u32.to_le_bytes());
            reseal(v)
        },
        {
            let mut v = valid.clone();
            let last = v.len() - 1;
            v[last] ^= 0xFF;
            v
        },
        {
            let mut v = valid.clone();
            v[20..24].copy_from_slice(&99_999u32.to_le_bytes());
            reseal(v)
        },
    ];

    for (i, blob) in rejects.iter().enumerate() {
        assert!(dest.import_checkpoint(blob).is_err(), "blob {i} must be rejected");
        assert_eq!(
            dest.export_checkpoint().unwrap(),
            before,
            "blob {i}: a rejected import must leave the destination byte-identical"
        );
    }

    // And a good one still lands.
    dest.import_checkpoint(&valid).unwrap();
    assert_eq!(dest.export_checkpoint().unwrap(), valid);
}

// ----------------------------------------------------------------------------
// Regression Case 17: the allocation budget is denominated in measured bytes
// ----------------------------------------------------------------------------

#[test]
fn test_cell_size_and_allocation_budget_arithmetic() {
    use tako_core::grid::Cell;
    use tako_core::terminal::checkpoint::{
        CELL_BYTES, HEADER_SIZE, MAX_CONTAINER_LEN, MAX_IMPORT_ALLOC_BYTES, MAX_PAYLOAD_LEN,
    };

    // The budget arithmetic is in bytes, so the figure has to be the measured
    // one. A wire cap is not a memory cap: at 32 bytes a cell, 4e7 cells is
    // ~1.22 GiB and a 10000x10000 grid is ~3 GiB, from a payload that run
    // length encodes to a few kilobytes.
    assert_eq!(std::mem::size_of::<Cell>(), 32);
    assert_eq!(CELL_BYTES, 32);
    // The wire cap is the container, not the payload: a 64 MiB budget that
    // both sides measure the same way leaves the payload 20 bytes short of it.
    assert_eq!(MAX_CONTAINER_LEN, 64 * 1024 * 1024);
    assert_eq!(MAX_PAYLOAD_LEN, MAX_CONTAINER_LEN - HEADER_SIZE);
    assert_eq!(MAX_IMPORT_ALLOC_BYTES, 512 * 1024 * 1024);
    assert_eq!(10_000u64 * 10_000 * CELL_BYTES, 3_200_000_000);

    // A grid that would decode past the budget is refused, however small the
    // payload that declares it is.
    let mut term = Terminal::new(4000, 4000);
    term.feed(b"budget");
    let cost = 4000u64 * 4000 * CELL_BYTES * 2; // primary + alternate
    assert!(cost > MAX_IMPORT_ALLOC_BYTES);
    assert!(
        matches!(
            term.export_checkpoint(),
            Err(tako_core::terminal::checkpoint::CheckpointError::TooLarge { .. })
        ),
        "export refuses a state it could not import back"
    );

    // A big-but-legal grid does round-trip, and its wire size is a fraction of
    // the heap it decodes into: 1200x400 cells is 15.36 MiB of `Cell` per
    // grid, 30.72 MiB for the pair, from the much smaller payload measured
    // here.
    let mut big = Terminal::new(1200, 400);
    big.feed(b"large but legal");
    let ckpt = big.export_checkpoint().expect("1200x400 is inside the budget");
    let mut restored = Terminal::new(1200, 400);
    restored.feed(b"the destination this import replaces");

    // Peak accounting, measured rather than assumed: the destination's own
    // state is still live while the replacement is decoded, so the peak spans
    // the staged decode, the wire buffer, and the old state that has not been
    // dropped yet.
    let rss_before = peak_rss_bytes();
    restored.import_checkpoint(&ckpt).unwrap();
    let rss_after = peak_rss_bytes();
    let cells_per_pair = 2 * 1200u64 * 400 * CELL_BYTES;
    println!(
        "import peak accounting: payload {} B, decoded cells {} B/pair, \
         retained old state {} B/pair, process peak RSS {} -> {} B (delta {} B)",
        ckpt.len(),
        cells_per_pair,
        cells_per_pair,
        rss_before,
        rss_after,
        rss_after.saturating_sub(rss_before),
    );
    assert_eq!(restored.export_checkpoint().unwrap(), ckpt);
    assert!(
        (ckpt.len() as u64) < 1200 * 400 * CELL_BYTES,
        "payload {} bytes vs {} bytes of cells per grid",
        ckpt.len(),
        1200 * 400 * CELL_BYTES
    );
    // Two live copies of the pair, plus the payload and decode temporaries.
    // The bound is what the budget promises, not a hope: nothing in the import
    // path holds a third copy.
    assert!(
        rss_after.saturating_sub(rss_before) < 4 * cells_per_pair,
        "peak grew by {} B, more than two live copies plus slack",
        rss_after.saturating_sub(rss_before)
    );
}

/// Process peak resident set, in bytes. macOS reports `ru_maxrss` in bytes,
/// Linux in kibibytes.
fn peak_rss_bytes() -> u64 {
    unsafe {
        let mut usage: libc::rusage = std::mem::zeroed();
        if libc::getrusage(libc::RUSAGE_SELF, &mut usage) != 0 {
            return 0;
        }
        let raw = usage.ru_maxrss as u64;
        if cfg!(target_os = "macos") { raw } else { raw * 1024 }
    }
}

// ----------------------------------------------------------------------------
// Regression Case 17: the negotiated cap is the cap on the blob, and 0 means
// "no caller limit"
// ----------------------------------------------------------------------------

/// A transport that says it will carry N bytes has to be handed at most N
/// bytes. The 20-byte container header is part of what gets transmitted, so a
/// cap that excludes it is a cap the caller cannot rely on: at the wire
/// ceiling it would hand a 64 MiB channel 64 MiB + 20.
#[test]
fn test_export_cap_covers_the_container_header() {
    use tako_core::terminal::checkpoint::{CheckpointError, HEADER_SIZE, MAX_PAYLOAD_LEN};

    let mut term = Terminal::new(80, 24);
    term.feed(b"the cap covers the header");
    let full = term.export_checkpoint().unwrap();
    let exact = full.len() as u64;
    assert!(exact > HEADER_SIZE as u64);

    // Exactly enough is enough, and what comes back fits.
    let at_cap = term
        .export_checkpoint_limited(exact)
        .expect("a cap equal to the blob is enough");
    assert_eq!(at_cap, full);
    assert!(at_cap.len() as u64 <= exact);

    // One byte less is not, and the reported size is the whole blob -- header
    // included -- so a caller can size its next attempt from it.
    match term.export_checkpoint_limited(exact - 1) {
        Err(CheckpointError::TooLarge { size, limit }) => {
            assert_eq!(size, exact, "the reported size counts the header");
            assert_eq!(limit, exact - 1);
        }
        other => panic!("expected TooLarge one byte under the blob, got {other:?}"),
    }

    // Every cap at or above the exact size returns something within it; every
    // cap below it refuses. No cap ever yields an oversized blob.
    for cap in (exact - 4)..(exact + 4) {
        match term.export_checkpoint_limited(cap) {
            Ok(blob) => assert!(
                blob.len() as u64 <= cap,
                "cap {cap} produced {} bytes",
                blob.len()
            ),
            Err(CheckpointError::TooLarge { size, limit }) => {
                assert_eq!(size, exact);
                assert_eq!(limit, cap);
                assert!(cap < exact);
            }
            other => panic!("unexpected result at cap {cap}: {other:?}"),
        }
    }

    // A refusal at the boundary mutated nothing.
    assert_eq!(term.export_checkpoint().unwrap(), full);

    // 0 is "no caller limit": the library ceiling alone, not a limit of zero.
    assert_eq!(
        term.export_checkpoint_limited(0).expect("0 means the ceiling"),
        full
    );
    // And a cap above the ceiling is clamped to it, not honoured.
    assert_eq!(term.export_checkpoint_limited(u64::MAX).unwrap(), full);
    assert!(full.len() <= MAX_PAYLOAD_LEN);

    // The C ABI carries both semantics.
    let vt = prod_vt_new(80, 24, 100);
    prod_vt_write(vt, b"the cap covers the header".as_ptr(), 25);
    let via_zero = unsafe { take_buffer(|o, l| prod_vt_checkpoint_export_limited(vt, 0, o, l)) }
        .expect("0 exports at the ceiling through the C ABI");
    assert!(Terminal::verify_checkpoint(&via_zero));
    let exact_c = via_zero.len() as u64;
    let at_cap_c =
        unsafe { take_buffer(|o, l| prod_vt_checkpoint_export_limited(vt, exact_c, o, l)) }
            .expect("a cap equal to the blob is enough through the C ABI");
    assert_eq!(at_cap_c.len() as u64, exact_c);
    assert_eq!(
        unsafe { take_buffer(|o, l| prod_vt_checkpoint_export_limited(vt, exact_c - 1, o, l)) },
        None,
        "one byte under the blob refuses through the C ABI too"
    );
    prod_vt_free(vt);
}

// ----------------------------------------------------------------------------
// Regression Case 18: the cumulative allocation budget actually refuses
// ----------------------------------------------------------------------------

/// A wire cap is not a memory cap. Geometry is the cheapest lever there is:
/// 10000x10000 passes every dimension bound (both are exactly MAX_DIM) yet
/// declares 3.2 GB of cells from a payload of about 1.3 KB. Reporting peak
/// usage would not stop it; the budget has to refuse.
#[test]
fn test_forged_geometry_is_refused_by_the_allocation_budget() {
    use tako_core::terminal::checkpoint::{
        CheckpointError, CELL_BYTES, MAX_DIM, MAX_IMPORT_ALLOC_BYTES,
    };

    let mut term = Terminal::new(80, 24);
    term.feed(b"honest source");
    let valid = term.export_checkpoint().unwrap();
    assert!(valid.len() < 64 * 1024, "the forgery is tiny: {}", valid.len());

    // cols and rows are the first two u32 of the payload.
    let mut forged = valid.clone();
    forged[20..24].copy_from_slice(&(MAX_DIM as u32).to_le_bytes());
    forged[24..28].copy_from_slice(&(MAX_DIM as u32).to_le_bytes());
    let forged = reseal(forged);
    assert!(
        Terminal::verify_checkpoint(&forged),
        "magic, version, length and CRC all still check out"
    );

    // The declared grid is within every dimension bound and still far past the
    // memory budget -- which is the whole point of having a separate one.
    let declared = (MAX_DIM as u64) * (MAX_DIM as u64) * CELL_BYTES;
    assert!(declared > MAX_IMPORT_ALLOC_BYTES, "{declared} vs {MAX_IMPORT_ALLOC_BYTES}");

    let mut dest = Terminal::new(60, 20);
    dest.feed(b"DESTINATION\r\nsecond line");
    let before = dest.export_checkpoint().unwrap();

    assert_eq!(
        dest.import_checkpoint(&forged),
        Err(CheckpointError::AllocationLimitExceeded)
    );

    // Fail-intact, byte for byte -- not merely "still has some text".
    assert_eq!(dest.export_checkpoint().unwrap(), before);
    assert_eq!(row_text(&dest, 0), "DESTINATION");
    assert_eq!(row_text(&dest, 1), "second line");

    // A second attempt is refused identically, and the honest checkpoint the
    // forgery was built from still imports.
    assert_eq!(
        dest.import_checkpoint(&forged),
        Err(CheckpointError::AllocationLimitExceeded)
    );
    dest.import_checkpoint(&valid).expect("the honest checkpoint still imports");
    assert_eq!(row_text(&dest, 0), "honest source");
}

/// Export must refuse exactly what import refuses.
///
/// `MAX_DIM` bounds the importer, but nothing bounded the exporter: a terminal
/// one column past it produced a blob that verified, carried an honest CRC, and
/// then failed at `import_checkpoint` with `DimensionOutOfBounds`. That is a
/// success return on an un-importable checkpoint -- the exact asymmetry the
/// container exists to remove -- and a caller that trusted the export had
/// already dropped the source state by the time the restore failed.
///
/// The fix refuses at export. Nothing resizes: the terminal is a legal
/// 10001-column terminal before the call and an untouched one after it.
#[test]
fn test_export_refuses_geometry_its_own_importer_would_reject() {
    use tako_core::terminal::checkpoint::{CheckpointError, MAX_DIM};

    // At the bound: exports, imports, round-trips. The guard must not be a
    // blanket refusal of large terminals.
    let mut at_bound = Terminal::new(MAX_DIM, 1);
    assert_eq!(at_bound.active_grid().cols(), MAX_DIM);
    at_bound.feed(b"widest legal terminal");
    let blob = at_bound
        .export_checkpoint()
        .expect("a terminal exactly at MAX_DIM is exportable");
    assert!(Terminal::verify_checkpoint(&blob));
    let mut dest = Terminal::new(MAX_DIM, 1);
    dest.import_checkpoint(&blob)
        .expect("and importable, which is the point of the bound");
    assert_eq!(row_text(&dest, 0), "widest legal terminal");

    // One column past it. The engine builds it happily -- this is not an
    // invalid terminal, only an unrepresentable checkpoint.
    let mut past = Terminal::new(MAX_DIM + 1, 1);
    assert_eq!(past.active_grid().cols(), MAX_DIM + 1);
    past.feed(b"one column too wide");

    assert_eq!(
        past.export_checkpoint(),
        Err(CheckpointError::DimensionOutOfBounds {
            cols: MAX_DIM + 1,
            rows: 1
        }),
        "export must refuse what import would reject, not emit a blob and let \
         the restore discover it"
    );
    assert_eq!(
        past.export_checkpoint_limited(0),
        Err(CheckpointError::DimensionOutOfBounds {
            cols: MAX_DIM + 1,
            rows: 1
        })
    );

    // The refusal did not touch the terminal: same geometry, same contents,
    // still usable.
    assert_eq!(past.active_grid().cols(), MAX_DIM + 1);
    assert_eq!(past.active_grid().rows(), 1);
    assert_eq!(row_text(&past, 0), "one column too wide");
    past.feed(b" still alive");
    assert_eq!(row_text(&past, 0), "one column too wide still alive");

    // Too tall is refused the same way.
    let too_tall = Terminal::new(1, MAX_DIM + 1);
    assert_eq!(
        too_tall.export_checkpoint(),
        Err(CheckpointError::DimensionOutOfBounds {
            cols: 1,
            rows: MAX_DIM + 1
        })
    );

    // And the C surface reports the same refusal rather than handing back a
    // buffer: a failed export yields no allocation to free.
    {
        let vt = prod_vt_new((MAX_DIM + 1) as u16, 1, 0);
        assert!(!vt.is_null());
        let mut ptr: *mut u8 = std::ptr::null_mut();
        let mut len: usize = 0;
        assert_eq!(
            prod_vt_checkpoint_export(vt, &mut ptr, &mut len),
            0,
            "the C export must fail for geometry its importer would reject"
        );
        assert!(ptr.is_null(), "a failed export must not hand back a buffer");
        assert_eq!(len, 0);
        prod_vt_free(vt);
    }
}

/// Build a version-1 container out of a version-2 one.
///
/// v1's payload was v2's payload followed by the selection block, which was
/// the last thing written: `present: bool`, and when present four `u32`
/// coordinates and a `u8` mode. Appending that block, stamping the version
/// back to 1 and resealing produces a container byte-for-byte identical to
/// what a v1 build would have emitted for the same terminal.
fn as_v1_with_selection(
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

/// A selection is the surface's, not the engine's, and it does not travel in a
/// checkpoint.
///
/// v1 serialized it, so a restore installed the *source's* highlight on the
/// destination -- over rows that selection never described -- and decoded four
/// grid coordinates straight off the wire with nothing validating them. v2
/// stops writing the block and reads past a v1 one. The destination's own
/// selection is therefore cleared exactly when the import succeeds, and
/// survives untouched when it fails.
#[test]
fn test_selection_does_not_travel_in_a_checkpoint() {
    use tako_core::terminal::checkpoint::CheckpointError;
    use tako_core::terminal::SelectionMode;

    let mut source = Terminal::new(40, 6);
    source.feed(b"source line one\r\nsource line two");
    source.start_selection(0, 0, SelectionMode::Linear);
    source.extend_selection(0, 10);
    assert!(source.has_selection(), "the source really does have one");

    let blob = source.export_checkpoint().unwrap();

    // Since v2 no container carries it: a selected and an unselected source
    // of otherwise identical state produce the identical container.
    let mut unselected = Terminal::new(40, 6);
    unselected.feed(b"source line one\r\nsource line two");
    assert!(!unselected.has_selection());
    assert_eq!(
        blob,
        unselected.export_checkpoint().unwrap(),
        "the selection must not be observable in the bytes at all"
    );

    // A successful import clears the destination's selection.
    let mut dest = Terminal::new(40, 6);
    dest.feed(b"DESTINATION one\r\nDESTINATION two");
    dest.start_selection(1, 2, SelectionMode::Rectangular);
    dest.extend_selection(1, 9);
    assert!(dest.has_selection());

    dest.import_checkpoint(&blob).expect("the current version imports");
    assert!(
        !dest.has_selection(),
        "a restored surface has nothing selected: the rows underneath the old \
         selection are gone"
    );
    assert_eq!(dest.selection_range(), None);
    assert_eq!(row_text(&dest, 0), "source line one");

    // A failed import leaves the destination's selection exactly as it was.
    let mut intact = Terminal::new(40, 6);
    intact.feed(b"KEEP ME");
    intact.start_selection(0, 1, SelectionMode::Linear);
    intact.extend_selection(0, 4);
    let range_before = intact.selection_range();
    assert!(range_before.is_some());

    let mut corrupt = blob.clone();
    let last = corrupt.len() - 1;
    corrupt[last] ^= 0xFF;
    assert!(matches!(
        intact.import_checkpoint(&corrupt),
        Err(CheckpointError::ChecksumMismatch { .. })
    ));
    assert!(intact.has_selection(), "fail-intact includes the selection");
    assert_eq!(intact.selection_range(), range_before);
    assert_eq!(row_text(&intact, 0), "KEEP ME");

    // A genuine v1 container still imports -- and its selection is dropped
    // rather than installed. The coordinates are deliberately absurd: under
    // v1 they were decoded and stored without a bound.
    // v1 is v2 plus the selection, so it is built from a v2 export; v3's own
    // tail comes after where v1's selection sat.
    let v2 = source.export_checkpoint_version(2, 0).unwrap();
    let v1 = as_v1_with_selection(&v2, (u32::MAX, u32::MAX), (u32::MAX - 1, 7), 1);
    assert!(Terminal::verify_checkpoint(&v1));
    assert_eq!(Terminal::inspect_checkpoint(&v1).unwrap().version, 1);

    let mut from_v1 = Terminal::new(40, 6);
    from_v1.start_selection(0, 0, SelectionMode::Linear);
    from_v1.extend_selection(0, 3);
    from_v1
        .import_checkpoint(&v1)
        .expect("a v1 container is still readable");
    assert_eq!(row_text(&from_v1, 0), "source line one");
    assert!(
        !from_v1.has_selection(),
        "the v1 selection is read past, not restored"
    );

    // A v1 container that claims a selection and then stops short is a
    // truncated payload, not a silently accepted one.
    let mut truncated = v1.clone();
    truncated.truncate(truncated.len() - 4);
    let truncated_len = (truncated.len() - 20) as u32;
    truncated[12..16].copy_from_slice(&truncated_len.to_le_bytes());
    let truncated = reseal(truncated);
    let mut victim = Terminal::new(40, 6);
    victim.feed(b"UNTOUCHED");
    assert_eq!(
        victim.import_checkpoint(&truncated),
        Err(CheckpointError::UnexpectedEof)
    );
    assert_eq!(row_text(&victim, 0), "UNTOUCHED");
}

/// Reserving a container costs memory before a single byte of its contents is
/// read, and a budget that does not charge for it is not a budget.
///
/// The forged grid is chosen so that the cells alone land *exactly* on the
/// limit: only the per-row spine pushes it over. Stop charging the spine and
/// the import is admitted and fails later on the truncated payload instead,
/// which is a different error -- so this test cannot pass by accident.
#[test]
fn test_container_spines_are_charged_against_the_allocation_budget() {
    use tako_core::terminal::checkpoint::{
        CheckpointError, CELL_BYTES, GRID_ROW_SPINE, MAX_DIM, MAX_IMPORT_ALLOC_BYTES,
    };

    // The primary grid is charged first and is decoded before the alternate is
    // charged at all, so the boundary has to be crossed on that first grid:
    // 2^24 cells put its cells alone exactly on the limit.
    const COLS: u32 = 8_192;
    const ROWS: u32 = 2_048;
    assert!(COLS as usize <= MAX_DIM && ROWS as usize <= MAX_DIM);
    let cells = (COLS as u64) * (ROWS as u64) * CELL_BYTES;
    assert_eq!(
        cells, MAX_IMPORT_ALLOC_BYTES,
        "the geometry must land on the limit, not past it"
    );
    assert!(
        cells + (ROWS as u64) * GRID_ROW_SPINE > MAX_IMPORT_ALLOC_BYTES,
        "and the row spines must be what carries it over"
    );

    let mut term = Terminal::new(80, 24);
    term.feed(b"honest source");
    let valid = term.export_checkpoint().unwrap();

    // cols and rows are the first two u32 of the payload.
    let mut forged = valid.clone();
    forged[20..24].copy_from_slice(&COLS.to_le_bytes());
    forged[24..28].copy_from_slice(&ROWS.to_le_bytes());
    let forged = reseal(forged);
    assert!(Terminal::verify_checkpoint(&forged), "still a well-formed container");

    let mut dest = Terminal::new(60, 20);
    dest.feed(b"DESTINATION");
    let before = dest.export_checkpoint().unwrap();

    assert_eq!(
        dest.import_checkpoint(&forged),
        Err(CheckpointError::AllocationLimitExceeded),
        "charged for the row spines, this is over budget"
    );
    assert_eq!(dest.export_checkpoint().unwrap(), before, "fail-intact");
    assert_eq!(row_text(&dest, 0), "DESTINATION");
}

/// What export charges is what import charges, spines included: the number
/// export refuses above is the number a host can ask for in advance.
#[test]
fn test_import_cost_counts_the_spines_on_both_sides() {
    use tako_core::terminal::checkpoint::{
        import_cost, CELL_BYTES, GRID_ROW_SPINE, MAX_IMPORT_ALLOC_BYTES, SCROLLBACK_ROW_SPINE,
    };

    let mut bare = Terminal::new(80, 24);
    bare.feed(b"no history yet");
    let bare_cost = import_cost(&bare);

    // Two grids of cells, two grids of row spines, and whatever the parser
    // and title carry. The floor is exact; the extra is small and non-zero.
    let floor = 80u64 * 24 * CELL_BYTES * 2 + 24 * GRID_ROW_SPINE * 2;
    assert!(bare_cost >= floor, "{bare_cost} < {floor}");

    // What one more row of history costs, measured rather than asserted: two
    // terminals of the same shape, differing only in how much has scrolled off.
    // A row is its cells *and* the `ScrollbackRow` holding them, so dropping
    // the spine from the count moves this number and the test says so.
    let history_cost = |rows: usize| {
        let mut term = Terminal::new(80, 24);
        for _ in 0..(100 + rows) {
            term.feed(b"\r\n");
        }
        import_cost(&term)
    };
    const EXTRA_ROWS: u64 = 200;
    assert_eq!(
        history_cost(EXTRA_ROWS as usize) - history_cost(0),
        EXTRA_ROWS * (80 * CELL_BYTES + SCROLLBACK_ROW_SPINE),
        "a scrollback row costs its cells plus its own spine"
    );

    let mut scrolled = Terminal::new(80, 24);
    for line in 0..300 {
        scrolled.feed(format!("history line {line}\r\n").as_bytes());
    }
    let scrolled_cost = import_cost(&scrolled);
    assert!(scrolled_cost > bare_cost, "history is not free");

    // The cost survives a round trip: what was charged to build this terminal
    // is what will be charged to rebuild it.
    let blob = scrolled.export_checkpoint().unwrap();
    let mut dest = Terminal::new(10, 4);
    dest.import_checkpoint(&blob).expect("honest checkpoint imports");
    assert_eq!(
        import_cost(&dest),
        scrolled_cost,
        "export and import must agree on what the state costs"
    );
    assert!(scrolled_cost < MAX_IMPORT_ALLOC_BYTES, "and a real terminal is nowhere near the cap");
}

/// The two sides of the budget are the same number.
///
/// [`import_cost`] is what export refuses above; `allocated` is what import
/// actually charged. If they drift, one direction is counting something the
/// other is not, and a checkpoint this build writes can be one it declines to
/// read back. Real terminal state, not a forgery: the symmetry has to hold on
/// the payloads that actually occur.
#[test]
fn test_export_and_import_charge_the_same_budget() {
    use tako_core::terminal::checkpoint::{import_cost, import_traced};

    let mut term = Terminal::new(100, 30);
    // Something from every charged section: history, styled cells, a title and
    // its stack, hyperlinks, tab stops, an in-flight OSC, kitty graphics, and
    // grapheme clusters (primary history/screen and alternate screen).
    for line in 0..250 {
        term.feed(format!("\x1b[3{}mhistory line {line}\x1b[0m\r\n", line % 8).as_bytes());
    }
    term.feed("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} e\u{0301}\u{0302} \u{0938}\u{094D}\u{0924}\u{0947}\r\n".as_bytes());
    term.feed(format!("\x1b[?1049h\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\x1b[?1049l").as_bytes());
    term.feed(b"\x1b]0;window title\x07");
    term.feed(b"\x1b[22t");
    term.feed(b"\x1b]8;id=one;https://example.invalid/a\x07linked\x1b]8;;\x07");
    term.feed(b"\x1b]8;id=two;https://example.invalid/b\x07more\x1b]8;;\x07");
    term.feed(b"\x1bH\t\x1bH");
    // A stored image and a placement, then a chunked transfer left open, so
    // the image map, the placement vector and the pending map are all charged.
    term.feed(b"\x1b_Ga=T,t=d,f=32,s=1,v=1,i=7;/4AA/w==\x1b\\");
    term.feed(b"\x1b_Ga=t,t=d,f=24,s=1,v=1,i=9,m=1;ESI=\x1b\\");
    term.feed(b"\x1b[>1u");
    term.feed(b"\x1b[>5u");

    // The fixture is only evidence while it actually populates every charged
    // container; assert that rather than trust the escape sequences.
    assert_eq!(term.graphics_placements().len(), 1, "placement vector");
    assert!(term.graphics_image(7).is_some(), "image map");
    assert!(term.buffer_text().contains("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"), "cluster in buffer");
    term.feed(b"\x1b]0;a title that never finish");

    let blob = term.export_checkpoint().unwrap();
    let predicted = import_cost(&term);
    let (restored, trace) = import_traced(&blob).expect("honest checkpoint imports");

    assert_eq!(
        trace.allocated, predicted,
        "import charged {} where export predicted {predicted}",
        trace.allocated
    );
    // And the restored terminal predicts the same cost again, so the number is
    // a property of the state rather than of one particular trip through it.
    assert_eq!(import_cost(&restored), predicted);
}

/// A checkpoint is refused when importing it *while the old terminal is still
/// alive* would exceed the budget, even though each state fits on its own.
///
/// `import_checkpoint` decodes the whole replacement before dropping `self`,
/// so both states are resident at the peak. Charging the incoming state from
/// zero therefore permits two individually-legal terminals to coexist above
/// the 512 MiB the container promises, which is the number a host sizes its
/// process against. The destination's own cost is what the decoder must
/// reserve before it allocates anything.
///
/// Sized so that the refusal happens *before* the replacement is built: at the
/// assert below only the destination and the (small) blob are resident, which
/// is the whole point of refusing early rather than after the fact.
#[test]
fn test_import_refuses_when_the_retained_destination_plus_replacement_exceeds_the_budget() {
    use tako_core::terminal::checkpoint::{import_cost, CheckpointError, MAX_IMPORT_ALLOC_BYTES};

    // Primary and alternate are both charged, so a cols x rows terminal costs
    // roughly 2 * cols * rows * CELL_BYTES. 10_000 x 420 lands just over half
    // the budget: legal alone, illegal in a pair.
    const COLS: usize = 10_000;
    const ROWS: usize = 420;

    let blob = {
        let mut source = Terminal::new(COLS, ROWS);
        source.feed(b"the replacement state");
        source.export_checkpoint().expect("a big but legal state exports")
    };

    let mut dest = Terminal::new(COLS, ROWS);
    dest.feed(b"the destination that must survive\r\n");

    let dest_cost = import_cost(&dest);
    assert!(
        dest_cost < MAX_IMPORT_ALLOC_BYTES,
        "the destination alone must be legal: {dest_cost} vs {MAX_IMPORT_ALLOC_BYTES}"
    );

    let incoming = tako_core::terminal::checkpoint::inspect(&blob).expect("header parses");
    assert_eq!((incoming.cols as usize, incoming.rows as usize), (COLS, ROWS));

    // Each fits; together they do not.
    assert!(
        dest_cost.saturating_add(dest_cost) > MAX_IMPORT_ALLOC_BYTES,
        "the pair must exceed the budget for this test to mean anything"
    );

    let before = dest.export_checkpoint().expect("destination exports");
    let err = dest
        .import_checkpoint(&blob)
        .expect_err("importing into a live terminal this large must be refused");
    assert!(
        matches!(err, CheckpointError::AllocationLimitExceeded),
        "expected the budget refusal, got {err:?}"
    );

    // Fail-intact: the refusal cost the destination nothing.
    let after = dest.export_checkpoint().expect("destination still exports");
    assert_eq!(before, after, "a refused import mutated the destination");
}

/// A terminal that has finished a large OSC still owns the buffer it used.
///
/// `Parser::clear` is `Vec::clear`: it drops the length and keeps the
/// allocation. So a terminal that consumed an 8 MiB title and then moved on is
/// holding 8 MiB (16, after the growth doubling) while every length inside it
/// reads zero -- and a checkpoint of it is a kilobyte.
///
/// That is the gap this pins: what a checkpoint of a state *decodes to* and
/// what that state *occupies* are different numbers, and only one of them is
/// the memory a live process is carrying.
#[test]
fn test_retained_capacity_outlives_a_logical_clear() {
    use tako_core::terminal::checkpoint::{import_cost, retained_cost};

    const PAYLOAD: usize = 8 << 20;

    let mut term = Terminal::new(20, 6);
    let mut input = Vec::with_capacity(PAYLOAD + 8);
    input.extend_from_slice(b"\x1b]0;");
    input.extend(std::iter::repeat_n(b'x', PAYLOAD));
    term.feed(&input);
    drop(input);

    // Mid-sequence both numbers see the payload: it is live state, and a
    // checkpoint has to carry it.
    assert!(
        import_cost(&term) as usize > PAYLOAD,
        "an in-flight OSC belongs in the decoded cost"
    );
    assert!(
        retained_cost(&term) as usize >= PAYLOAD,
        "an in-flight OSC belongs in the retained cost"
    );

    // CAN abandons the sequence; the next OSC calls `clear` on the same
    // buffer. Logically the payload is gone.
    term.feed(b"\x18");
    term.feed(b"\x1b]0;short\x07");

    let decoded = import_cost(&term);
    let retained = retained_cost(&term);
    let measured = term.measure_checkpoint().expect("a small state measures");

    assert!(
        decoded < 64 * 1024 && measured < 64 * 1024,
        "the payload is logically gone, so a checkpoint of this state is small: \
         decoded={decoded} measured={measured}"
    );
    assert!(
        retained as usize >= PAYLOAD,
        "the buffer is still allocated and must still be counted: retained={retained}"
    );
    assert!(
        retained > decoded.saturating_mul(100),
        "this test is only meaningful when the two numbers diverge sharply: \
         retained={retained} decoded={decoded}"
    );
}

/// Storage the destination retained but is not using still has to be inside
/// the import budget.
///
/// The peak of a staged import is the destination plus the replacement: the
/// terminal being replaced is not freed until the assignment. Charging the
/// destination what a *checkpoint of it* would decode to gets that peak wrong
/// in exactly the case above -- a large buffer, logically empty -- because the
/// decoded cost cannot see an allocation no length reports.
///
/// Here the destination is holding 128 MiB it is not using, and the incoming
/// checkpoint decodes to 415 MiB. Either is legal alone. Both at once are not,
/// and the refusal has to happen before the replacement is built.
#[test]
fn test_import_counts_storage_the_destination_retained_after_a_logical_clear() {
    use tako_core::terminal::checkpoint::{
        import_cost, retained_cost, CheckpointError, MAX_IMPORT_ALLOC_BYTES,
    };

    // 10_000 x 680, primary and alternate: ~415 MiB decoded, and a container
    // of a few kilobytes -- so the blob itself is not what tips the budget.
    let blob = {
        let mut source = Terminal::new(10_000, 680);
        source.feed(b"the replacement state");
        source.export_checkpoint().expect("a big but legal state exports")
    };
    let incoming = {
        let mut probe = Terminal::new(10_000, 680);
        probe.feed(b"the replacement state");
        import_cost(&probe)
    };
    assert!(
        incoming < MAX_IMPORT_ALLOC_BYTES,
        "the incoming state must be legal on its own: {incoming}"
    );

    // A destination that has consumed a 70 MiB OSC and then abandoned it: the
    // buffer doubled to 128 MiB and is still allocated.
    let mut dest = Terminal::new(20, 6);
    dest.feed(b"the destination that must survive\r\n");
    let mut input = Vec::with_capacity((70 << 20) + 8);
    input.extend_from_slice(b"\x1b]0;");
    input.extend(std::iter::repeat_n(b'x', 70 << 20));
    dest.feed(&input);
    drop(input);
    dest.feed(b"\x18");
    dest.feed(b"\x1b]0;short\x07");

    let dest_decoded = import_cost(&dest);
    let dest_retained = retained_cost(&dest);

    // The premise: by the decoded measure this destination is free, and the
    // import would sail through. By what it actually occupies, it does not.
    assert!(
        dest_decoded.saturating_add(incoming) < MAX_IMPORT_ALLOC_BYTES,
        "this test proves nothing unless the decoded measure would admit the \
         import: {dest_decoded} + {incoming} vs {MAX_IMPORT_ALLOC_BYTES}"
    );
    assert!(
        dest_retained.saturating_add(incoming) > MAX_IMPORT_ALLOC_BYTES,
        "the retained destination plus the replacement must exceed the budget: \
         {dest_retained} + {incoming} vs {MAX_IMPORT_ALLOC_BYTES}"
    );

    // A terminal that is not holding anything accepts the same blob, so the
    // refusal below is about the destination and nothing else.
    let mut fresh = Terminal::new(20, 6);
    fresh
        .import_checkpoint(&blob)
        .expect("the blob is legal on its own");

    let before = dest.export_checkpoint().expect("destination exports");
    let err = dest
        .import_checkpoint(&blob)
        .expect_err("importing into a destination holding this much must be refused");
    assert!(
        matches!(err, CheckpointError::AllocationLimitExceeded),
        "expected the budget refusal, got {err:?}"
    );

    // Fail-intact, and specifically *not* by shrinking the destination to make
    // room: the retained buffer is still retained.
    let after = dest.export_checkpoint().expect("destination still exports");
    assert_eq!(before, after, "a refused import mutated the destination");
    assert_eq!(
        retained_cost(&dest),
        dest_retained,
        "a refused import must not release the destination's storage to fit"
    );
}

/// Queued host events are the destination's memory too, and a refusal must
/// not drain them to make room.
///
/// The sibling test above is about storage a `clear` left behind. This one is
/// about storage nothing has released *yet*: events the byte stream produced
/// and the host has not collected. They are excluded from the checkpoint by
/// design -- a restore must not ring the bell again -- so a measure derived
/// from what a checkpoint of the destination would decode to cannot see them
/// at all, and neither can one that charges only `events.capacity()` times the
/// size of a slot. A megabyte of OSC 0 title lives in a 24-byte slot.
///
/// So the destination below is holding ~120 MiB entirely in event payloads,
/// the incoming checkpoint decodes to ~415 MiB, and the two together are over
/// budget. The refusal has to come before the replacement is built, and it has
/// to leave the events exactly where they were: they belong to the host, and
/// discarding them to fit an import would lose a title, a clipboard write or a
/// command exit the host never saw.
#[test]
fn test_import_counts_the_payloads_of_events_the_host_has_not_collected() {
    use tako_core::terminal::checkpoint::{
        retained_cost, CheckpointError, MAX_IMPORT_ALLOC_BYTES,
    };

    const EVENTS: usize = 120;
    const EACH: usize = 1 << 20;

    /// A terminal carrying `EVENTS` undelivered OSC 0 titles of `EACH` bytes.
    fn destination_with_queued_events() -> Terminal {
        let mut term = Terminal::new(20, 6);
        term.feed(b"the destination that must survive\r\n");
        let mut osc = Vec::with_capacity(EACH + 8);
        osc.extend_from_slice(b"\x1b]0;");
        osc.extend(std::iter::repeat_n(b'x', EACH));
        osc.push(0x07);
        for _ in 0..EVENTS {
            term.feed(&osc);
        }
        term
    }

    // 10_000 x 680, primary and alternate: ~415 MiB decoded, from a container
    // of a few kilobytes.
    let blob = {
        let mut source = Terminal::new(10_000, 680);
        source.feed(b"the replacement state");
        source.export_checkpoint().expect("a big but legal state exports")
    };
    let incoming = {
        let mut probe = Terminal::new(10_000, 680);
        probe.feed(b"the replacement state");
        tako_core::terminal::checkpoint::import_cost(&probe)
    };
    assert!(
        incoming < MAX_IMPORT_ALLOC_BYTES,
        "the incoming state must be legal on its own: {incoming}"
    );

    // The same destination with the events collected is the events-blind
    // measure: identical grid, identical parser buffers, nothing queued.
    let blind = {
        let mut twin = destination_with_queued_events();
        let collected = twin.take_events();
        assert_eq!(collected.len(), EVENTS, "the fixture should queue one event per OSC");
        drop(collected);
        retained_cost(&twin)
    };

    // A terminal holding nothing accepts the same blob, so the refusal below
    // is about the destination and nothing else.
    {
        let mut fresh = Terminal::new(20, 6);
        fresh
            .import_checkpoint(&blob)
            .expect("the blob is legal on its own");
    }

    let mut dest = destination_with_queued_events();
    let dest_retained = retained_cost(&dest);

    // The premise: without the payloads this destination looks free and the
    // import sails through. With them, it does not.
    assert!(
        blind.saturating_add(incoming) < MAX_IMPORT_ALLOC_BYTES,
        "this test proves nothing unless an events-blind measure would admit \
         the import: {blind} + {incoming} vs {MAX_IMPORT_ALLOC_BYTES}"
    );
    assert!(
        dest_retained.saturating_add(incoming) > MAX_IMPORT_ALLOC_BYTES,
        "the queued payloads must count against the budget: {dest_retained} + \
         {incoming} vs {MAX_IMPORT_ALLOC_BYTES}"
    );

    let before = dest.export_checkpoint().expect("destination exports");
    let err = dest
        .import_checkpoint(&blob)
        .expect_err("importing into a destination holding this much must be refused");
    assert!(
        matches!(err, CheckpointError::AllocationLimitExceeded),
        "expected the budget refusal, got {err:?}"
    );

    // Fail-intact, and specifically not by draining or shrinking to fit.
    let after = dest.export_checkpoint().expect("destination still exports");
    assert_eq!(before, after, "a refused import mutated the destination");
    assert_eq!(
        retained_cost(&dest),
        dest_retained,
        "a refused import must not release the destination's storage to fit"
    );
    let survivors = dest.take_events();
    assert_eq!(
        survivors.len(),
        EVENTS,
        "the host's undelivered events must survive a refused import"
    );
}
