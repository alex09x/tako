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
