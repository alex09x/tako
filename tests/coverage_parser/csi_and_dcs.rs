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

/// CsiEntry handles CAN/SUB, ESC restart, and non-ASCII fallback.
#[test]
fn csi_entry_control_and_transitions() {
    let mut parser = Parser::new();
    let mut performer = TestPerformer::default();

    // CAN (0x18) in CsiEntry executes and resets to Ground
    parser.advance_bytes(&mut performer, b"\x1b[\x18");
    assert_eq!(parser.state, State::Ground);
    assert_eq!(performer.actions, vec![Action::Execute(0x18)]);

    performer.actions.clear();
    // SUB (0x1A) in CsiEntry executes and resets to Ground
    parser.advance_bytes(&mut performer, b"\x1b[\x1a");
    assert_eq!(parser.state, State::Ground);
    assert_eq!(performer.actions, vec![Action::Execute(0x1A)]);

    performer.actions.clear();
    // ESC (0x1B) in CsiEntry restarts Escape state
    parser.advance_bytes(&mut performer, b"\x1b[\x1b[H");
    assert_eq!(parser.state, State::Ground);
    assert_eq!(
        performer.actions,
        vec![Action::CsiDispatch(vec![], 0, vec![], false, 'H')]
    );

    performer.actions.clear();
    // Non-ASCII byte (0x80) in CsiEntry falls through to Ground
    parser.advance_bytes(&mut performer, b"\x1b[\x80");
    assert_eq!(parser.state, State::Ground);
}

/// CsiParam handles CAN/SUB, ESC restart, private marker ignore, and non-ASCII fallback.
#[test]
fn csi_param_control_and_transitions() {
    let mut parser = Parser::new();
    let mut performer = TestPerformer::default();

    // CAN (0x18) in CsiParam executes and resets to Ground
    parser.advance_bytes(&mut performer, b"\x1b[12\x18");
    assert_eq!(parser.state, State::Ground);
    assert_eq!(performer.actions, vec![Action::Execute(0x18)]);

    performer.actions.clear();
    // SUB (0x1A) in CsiParam executes and resets to Ground
    parser.advance_bytes(&mut performer, b"\x1b[12\x1a");
    assert_eq!(parser.state, State::Ground);
    assert_eq!(performer.actions, vec![Action::Execute(0x1A)]);

    performer.actions.clear();
    // ESC (0x1B) in CsiParam restarts Escape
    parser.advance_bytes(&mut performer, b"\x1b[12\x1b[H");
    assert_eq!(parser.state, State::Ground);
    assert_eq!(
        performer.actions,
        vec![Action::CsiDispatch(vec![], 0, vec![], false, 'H')]
    );

    performer.actions.clear();
    // Private marker in CsiParam sets ignore flag
    parser.advance_bytes(&mut performer, b"\x1b[12?m");
    assert_eq!(parser.state, State::Ground);
    assert_eq!(
        performer.actions,
        vec![Action::CsiDispatch(vec![12], 0, vec![], true, 'm')]
    );

    performer.actions.clear();
    // Non-ASCII byte (0x80) in CsiParam transitions to Ground
    parser.advance_bytes(&mut performer, b"\x1b[12\x80");
    assert_eq!(parser.state, State::Ground);
}

/// CsiIntermediate handles CAN/SUB, ESC restart, trailing digits, and non-ASCII fallback.
#[test]
fn csi_intermediate_control_and_transitions() {
    let mut parser = Parser::new();
    let mut performer = TestPerformer::default();

    // CAN in CsiIntermediate executes and resets to Ground
    parser.advance_bytes(&mut performer, b"\x1b[ $\x18");
    assert_eq!(parser.state, State::Ground);
    assert_eq!(performer.actions, vec![Action::Execute(0x18)]);

    performer.actions.clear();
    // SUB in CsiIntermediate executes and resets to Ground
    parser.advance_bytes(&mut performer, b"\x1b[ $\x1a");
    assert_eq!(parser.state, State::Ground);
    assert_eq!(performer.actions, vec![Action::Execute(0x1A)]);

    performer.actions.clear();
    // ESC in CsiIntermediate restarts Escape
    parser.advance_bytes(&mut performer, b"\x1b[ $\x1b[H");
    assert_eq!(parser.state, State::Ground);
    assert_eq!(
        performer.actions,
        vec![Action::CsiDispatch(vec![], 0, vec![], false, 'H')]
    );

    performer.actions.clear();
    // Digit after intermediate sets ignore flag
    parser.advance_bytes(&mut performer, b"\x1b[ $1m");
    assert_eq!(parser.state, State::Ground);
    assert_eq!(
        performer.actions,
        vec![Action::CsiDispatch(vec![], 0, vec![b' ', b'$'], true, 'm')]
    );

    performer.actions.clear();
    // Non-ASCII byte in CsiIntermediate transitions to Ground
    parser.advance_bytes(&mut performer, b"\x1b[ $\x80");
    assert_eq!(parser.state, State::Ground);
}

