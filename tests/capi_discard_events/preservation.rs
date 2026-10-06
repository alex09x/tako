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
fn test_current_title_grid_and_parser_continuation_preserved() {
    // Two terminals are driven with byte-identical input in lockstep. Only `vt`
    // has prod_vt_discard_events called at the split points; `control` runs the
    // same script uninterrupted. Any state the discard disturbed - including SGR
    // parser state, which no C getter exposes - shows up as a checkpoint diff at
    // the end. Asserting that the screen merely contains "StyledText" would not
    // establish that, because the text renders either way.
    let vt = unsafe { prod_vt_new(80, 24, 100) };
    let control = unsafe { prod_vt_new(80, 24, 100) };

    // 1. Set title and write initial grid text
    let setup = b"\x1b]0;Authoritative Production Title\x07Line 1\r\nLine 2";
    unsafe { write_seq(vt, setup) };
    unsafe { write_seq(control, setup) };

    unsafe { prod_vt_discard_events(vt) };

    let title_bytes = unsafe { take_buffer(|o, l| prod_vt_title(vt, o, l)) }.unwrap();
    assert_eq!(
        String::from_utf8(title_bytes).unwrap(),
        "Authoritative Production Title",
        "title must be preserved across discard"
    );

    let text_bytes = unsafe { take_buffer(|o, l| prod_vt_viewport_text(vt, o, l)) }.unwrap();
    let text = String::from_utf8_lossy(&text_bytes);
    assert!(
        text.contains("Line 1\nLine 2"),
        "grid text must be preserved: {text}"
    );

    // 2. Parser continuation: an SGR sequence (underline + italic) split so that
    //    the discard lands mid-escape, between the parameters and the final byte.
    let sgr_head = b"\r\n\x1b[4;3";
    let sgr_tail = b"mStyledText\x1b[0m";
    unsafe { write_seq(vt, sgr_head) };
    unsafe { write_seq(control, sgr_head) };

    unsafe { prod_vt_discard_events(vt) };

    unsafe { write_seq(vt, sgr_tail) };
    unsafe { write_seq(control, sgr_tail) };

    let updated_text_bytes =
        unsafe { take_buffer(|o, l| prod_vt_viewport_text(vt, o, l)) }.unwrap();
    let updated_text = String::from_utf8_lossy(&updated_text_bytes);
    assert!(
        updated_text.contains("StyledText"),
        "parser must continue valid sequence across discard without truncation: {updated_text}"
    );

    // 3. Parser continuation for OSC: a title sequence split across the discard.
    let osc_head = b"\x1b]0;Updated ";
    let osc_tail = b"Title\x07";
    unsafe { write_seq(vt, osc_head) };
    unsafe { write_seq(control, osc_head) };

    unsafe { prod_vt_discard_events(vt) };

    unsafe { write_seq(vt, osc_tail) };
    unsafe { write_seq(control, osc_tail) };

    let updated_title_bytes = unsafe { take_buffer(|o, l| prod_vt_title(vt, o, l)) }.unwrap();
    assert_eq!(
        String::from_utf8(updated_title_bytes).unwrap(),
        "Updated Title",
        "split OSC title must complete across discard"
    );

    // 4. The real gate: full serialized state against the uninterrupted control.
    //    The control still holds every queued event; the discarded terminal holds
    //    none. Events are excluded from checkpoint serialization, so the two must
    //    be byte-identical - cell attributes, cursor, modes, parser state and all.
    let after_discards = unsafe { export_checkpoint(vt) };
    let uninterrupted = unsafe { export_checkpoint(control) };
    if after_discards != uninterrupted {
        // A full byte dump of two checkpoints is unreadable; report the shape of
        // the divergence instead.
        let at = after_discards
            .iter()
            .zip(uninterrupted.iter())
            .position(|(a, b)| a != b);
        let window = at.map(|i| {
            let lo = i.saturating_sub(8);
            let hi = (i + 8).min(after_discards.len().min(uninterrupted.len()));
            (
                after_discards[lo..hi].to_vec(),
                uninterrupted[lo..hi].to_vec(),
            )
        });
        panic!(
            "terminal state after interleaved discards must equal the uninterrupted control: \
             lengths {} vs {}, first difference at byte offset {:?}, \
             window (discarded vs control) {:?}",
            after_discards.len(),
            uninterrupted.len(),
            at,
            window
        );
    }

    unsafe {
        prod_vt_free(vt);
        prod_vt_free(control);
    }
}

