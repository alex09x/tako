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

/// DcsPassthrough routes control bytes to put and unhooks on CAN/SUB or non-ASCII.
#[test]
fn dcs_passthrough_control_put_and_cancel() {
    let mut parser = Parser::new();
    let mut performer = TestPerformer::default();

    // Control byte < 0x20 during passthrough is routed to put()
    parser.advance_bytes(&mut performer, b"\x1bP0p\x05A\x1b\\");
    assert_eq!(
        performer.actions,
        vec![
            Action::Hook(vec![0], 0, vec![], false, 'p'),
            Action::Put(0x05),
            Action::Put(b'A'),
            Action::Unhook,
            Action::EscDispatch(vec![], false, b'\\'),
        ]
    );

    performer.actions.clear();
    // CAN (0x18) during passthrough unhooks and returns to Ground
    parser.advance_bytes(&mut performer, b"\x1bP0pABC\x18");
    assert_eq!(parser.state, State::Ground);
    assert_eq!(
        performer.actions,
        vec![
            Action::Hook(vec![0], 0, vec![], false, 'p'),
            Action::Put(b'A'),
            Action::Put(b'B'),
            Action::Put(b'C'),
            Action::Unhook,
        ]
    );

    performer.actions.clear();
    // SUB (0x1A) during passthrough unhooks and returns to Ground
    parser.advance_bytes(&mut performer, b"\x1bP0p\x1a");
    assert_eq!(parser.state, State::Ground);
    assert_eq!(
        performer.actions,
        vec![Action::Hook(vec![0], 0, vec![], false, 'p'), Action::Unhook,]
    );

    performer.actions.clear();
    // Non-ASCII byte during passthrough unhooks and returns to Ground
    parser.advance_bytes(&mut performer, b"\x1bP0p\x80");
    assert_eq!(parser.state, State::Ground);
    assert_eq!(
        performer.actions,
        vec![Action::Hook(vec![0], 0, vec![], false, 'p'), Action::Unhook,]
    );
}

/// DcsIgnore consumes bytes until CAN, SUB, or ESC restart.
#[test]
fn dcs_ignore_state_transitions() {
    let mut parser = Parser::new();
    let mut performer = TestPerformer::default();

    // DcsIgnore is a quiescent error state restored from checkpoints
    parser.state = State::DcsIgnore;
    parser.advance(&mut performer, b'a');
    parser.advance(&mut performer, b'b');
    assert_eq!(parser.state, State::DcsIgnore);

    // CAN resets to Ground
    parser.advance(&mut performer, 0x18);
    assert_eq!(parser.state, State::Ground);

    // SUB resets to Ground
    parser.state = State::DcsIgnore;
    parser.advance(&mut performer, 0x1A);
    assert_eq!(parser.state, State::Ground);

    // ESC transitions to Escape
    parser.state = State::DcsIgnore;
    parser.advance(&mut performer, 0x1B);
    assert_eq!(parser.state, State::Escape);
}

/// OscString decodes 4-byte UTF-8, preserves raw high bytes, and handles 8-bit ST.
#[test]
fn osc_string_4byte_utf8_continuation_and_invalids() {
    let mut parser = Parser::new();
    let mut performer = TestPerformer::default();

    // 4-byte UTF-8 emoji in OSC title (0xF0..=0xF4 lead byte)
    parser.advance_bytes(&mut performer, b"\x1b]0;\xf0\x9f\xa6\x80\x07");
    assert_eq!(parser.state, State::Ground);
    assert_eq!(
        performer.actions,
        vec![Action::OscDispatch(
            vec![b"0".to_vec(), "🦀".as_bytes().to_vec()],
            true
        )]
    );

    performer.actions.clear();
    // Stray continuation byte (0x80) when utf8_need == 0 pushed as raw byte
    parser.advance_bytes(&mut performer, b"\x1b]0;\x80\x07");
    assert_eq!(parser.state, State::Ground);
    assert_eq!(
        performer.actions,
        vec![Action::OscDispatch(vec![b"0".to_vec(), vec![0x80]], true)]
    );

    performer.actions.clear();
    // 8-bit ST (0x9C) terminates OSC without bell flag
    parser.advance_bytes(&mut performer, b"\x1b]2;window\x9c");
    assert_eq!(parser.state, State::Ground);
    assert_eq!(
        performer.actions,
        vec![Action::OscDispatch(
            vec![b"2".to_vec(), b"window".to_vec()],
            false
        )]
    );

    performer.actions.clear();
    // Invalid high byte >= 0x80 (e.g. 0xFF) pushed as raw byte
    parser.advance_bytes(&mut performer, b"\x1b]0;\xff\x07");
    assert_eq!(parser.state, State::Ground);
    assert_eq!(
        performer.actions,
        vec![Action::OscDispatch(vec![b"0".to_vec(), vec![0xFF]], true)]
    );

    performer.actions.clear();
    // CAN (0x18) cancels OSC cleanly without dispatch
    parser.advance_bytes(&mut performer, b"\x1b]0;aborted\x18");
    assert_eq!(parser.state, State::Ground);
    assert!(performer.actions.is_empty());
}

