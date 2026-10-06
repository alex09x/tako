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

// ----------------------------------------------------------------------------
// Regression Case 1: 20x6 twenty 'x' characters, pending wrap, and next 'Y'
// ----------------------------------------------------------------------------

#[test]
fn test_case_1_prod_vt_snapshot_ansi_preserves_legacy_byte_compatibility() {
    let vt = prod_vt_new(20, 6, 1000);
    assert!(!vt.is_null());

    let input = b"xxxxxxxxxxxxxxxxxxxx"; // 20 chars
    prod_vt_write(vt, input.as_ptr(), input.len());

    let mut cursor = ProdVtCursor {
        x: 0,
        y: 0,
        visible: 0,
    };
    assert_eq!(prod_vt_cursor_state(vt, &mut cursor), 1);
    assert_eq!(
        (cursor.x, cursor.y),
        (19, 0),
        "source cursor must be at col 19, row 0"
    );

    let snap =
        unsafe { take_buffer(|o, l| prod_vt_snapshot_ansi(vt, o, l)) }.expect("snapshot_ansi");

    // Existing Prod contract: prod_vt_snapshot_ansi emits all 6 rows separated by CRLF without
    // omitting trailing blank lines and without appending cursor positioning escape sequences.
    let crlf_count = snap.windows(2).filter(|&w| w == b"\r\n").count();
    assert_eq!(
        crlf_count, 5,
        "legacy snapshot_ansi must emit all rows (5 CRLFs for 6 rows)"
    );
    assert!(
        !snap.ends_with(b"H"),
        "must not append cursor position escape"
    );
    assert!(
        !snap.ends_with(b"?25l"),
        "must not append cursor visibility escape"
    );

    // Replay of pure ANSI lines leaves cursor at (0, 5) — the exact historical baseline in operator finding #1.
    let restored_vt = prod_vt_new(20, 6, 1000);
    prod_vt_write(restored_vt, snap.as_ptr(), snap.len());
    let mut rest_cursor = ProdVtCursor {
        x: 0,
        y: 0,
        visible: 0,
    };
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

    let mut cursor = ProdVtCursor {
        x: 0,
        y: 0,
        visible: 0,
    };
    assert_eq!(prod_vt_cursor_state(vt, &mut cursor), 1);
    assert_eq!(
        (cursor.x, cursor.y),
        (19, 0),
        "source cursor must be at col 19, row 0"
    );

    let snap = unsafe { take_buffer(|o, l| prod_vt_snapshot_ansi_v2(vt, o, l)) }
        .expect("snapshot_ansi_v2");

    // Replay snapshot_v2 into a fresh TakoCore
    let restored_vt = prod_vt_new(20, 6, 1000);
    prod_vt_write(restored_vt, snap.as_ptr(), snap.len());

    let mut rest_cursor = ProdVtCursor {
        x: 0,
        y: 0,
        visible: 0,
    };
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
    let rest_text =
        unsafe { take_buffer(|o, l| prod_vt_viewport_text(restored_vt, o, l)) }.unwrap();
    assert_eq!(src_text, rest_text);
    assert_eq!(
        String::from_utf8(rest_text).unwrap(),
        "xxxxxxxxxxxxxxxxxxxx\nY"
    );

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

    let mut cur1 = ProdVtCursor {
        x: 0,
        y: 0,
        visible: 0,
    };
    let mut cur2 = ProdVtCursor {
        x: 0,
        y: 0,
        visible: 0,
    };
    assert_eq!(prod_vt_cursor_state(vt, &mut cur1), 1);
    assert_eq!(prod_vt_cursor_state(restored_vt, &mut cur2), 1);
    assert_eq!((cur1.x, cur1.y), (1, 1));
    assert_eq!((cur2.x, cur2.y), (1, 1));

    let src_text = unsafe { take_buffer(|o, l| prod_vt_viewport_text(vt, o, l)) }.unwrap();
    let rest_text =
        unsafe { take_buffer(|o, l| prod_vt_viewport_text(restored_vt, o, l)) }.unwrap();
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

    let mut scrollbar = ProdVtScrollbar {
        total: 0,
        offset: 0,
        len: 0,
    };
    assert_eq!(prod_vt_scrollbar_state(vt, &mut scrollbar), 1);
    assert_eq!(scrollbar.len, 55);
    assert_eq!(scrollbar.total, 55, "initial scrollback must be 0");

    let mut cursor = ProdVtCursor {
        x: 0,
        y: 0,
        visible: 0,
    };
    assert_eq!(prod_vt_cursor_state(vt, &mut cursor), 1);
    assert_eq!(cursor.y, 54, "cursor row must be 54 (last row)");
    assert_eq!(cursor.x, 2, "cursor col must be 2 after '54'");

    // Test native checkpoint, legacy snapshot_ansi, and snapshot_ansi_v2
    let ckpt = unsafe { take_buffer(|o, l| prod_vt_checkpoint(vt, o, l)) }.expect("checkpoint");
    let snap =
        unsafe { take_buffer(|o, l| prod_vt_snapshot_ansi(vt, o, l)) }.expect("snapshot_ansi");
    let snap_v2 = unsafe { take_buffer(|o, l| prod_vt_snapshot_ansi_v2(vt, o, l)) }
        .expect("snapshot_ansi_v2");

    for (desc, is_ckpt, payload) in [
        ("native_checkpoint", true, ckpt),
        ("snapshot_ansi", false, snap),
        ("snapshot_ansi_v2", false, snap_v2),
    ] {
        let restored_vt = prod_vt_new(258, 55, 10000);
        if is_ckpt {
            assert_eq!(
                prod_vt_restore(restored_vt, payload.as_ptr(), payload.len()),
                1
            );
        } else {
            prod_vt_write(restored_vt, payload.as_ptr(), payload.len());
        }

        let mut rest_cursor = ProdVtCursor {
            x: 0,
            y: 0,
            visible: 0,
        };
        assert_eq!(prod_vt_cursor_state(restored_vt, &mut rest_cursor), 1);
        assert_ne!(
            rest_cursor.x, 256,
            "{desc}: cursor must NOT be at final tab stop 256"
        );
        assert_eq!(
            (rest_cursor.x, rest_cursor.y),
            (2, 54),
            "{desc}: cursor must be at col 2, row 54"
        );

        let mut rest_bar = ProdVtScrollbar {
            total: 0,
            offset: 0,
            len: 0,
        };
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
