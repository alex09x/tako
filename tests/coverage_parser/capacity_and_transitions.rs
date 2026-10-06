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

/// The default `print_slice` splits a slice into byte-by-byte `print` calls.
#[test]
fn default_perform_print_slice() {
    let mut parser = Parser::new();
    let mut performer = DefaultTraitPerformer::default();
    parser.advance_bytes(&mut performer, b"Rust");
    assert_eq!(performer.printed_chars, vec!['R', 'u', 's', 't']);
}

/// APC sequences dispatch through the trait default without panic.
#[test]
fn default_perform_apc_dispatch() {
    let mut parser = Parser::new();
    let mut performer = DefaultTraitPerformer::default();
    parser.advance_bytes(&mut performer, b"\x1b_test-payload\x1b\\");
    assert_eq!(parser.state, State::Ground);
}

/// Pins parser retained heap capacity tracking for in-flight OSC allocations.
#[test]
fn parser_retained_capacity_empty_and_buffers() {
    let mut parser = Parser::default();
    assert_eq!(parser.retained_capacity_bytes(), 0);

    let mut performer = TestPerformer::default();
    parser.advance(&mut performer, 0x1B);
    parser.advance(&mut performer, b']');
    for _ in 0..64 {
        parser.advance(&mut performer, b'A');
    }
    let osc_cap = parser.retained_capacity_bytes();
    assert!(
        osc_cap >= 64,
        "expected at least 64 bytes retained, got {osc_cap}"
    );
}

/// Pins parser retained capacity accounting when intermediates spill beyond inline storage.
#[test]
fn parser_retained_capacity_spilled_intermediates() {
    let mut parser = Parser::new();
    let mut performer = TestPerformer::default();
    // Feed CSI with 4 intermediates: SmallVec inline capacity is 2, so 4 forces heap spill.
    parser.advance(&mut performer, 0x1B);
    parser.advance(&mut performer, b'[');
    parser.advance(&mut performer, b' ');
    parser.advance(&mut performer, b'!');
    parser.advance(&mut performer, b'"');
    parser.advance(&mut performer, b'#');
    assert_eq!(parser.state, State::CsiIntermediate);
    let cap = parser.retained_capacity_bytes();
    assert!(
        cap >= 4,
        "intermediates spilled to heap must be counted in retained capacity: {cap}"
    );
    let view = parser.view();
    assert_eq!(view.intermediates, b" !\"#");
}

/// Pins parser retained capacity accounting when params spill beyond inline storage.
#[test]
fn parser_retained_capacity_spilled_params() {
    let mut parser = Parser::new();
    let mut params = smallvec::SmallVec::<[u16; 16]>::new();
    for i in 0..24 {
        params.push(i);
    }
    assert!(
        params.spilled(),
        "24 params must spill past 16 inline slots"
    );
    let snap = ParserSnapshot {
        state: State::CsiParam,
        intermediates: smallvec::SmallVec::new(),
        params,
        params_sep: 0,
        ignore: false,
        osc_raw: Vec::new(),
        apc_raw: Vec::new(),
        utf8_need: 0,
        utf8_cp: 0,
    };
    parser.restore(snap);
    let cap = parser.retained_capacity_bytes();
    assert!(
        cap >= 48,
        "spilled params (24 * 2 = 48 bytes min) must be counted: {cap}"
    );
}

/// parser checkpoint snapshot copies owned state and restore recovers continuation exactly.
#[test]
fn parser_snapshot_and_restore_fidelity() {
    let mut parser = Parser::new();
    let mut performer = TestPerformer::default();
    parser.advance_bytes(&mut performer, b"\x1b[12:34$");
    assert_eq!(parser.state, State::CsiIntermediate);

    let snap = parser.snapshot();
    assert_eq!(snap.state, State::CsiIntermediate);
    assert_eq!(snap.params.as_slice(), &[12, 34]);
    assert_eq!(snap.params_sep, 1);
    assert_eq!(snap.intermediates.as_slice(), b"$");
    assert!(!snap.ignore);

    let mut restored = Parser::default();
    restored.restore(snap);
    assert_eq!(restored.view().state, State::CsiIntermediate);
    assert_eq!(restored.view().params, &[12, 34]);
    assert_eq!(restored.view().params_sep, 1);
    assert_eq!(restored.view().intermediates, b"$");

    let mut finish_performer = TestPerformer::default();
    restored.advance(&mut finish_performer, b'p');
    assert_eq!(restored.state, State::Ground);
    assert_eq!(
        finish_performer.actions,
        vec![Action::CsiDispatch(vec![12, 34], 1, vec![b'$'], false, 'p')]
    );
}

/// CSI colon and semicolon with empty params initialize first param to 0.
#[test]
fn csi_entry_colon_and_semicolon_empty_params() {
    let mut parser = Parser::new();
    let mut performer = TestPerformer::default();
    parser.advance_bytes(&mut performer, b"\x1b[:5m");
    assert_eq!(
        performer.actions,
        vec![Action::CsiDispatch(vec![0, 5], 1, vec![], false, 'm')]
    );

    performer.actions.clear();
    parser.advance_bytes(&mut performer, b"\x1b[;7m");
    assert_eq!(
        performer.actions,
        vec![Action::CsiDispatch(vec![0, 7], 0, vec![], false, 'm')]
    );
}

/// parameters beyond 16 are ignored without overflowing SmallVec.
#[test]
fn csi_param_max_capacity_bound() {
    let mut parser = Parser::new();
    let mut performer = TestPerformer::default();
    parser.advance_bytes(
        &mut performer,
        b"\x1b[1;2;3;4;5;6;7;8;9;10;11;12;13;14;15;16;17;18;19;20m",
    );
    assert_eq!(performer.actions.len(), 1);
    if let Action::CsiDispatch(params, _sep, _inter, _ignore, action) = &performer.actions[0] {
        assert_eq!(*action, 'm');
        assert_eq!(params.len(), 16);
        // Parameters up to slot 15 are exact; subsequent digits accumulate into slot 16 saturating at u16::MAX
        assert_eq!(
            params,
            &[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 65535]
        );
    } else {
        panic!("expected CsiDispatch");
    }
}

/// EscapeIntermediate handles CAN/SUB, ESC restart, and invalid bytes.
#[test]
fn escape_intermediate_control_and_transitions() {
    let mut parser = Parser::new();
    let mut performer = TestPerformer::default();

    // CAN (0x18) executes and resets to Ground
    parser.advance_bytes(&mut performer, b"\x1b( \x18");
    assert_eq!(parser.state, State::Ground);
    assert_eq!(performer.actions, vec![Action::Execute(0x18)]);

    performer.actions.clear();
    // SUB (0x1A) executes and resets to Ground
    parser.advance_bytes(&mut performer, b"\x1b( \x1a");
    assert_eq!(parser.state, State::Ground);
    assert_eq!(performer.actions, vec![Action::Execute(0x1A)]);

    performer.actions.clear();
    // ESC (0x1B) cancels previous sequence and starts fresh Escape
    parser.advance_bytes(&mut performer, b"\x1b( \x1b[H");
    assert_eq!(parser.state, State::Ground);
    assert_eq!(
        performer.actions,
        vec![Action::CsiDispatch(vec![], 0, vec![], false, 'H')]
    );

    performer.actions.clear();
    // Invalid byte (0x80) resets to Ground
    parser.advance_bytes(&mut performer, b"\x1b( \x80");
    assert_eq!(parser.state, State::Ground);
}