/// SOS, PM, and APC buffers collect multi-byte UTF-8 and dispatch on ST.
#[test]
fn sos_pm_apc_comprehensive() {
    let mut parser = Parser::new();
    let mut performer = TestPerformer::default();

    // APC with 2-byte, 3-byte, and 4-byte UTF-8, terminated by 7-bit ST (ESC \)
    let utf8_payload = "café € 🦀".as_bytes();
    let mut seq = b"\x1b_".to_vec();
    seq.extend_from_slice(utf8_payload);
    seq.extend_from_slice(b"\x1b\\");
    parser.advance_bytes(&mut performer, &seq);
    assert_eq!(parser.state, State::Ground);
    assert_eq!(
        performer.actions,
        vec![
            Action::ApcDispatch(utf8_payload.to_vec()),
            Action::EscDispatch(vec![], false, b'\\'),
        ]
    );

    performer.actions.clear();
    // PM string terminated by 8-bit ST (0x9C)
    parser.advance_bytes(&mut performer, b"\x1b^privacy-data\x9c");
    assert_eq!(parser.state, State::Ground);
    assert_eq!(
        performer.actions,
        vec![Action::ApcDispatch(b"privacy-data".to_vec())]
    );

    performer.actions.clear();
    // SOS string cancelled by CAN (0x18)
    parser.advance_bytes(&mut performer, b"\x1bXcancelled\x18");
    assert_eq!(parser.state, State::Ground);
    assert!(performer.actions.is_empty());

    performer.actions.clear();
    // APC with raw high bytes (>= 0x80)
    parser.advance_bytes(&mut performer, b"\x1b_\x80\xff\x9c");
    assert_eq!(parser.state, State::Ground);
    assert_eq!(
        performer.actions,
        vec![Action::ApcDispatch(vec![0x80, 0xFF])]
    );
}

/// unhandled state variants like CsiIgnore fall back to Ground.
#[test]
fn unhandled_state_fallback() {
    let mut parser = Parser::new();
    let mut performer = TestPerformer::default();

    // CsiIgnore is defined in State and restored by checkpoints, but advance falls through to Ground
    parser.state = State::CsiIgnore;
    parser.advance(&mut performer, b'A');
    assert_eq!(parser.state, State::Ground);
}

/// sequences with more than 16 intermediate bytes set ignore flag.
#[test]
fn intermediate_limit_sets_ignore() {
    let mut parser = Parser::new();
    let mut performer = TestPerformer::default();

    // 17 intermediate bytes in CSI
    parser.advance_bytes(&mut performer, b"\x1b[ !\"#$%&'()*+,-./ !m");
    assert_eq!(parser.state, State::Ground);
    assert_eq!(performer.actions.len(), 1);
    if let Action::CsiDispatch(_params, _sep, _inter, ignore, action) = &performer.actions[0] {
        assert_eq!(*action, 'm');
        assert!(*ignore, "more than 16 intermediates must set ignore");
    } else {
        panic!("expected CsiDispatch");
    }
}

/// numeric CSI parameter values saturate at u16::MAX instead of wrapping.
#[test]
fn param_u16_overflow_saturates() {
    let mut parser = Parser::new();
    let mut performer = TestPerformer::default();

    parser.advance_bytes(&mut performer, b"\x1b[999999999m");
    assert_eq!(parser.state, State::Ground);
    assert_eq!(
        performer.actions,
        vec![Action::CsiDispatch(vec![u16::MAX], 0, vec![], false, 'm')]
    );
}

/// invalid UTF-8 lead bytes and premature ASCII interruptions print replacement characters.
#[test]
fn ground_utf8_errors_and_recovery() {
    let mut parser = Parser::new();
    let mut performer = TestPerformer::default();

    // Invalid lead bytes 0xC0 and 0xFF produce replacement character
    parser.advance(&mut performer, 0xC0);
    parser.advance(&mut performer, 0xFF);
    assert_eq!(
        performer.actions,
        vec![Action::Print('\u{FFFD}'), Action::Print('\u{FFFD}')]
    );

    performer.actions.clear();
    // Interrupted 4-byte UTF-8 sequence resets utf8_need and processes ASCII byte immediately
    parser.advance(&mut performer, 0xF0);
    parser.advance(&mut performer, b'Z');
    assert_eq!(performer.actions, vec![Action::Print('Z')]);
}

/// Terminal end-to-end integration drives parser through Terminal::feed public API.
#[test]
fn terminal_end_to_end_integration() {
    let mut term = Terminal::new(80, 24);

    // Set title via OSC 0
    term.feed(b"\x1b]0;Coverage Title\x07");
    assert_eq!(term.title(), "Coverage Title");

    // SGR styling and text feed
    term.feed(b"\x1b[1;32mGreen\x1b[0m");
    assert_eq!(term.cursor(), (0, 5));

    // Move cursor with CSI H
    term.feed(b"\x1b[5;10H");
    assert_eq!(term.cursor(), (4, 9));

    // DCS query response (DECRQSS)
    term.feed(b"\x1bP$qm\x1b\\");
    let out = term.take_output();
    assert!(!out.is_empty());
}
