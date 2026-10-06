/*
 * tako — Compact terminal emulator engine
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::{Action, MockPerformer};
use crate::parser::*;

fn advance_bytes_scalar<P: Perform>(parser: &mut Parser, performer: &mut P, bytes: &[u8]) {
    let mut offset = 0;
    while offset < bytes.len() {
        if parser.state == State::Ground && parser.utf8_need == 0 {
            let start = offset;
            while offset < bytes.len() && matches!(bytes[offset], 0x20..=0x7F) {
                offset += 1;
            }
            if offset - start > 1 {
                performer.print_slice(&bytes[start..offset]);
                continue;
            }
            offset = start;
        }

        parser.advance(performer, bytes[offset]);
        offset += 1;
    }
}

fn assert_parser_fields_eq(actual: &Parser, expected: &Parser) {
    assert_eq!(actual.state, expected.state);
    assert_eq!(actual.intermediates, expected.intermediates);
    assert_eq!(actual.params, expected.params);
    assert_eq!(actual.params_sep, expected.params_sep);
    assert_eq!(actual.ignore, expected.ignore);
    assert_eq!(actual.osc_raw, expected.osc_raw);
    assert_eq!(actual.apc_raw, expected.apc_raw);
    assert_eq!(actual.utf8_need, expected.utf8_need);
    assert_eq!(actual.utf8_cp, expected.utf8_cp);
}

fn deterministic_byte(seed: &mut u64) -> u8 {
    let mut x = *seed;
    x ^= x << 7;
    x ^= x >> 9;
    x ^= x << 8;
    *seed = x;
    (x & 0xff) as u8
}

fn assert_advance_bytes_matches_scalar(bytes: &[u8]) {
    let mut fast = Parser::new();
    let mut fast_performer = MockPerformer {
        actions: Vec::new(),
    };
    fast.advance_bytes(&mut fast_performer, bytes);

    let mut scalar = Parser::new();
    let mut scalar_performer = MockPerformer {
        actions: Vec::new(),
    };
    advance_bytes_scalar(&mut scalar, &mut scalar_performer, bytes);

    assert_eq!(fast_performer.actions, scalar_performer.actions);
    assert_parser_fields_eq(&fast, &scalar);
}

#[test]
fn advance_bytes_batches_only_ground_state_ascii() {
    let mut parser = Parser::new();
    let mut performer = MockPerformer {
        actions: Vec::new(),
    };
    parser.advance_bytes(&mut performer, b"hello\n\x1b[31mred");

    assert_eq!(
        performer.actions,
        vec![
            Action::PrintSlice(b"hello".to_vec()),
            Action::Execute(b'\n'),
            Action::CsiDispatch(vec![31], 0, vec![], false, 'm'),
            Action::PrintSlice(b"red".to_vec()),
        ]
    );
}

#[test]
fn advance_bytes_matches_scalar_reference_all_bytes() {
    let mut bytes: Vec<u8> = (0u8..=u8::MAX).collect();
    bytes.extend_from_slice(b"abc");
    assert_advance_bytes_matches_scalar(&bytes);
}

#[test]
fn advance_bytes_matches_scalar_reference_short_tail_and_random_sequences() {
    let seed = 0xD1EC_0DE0_BADA_55A5u64;
    for len in 0..64usize {
        let mut bytes = Vec::with_capacity(len);
        let mut mix = seed
            .wrapping_add(len as u64)
            .wrapping_mul(0x9E37_79B9_7F4A_7C15);
        for _ in 0..len {
            bytes.push(deterministic_byte(&mut mix));
        }
        assert_advance_bytes_matches_scalar(&bytes);

        let mut border = Vec::with_capacity(len + 32);
        border.extend(std::iter::repeat_n(0x20u8, 15));
        border.extend(std::iter::repeat_n(0x20u8, len % 2));
        border.push(0x1B);
        border.extend(std::iter::repeat_n(b'X', 17));
        border.extend_from_slice(&bytes);
        assert_advance_bytes_matches_scalar(&border);
    }

    assert_advance_bytes_matches_scalar(b"\x1B[31mHello\x07");
    assert_advance_bytes_matches_scalar(b"\x1B]0;Title\x1B\\");
}
