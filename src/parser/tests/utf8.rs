/*
 * tako — Compact terminal emulator engine
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::{Action, MockPerformer, parse_str};
use crate::parser::*;

#[test]
fn test_utf8_multibyte_sequences_decode_to_single_print_actions() {
    let performer = parse_str("h\u{00e9}\u{4e2d}\u{1f600}i");
    let printed: Vec<char> = performer
        .actions
        .iter()
        .filter_map(|a| match a {
            Action::Print(c) => Some(*c),
            _ => None,
        })
        .collect();
    assert_eq!(printed, vec!['h', '\u{00e9}', '\u{4e2d}', '\u{1f600}', 'i']);
}

#[test]
fn test_stray_utf8_continuation_byte_prints_replacement_char_without_panicking() {
    let mut parser = Parser::new();
    let mut performer = MockPerformer {
        actions: Vec::new(),
    };
    // A continuation byte (0x80..=0xBF) with no preceding lead byte.
    parser.advance(&mut performer, 0x80);
    parser.advance(&mut performer, b'x');
    assert_eq!(
        performer.actions,
        vec![Action::Print('\u{FFFD}'), Action::Print('x')]
    );
}

#[test]
fn test_malformed_ground_state_utf8_replacement_chars() {
    // 1. Bare continuation bytes in ground state yield replacement character U+FFFD
    {
        let mut parser = Parser::new();
        let mut performer = MockPerformer {
            actions: Vec::new(),
        };
        parser.advance(&mut performer, 0x9C); // Standalone 0x9C in ground state
        parser.advance(&mut performer, 0xBF);
        assert_eq!(
            performer.actions,
            vec![Action::Print('\u{FFFD}'), Action::Print('\u{FFFD}')]
        );
    }

    // 2. Invalid UTF-8 lead bytes in ground state yield replacement character U+FFFD
    {
        let mut parser = Parser::new();
        let mut performer = MockPerformer {
            actions: Vec::new(),
        };
        for &b in &[0xC0, 0xC1, 0xF5, 0xFF] {
            parser.advance(&mut performer, b);
        }
        assert_eq!(
            performer.actions,
            vec![
                Action::Print('\u{FFFD}'),
                Action::Print('\u{FFFD}'),
                Action::Print('\u{FFFD}'),
                Action::Print('\u{FFFD}'),
            ]
        );
    }
}