/// DcsEntry handles direct colon/semicolon params and non-ASCII fallback.
#[test]
fn dcs_entry_colon_semicolon_and_fallback() {
    let mut parser = Parser::new();
    let mut performer = TestPerformer::default();

    // Semicolon immediately after DCS entry creates param 0; terminated with 7-bit ST (ESC \)
    parser.advance_bytes(&mut performer, b"\x1bP;2p\x1b\\");
    assert_eq!(
        performer.actions,
        vec![
            Action::Hook(vec![0, 2], 0, vec![], false, 'p'),
            Action::Unhook,
            Action::EscDispatch(vec![], false, b'\\'),
        ]
    );

    performer.actions.clear();
    // Colon immediately after DCS entry creates colon-separated param 0
    parser.advance_bytes(&mut performer, b"\x1bP:2p\x1b\\");
    assert_eq!(
        performer.actions,
        vec![
            Action::Hook(vec![0, 2], 1, vec![], false, 'p'),
            Action::Unhook,
            Action::EscDispatch(vec![], false, b'\\'),
        ]
    );

    performer.actions.clear();
    // Non-ASCII byte in DcsEntry transitions to Ground
    parser.advance_bytes(&mut performer, b"\x1bP\x80");
    assert_eq!(parser.state, State::Ground);
}

/// DcsParam handles control ignore, CAN/SUB cancel, intermediates, colons, markers, and actions.
#[test]
fn dcs_param_comprehensive() {
    let mut parser = Parser::new();
    let mut performer = TestPerformer::default();

    // In DcsParam: control byte (0x05) ignored without leaving state
    parser.advance_bytes(&mut performer, b"\x1bP1\x05");
    assert_eq!(parser.state, State::DcsParam);

    // CAN cancels to Escape
    parser.advance(&mut performer, 0x18);
    assert_eq!(parser.state, State::Escape);
    parser.advance(&mut performer, b'c');
    assert_eq!(parser.state, State::Ground);

    performer.actions.clear();
    // SUB cancels to Escape
    parser.advance_bytes(&mut performer, b"\x1bP1\x1a");
    assert_eq!(parser.state, State::Escape);
    parser.advance(&mut performer, b'c');
    assert_eq!(parser.state, State::Ground);

    performer.actions.clear();
    // Intermediate transition in DcsParam
    parser.advance_bytes(&mut performer, b"\x1bP1 $q\x1b\\");
    assert_eq!(
        performer.actions,
        vec![
            Action::Hook(vec![1], 0, vec![b' ', b'$'], false, 'q'),
            Action::Unhook,
            Action::EscDispatch(vec![], false, b'\\'),
        ]
    );

    performer.actions.clear();
    // Colon and semicolon and digit parsing in DcsParam
    parser.advance_bytes(&mut performer, b"\x1bP12;34:56p\x1b\\");
    assert_eq!(
        performer.actions,
        vec![
            Action::Hook(vec![12, 34, 56], 2, vec![], false, 'p'),
            Action::Unhook,
            Action::EscDispatch(vec![], false, b'\\'),
        ]
    );

    performer.actions.clear();
    // Private marker in DcsParam sets ignore flag
    parser.advance_bytes(&mut performer, b"\x1bP1?p\x1b\\");
    assert_eq!(
        performer.actions,
        vec![
            Action::Hook(vec![1], 0, vec![], true, 'p'),
            Action::Unhook,
            Action::EscDispatch(vec![], false, b'\\'),
        ]
    );

    performer.actions.clear();
    // Non-ASCII byte in DcsParam transitions to Ground
    parser.advance_bytes(&mut performer, b"\x1bP1\x80");
    assert_eq!(parser.state, State::Ground);
}

/// DcsIntermediate handles CAN/SUB, ESC restart, digits setting ignore, and non-ASCII fallback.
#[test]
fn dcs_intermediate_control_and_transitions() {
    let mut parser = Parser::new();
    let mut performer = TestPerformer::default();

    // CAN in DcsIntermediate transitions to Escape
    parser.advance_bytes(&mut performer, b"\x1bP $\x18");
    assert_eq!(parser.state, State::Escape);

    // SUB in DcsIntermediate transitions to Escape
    parser.advance_bytes(&mut performer, b"c\x1bP $\x1a");
    assert_eq!(parser.state, State::Escape);

    // ESC in DcsIntermediate transitions to Escape
    parser.advance_bytes(&mut performer, b"c\x1bP $\x1b[H");
    assert_eq!(parser.state, State::Ground);

    performer.actions.clear();
    // Digit in DcsIntermediate sets ignore flag
    parser.advance_bytes(&mut performer, b"\x1bP $1p\x1b\\");
    assert_eq!(
        performer.actions,
        vec![
            Action::Hook(vec![], 0, vec![b' ', b'$'], true, 'p'),
            Action::Unhook,
            Action::EscDispatch(vec![], false, b'\\'),
        ]
    );

    performer.actions.clear();
    // Non-ASCII byte in DcsIntermediate transitions to Ground
    parser.advance_bytes(&mut performer, b"\x1bP $\x80");
    assert_eq!(parser.state, State::Ground);
}
