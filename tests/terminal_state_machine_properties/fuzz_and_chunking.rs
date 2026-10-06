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
use super::operations::*;

#[test]
fn test_fuzz_state_machine_sequences_across_seeds() {
    for &seed in FIXED_SEEDS {
        let mut rng = SimpleRng::new(seed);
        let init_cols = rng.gen_range(1, 100);
        let init_rows = rng.gen_range(1, 50);
        let mut term = Terminal::new(init_cols, init_rows);

        assert_durable_invariants(&term);

        let op_count = rng.gen_range(200, 350);
        for step in 0..op_count {
            let op = generate_random_op(&mut rng);
            apply_op(&mut term, &op, &mut rng);

            // Periodically or after every step verify invariants
            if (step % 5 == 0 || step == op_count - 1)
                && std::panic::catch_unwind(|| assert_durable_invariants(&term)).is_err()
            {
                panic!("seed {seed}, step {step}, after {op:?}");
            }
        }
    }
}

#[test]
fn test_property_chunking_independence() {
    for &seed in FIXED_SEEDS {
        let mut rng = SimpleRng::new(seed);
        let cols = rng.gen_range(10, 80);
        let rows = rng.gen_range(4, 30);

        // Build a deterministic byte stream
        let mut stream = Vec::new();
        let snippet_count = rng.gen_range(30, 80);
        for _ in 0..snippet_count {
            match rng.gen_range(0, 4) {
                0 => stream.extend_from_slice(rng.choose(CURATED_VT_SNIPPETS)),
                1 => stream.extend_from_slice(rng.choose(CURATED_UTF8_TEXT).as_bytes()),
                2 => {
                    let len = rng.gen_range(1, 32);
                    let ascii = (0..len)
                        .map(|_| rng.gen_range(0x20, 0x7e) as u8)
                        .collect::<Vec<_>>();
                    stream.extend_from_slice(&ascii);
                }
                _ => {
                    let len = rng.gen_range(1, 16);
                    let raw = rng.gen_bytes(len);
                    stream.extend_from_slice(&raw);
                }
            }
        }

        // Terminal A: single chunk feed
        let mut term_single = Terminal::new(cols, rows);
        term_single.feed(&stream);
        let single_output = term_single.take_output();
        let single_events = term_single.take_events();
        let single_dump = term_single.dump();
        let single_cursor = term_single.cursor();
        let single_screen = term_single.active_screen();
        let single_visible = term_single.cursor_visible();
        let single_title = term_single.title().to_string();
        let single_plain = term_single.plain_string();
        let single_unwrapped = term_single.plain_string_unwrapped();
        let single_buffer = term_single.buffer_text();

        // Terminal B: byte-by-byte feed
        let mut term_bytes = Terminal::new(cols, rows);
        for &b in &stream {
            term_bytes.feed(&[b]);
        }
        let bytes_output = term_bytes.take_output();
        let bytes_events = term_bytes.take_events();
        let bytes_dump = term_bytes.dump();
        let bytes_cursor = term_bytes.cursor();
        let bytes_screen = term_bytes.active_screen();
        let bytes_visible = term_bytes.cursor_visible();
        let bytes_title = term_bytes.title().to_string();
        let bytes_plain = term_bytes.plain_string();
        let bytes_unwrapped = term_bytes.plain_string_unwrapped();
        let bytes_buffer = term_bytes.buffer_text();

        assert_eq!(
            single_cursor, bytes_cursor,
            "seed {seed}: cursor mismatch between single-feed and byte-by-byte feed"
        );
        assert_eq!(
            single_screen, bytes_screen,
            "seed {seed}: screen buffer mismatch"
        );
        assert_eq!(
            single_visible, bytes_visible,
            "seed {seed}: cursor visibility mismatch"
        );
        assert_eq!(single_title, bytes_title, "seed {seed}: title mismatch");
        assert_eq!(
            single_dump, bytes_dump,
            "seed {seed}: dump mismatch between single-feed and byte-by-byte feed"
        );
        assert_eq!(
            single_plain, bytes_plain,
            "seed {seed}: plain_string mismatch"
        );
        assert_eq!(
            single_unwrapped, bytes_unwrapped,
            "seed {seed}: plain_string_unwrapped mismatch"
        );
        assert_eq!(
            single_buffer, bytes_buffer,
            "seed {seed}: buffer_text mismatch"
        );
        assert_eq!(
            single_output, bytes_output,
            "seed {seed}: response output mismatch"
        );
        assert_eq!(
            single_events, bytes_events,
            "seed {seed}: terminal events mismatch"
        );

        // Terminal C: randomized chunk partitions
        let mut term_random_chunks = Terminal::new(cols, rows);
        let mut offset = 0;
        while offset < stream.len() {
            let chunk_len = rng.gen_range(1, 15).min(stream.len() - offset);
            term_random_chunks.feed(&stream[offset..offset + chunk_len]);
            offset += chunk_len;
        }

        assert_eq!(
            single_dump,
            term_random_chunks.dump(),
            "seed {seed}: dump mismatch with randomized chunking"
        );
        assert_eq!(
            single_output,
            term_random_chunks.take_output(),
            "seed {seed}: output mismatch with randomized chunking"
        );
        assert_eq!(
            single_events,
            term_random_chunks.take_events(),
            "seed {seed}: events mismatch with randomized chunking"
        );

        assert_durable_invariants(&term_single);
        assert_durable_invariants(&term_bytes);
        assert_durable_invariants(&term_random_chunks);
    }
}
