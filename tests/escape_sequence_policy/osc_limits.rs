/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use tako_core::terminal::{Terminal, TerminalEvent};

#[test]
fn parser_raw_osc_payload_is_bounded() {
    use tako_core::parser::{MAX_OSC_RAW_BYTES, Parser, Perform};
    struct Dummy;
    impl Perform for Dummy {
        fn print(&mut self, _: char) {}
        fn execute(&mut self, _: u8) {}
        fn hook(&mut self, _: &[u16], _: u32, _: &[u8], _: bool, _: char) {}
        fn put(&mut self, _: u8) {}
        fn unhook(&mut self) {}
        fn osc_dispatch(&mut self, _: &[&[u8]], _: bool) {}
        fn csi_dispatch(&mut self, _: &[u16], _: u32, _: &[u8], _: bool, _: char) {}
        fn esc_dispatch(&mut self, _: &[u8], _: bool, _: u8) {}
    }
    let mut parser = Parser::new();
    let mut dummy = Dummy;
    // Enter OSC
    parser.advance_bytes(&mut dummy, b"\x1b]0;");
    // Feed beyond MAX_OSC_RAW_BYTES
    let chunk = vec![b'A'; 65536];
    let num_chunks = (MAX_OSC_RAW_BYTES / chunk.len()) + 2;
    for _ in 0..num_chunks {
        parser.advance_bytes(&mut dummy, &chunk);
    }
    assert_eq!(parser.view().osc_raw.len(), MAX_OSC_RAW_BYTES);
}

#[test]
fn osc99_chunk_accumulation_and_limits() {
    let mut term = Terminal::new(80, 24);

    // Part 1: title chunk 1 (100 chars), not done (d=0)
    let t1 = "A".repeat(100);
    let seq1 = format!("\x1b]99;i=test1:d=0:p=title;{t1}\x07");
    term.feed(seq1.as_bytes());

    // Part 2: title chunk 2 (100 chars), done (d=1) -> total 200 chars, must be clamped to 128
    let t2 = "B".repeat(100);
    let seq2 = format!("\x1b]99;i=test1:d=1:p=title;{t2}\x07");
    term.feed(seq2.as_bytes());

    let events = term.take_events();
    let notif = events
        .iter()
        .find_map(|e| match e {
            TerminalEvent::StructuredNotification { title, .. } => Some(title),
            _ => None,
        })
        .expect("structured notification emitted");

    assert_eq!(
        notif.chars().count(),
        128,
        "title accumulation clamped to 128 chars"
    );
}

#[test]
fn osc99_oversized_raw_chunk_rejected() {
    let mut term = Terminal::new(80, 24);

    // Chunk > 8192 bytes should be rejected before decoding
    let huge = "X".repeat(9000);
    let seq = format!("\x1b]99;i=huge:d=1:p=body;{huge}\x07");
    term.feed(seq.as_bytes());

    let events = term.take_events();
    assert!(events.is_empty(), "oversized OSC 99 chunk must be rejected");
}

#[test]
fn sanitizer_rescan_dos_resistance_with_stripped_controls() {
    let mut term = Terminal::new(80, 24);

    // 511 valid characters followed by 100,000 DEL (\x7f) control characters
    let mut hostile_input = "A".repeat(511);
    hostile_input.push_str(&"\x7f".repeat(100_000));

    let start = std::time::Instant::now();
    let sanitized = Terminal::sanitize_title(&hostile_input);
    let elapsed = start.elapsed();

    assert_eq!(sanitized.len(), 511);
    assert!(
        elapsed < std::time::Duration::from_millis(50),
        "sanitizer should finish quickly without O(N*M) rescan overhead, took {:?}",
        elapsed
    );

    // Also test through osc_dispatch
    let seq = format!("\x1b]0;{hostile_input}\x07");
    let start_feed = std::time::Instant::now();
    term.feed(seq.as_bytes());
    let elapsed_feed = start_feed.elapsed();
    assert!(
        elapsed_feed < std::time::Duration::from_millis(50),
        "terminal feed with hostile title took {:?}",
        elapsed_feed
    );
}

#[test]
fn osc_excessive_parameter_count_rejected() {
    let mut term = Terminal::new(80, 24);

    // 10,000 semicolons within OSC sequence
    let mut seq = Vec::from(b"\x1b]0");
    seq.extend(std::iter::repeat_n(b';', 10_000));
    seq.push(b'\x07');

    let start = std::time::Instant::now();
    term.feed(&seq);
    let elapsed = start.elapsed();

    assert!(
        elapsed < std::time::Duration::from_millis(50),
        "excessive parameter OSC took {:?}",
        elapsed
    );
    let events = term.take_events();
    assert!(
        events.is_empty(),
        "OSC with excessive parameters must be rejected without dispatching"
    );
}

#[test]
fn osc99_aggregate_multipart_payload_limit_enforced() {
    let mut term = Terminal::new(80, 24);

    // Multiple payload parts separated by semicolons exceeding 8192 bytes total
    let part = "A".repeat(1000);
    // 10 parts of 1000 bytes = 10,000 bytes > 8192 bytes
    let parts = vec![part; 10].join(";");
    let seq = format!("\x1b]99;i=agg:d=1:p=body;{parts}\x07");

    let start = std::time::Instant::now();
    term.feed(seq.as_bytes());
    let elapsed = start.elapsed();

    assert!(
        elapsed < std::time::Duration::from_millis(50),
        "aggregate OSC 99 parsing took {:?}",
        elapsed
    );
    let events = term.take_events();
    assert!(
        events.is_empty(),
        "OSC 99 exceeding aggregate payload size must be rejected"
    );
}

#[test]
fn parser_releases_oversized_buffers_when_canceled() {
    use tako_core::parser::{Parser, Perform};
    struct Dummy;
    impl Perform for Dummy {
        fn print(&mut self, _: char) {}
        fn execute(&mut self, _: u8) {}
        fn hook(&mut self, _: &[u16], _: u32, _: &[u8], _: bool, _: char) {}
        fn put(&mut self, _: u8) {}
        fn unhook(&mut self) {}
        fn osc_dispatch(&mut self, _: &[&[u8]], _: bool) {}
        fn csi_dispatch(&mut self, _: &[u16], _: u32, _: &[u8], _: bool, _: char) {}
        fn esc_dispatch(&mut self, _: &[u8], _: bool, _: u8) {}
    }

    let mut parser = Parser::new();
    let mut dummy = Dummy;

    // 1. Accumulate > 64 KiB into OSC buffer
    parser.advance_bytes(&mut dummy, b"\x1b]0;");
    let large_payload = vec![b'X'; 128 * 1024];
    parser.advance_bytes(&mut dummy, &large_payload);
    assert!(parser.retained_capacity_bytes() >= 128 * 1024);

    // Cancel sequence with CAN (0x18)
    parser.advance_bytes(&mut dummy, b"\x18");
    assert_eq!(
        parser.retained_capacity_bytes(),
        0,
        "canceling oversized OSC with CAN must reclaim memory"
    );

    // 2. Accumulate > 64 KiB into APC buffer
    parser.advance_bytes(&mut dummy, b"\x1b_");
    parser.advance_bytes(&mut dummy, &large_payload);
    assert!(parser.retained_capacity_bytes() >= 128 * 1024);

    // Cancel sequence with SUB (0x1A)
    parser.advance_bytes(&mut dummy, b"\x1a");
    assert_eq!(
        parser.retained_capacity_bytes(),
        0,
        "canceling oversized APC with SUB must reclaim memory"
    );
}