#[test]
fn test_pending_responses_preserved() {
    let vt = unsafe { prod_vt_new(80, 24, 100) };

    // Position cursor at row 5, col 10 (1-indexed)
    let move_cursor = b"\x1b[5;10H";
    unsafe { write_seq(vt, move_cursor) };

    // Give the palette a known synthetic entry so the OSC query below has a
    // deterministic answer.
    let palette_setup = b"\x1b]4;1;#ff8000\x07";
    unsafe { write_seq(vt, palette_setup) };

    // Four queries spanning both response-producing paths:
    //   CSI 6 n   CPR            -> CSI 5 ; 10 R
    //   CSI 5 n   DSR status     -> CSI 0 n
    //   CSI c     Primary DA     -> CSI ? 62 ; 22 c
    //   OSC 4;1;? palette query  -> OSC 4 ; 1 ; rgb:ffff/8080/0000
    let queries = b"\x1b[6n\x1b[5n\x1b[c\x1b]4;1;?\x07";
    unsafe { write_seq(vt, queries) };

    // Discard events: MUST NOT drain or touch ResponseQueue
    unsafe { prod_vt_discard_events(vt) };

    // Drain responses via C API
    let responses = unsafe { take_buffer(|o, l| prod_vt_drain_responses(vt, o, l)) }.unwrap();
    assert!(
        !responses.is_empty(),
        "pending responses must be preserved across discard_events"
    );
    let resp_str = String::from_utf8_lossy(&responses);
    assert!(
        resp_str.contains("\x1b[5;10R"),
        "CPR response must be present: {resp_str:?}"
    );
    assert!(
        resp_str.contains("\x1b[0n"),
        "DSR status response must be present: {resp_str:?}"
    );
    assert!(
        resp_str.contains("\x1b[?62;22c"),
        "Primary DA response must be present: {resp_str:?}"
    );
    assert!(
        resp_str.contains("\x1b]4;1;rgb:ffff/8080/0000"),
        "OSC palette query response must be present: {resp_str:?}"
    );

    // Draining again returns empty
    let empty_responses = unsafe { take_buffer(|o, l| prod_vt_drain_responses(vt, o, l)) }.unwrap();
    assert!(empty_responses.is_empty(), "second drain must be empty");

    unsafe { prod_vt_free(vt) };
}

#[test]
fn test_checkpoint_export_remains_non_mutating() {
    let vt = unsafe { prod_vt_new(40, 10, 100) };

    let setup = b"\x1b]0;Export Title\x07Hello Checkpoint World!\r\nSecond line.";
    unsafe { write_seq(vt, setup) };

    // Discard any events from setup
    unsafe { prod_vt_discard_events(vt) };

    // Measure checkpoint export
    let mut needed: usize = 0;
    let st = unsafe { prod_vt_checkpoint_export2(vt, 0, std::ptr::null_mut(), 0, &mut needed) };
    assert_eq!(st, -2); // PROD_VT_ERR_BUFFER_TOO_SMALL
    assert!(needed > 20);

    let mut buf1 = vec![0u8; needed];
    let mut written1: usize = 0;
    let st1 =
        unsafe { prod_vt_checkpoint_export2(vt, 0, buf1.as_mut_ptr(), buf1.len(), &mut written1) };
    assert_eq!(st1, 0); // PROD_VT_OK
    assert_eq!(written1, needed);

    // Discard events again: non-mutating
    unsafe { prod_vt_discard_events(vt) };

    // Export again: must produce byte-for-byte identical checkpoint!
    let mut buf2 = vec![0u8; needed];
    let mut written2: usize = 0;
    let st2 =
        unsafe { prod_vt_checkpoint_export2(vt, 0, buf2.as_mut_ptr(), buf2.len(), &mut written2) };
    assert_eq!(st2, 0); // PROD_VT_OK
    assert_eq!(written2, needed);
    assert_eq!(buf1, buf2, "checkpoint bytes must be identical");

    // Terminal title and viewport text must remain identical
    let title = unsafe { take_buffer(|o, l| prod_vt_title(vt, o, l)) }.unwrap();
    assert_eq!(String::from_utf8(title).unwrap(), "Export Title");

    let text = unsafe { take_buffer(|o, l| prod_vt_viewport_text(vt, o, l)) }.unwrap();
    assert!(String::from_utf8_lossy(&text).contains("Hello Checkpoint World!"));

    // Import into a target terminal
    let target_vt = unsafe { prod_vt_new(80, 24, 100) };
    let imp_st = unsafe { prod_vt_checkpoint_import2(target_vt, buf1.as_ptr(), buf1.len()) };
    assert_eq!(imp_st, 0); // PROD_VT_OK

    let imp_title = unsafe { take_buffer(|o, l| prod_vt_title(target_vt, o, l)) }.unwrap();
    assert_eq!(String::from_utf8(imp_title).unwrap(), "Export Title");

    // Discard events on imported terminal is safe
    unsafe { prod_vt_discard_events(target_vt) };

    unsafe {
        prod_vt_free(vt);
        prod_vt_free(target_vt);
    }
}
