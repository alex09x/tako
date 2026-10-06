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

#[test]
fn test_esc_b() {
    let mut parser = Parser::new();
    let mut performer = MockPerformer {
        actions: Vec::new(),
    };
    parser.advance(&mut performer, 0x1B);
    parser.advance(&mut performer, b'(');
    parser.advance(&mut performer, b'B');

    assert_eq!(parser.state, State::Ground);
    assert_eq!(performer.actions.len(), 1);
    if let Action::EscDispatch(intermediates, ignore, byte) = &performer.actions[0] {
        assert_eq!(byte, &b'B');
        assert_eq!(intermediates, &vec![b'(']);
        assert!(!(*ignore));
    } else {
        panic!("Wrong action");
    }
}

#[test]
fn test_csi_h() {
    let mut parser = Parser::new();
    let mut p = MockPerformer {
        actions: Vec::new(),
    };
    parser.advance(&mut p, 0x1B);
    parser.advance(&mut p, b'[');
    parser.advance(&mut p, b'H');

    assert_eq!(parser.state, State::Ground);
    assert_eq!(p.actions.len(), 1);
    if let Action::CsiDispatch(params, _sep, _intermediates, _ignore, action) = &p.actions[0] {
        assert_eq!(*action, 'H');
        assert_eq!(params.len(), 0);
    } else {
        panic!("Wrong action");
    }
}

#[test]
fn test_csi_1_4_h() {
    let mut parser = Parser::new();
    let mut p = MockPerformer {
        actions: Vec::new(),
    };
    parser.advance(&mut p, 0x1B);
    parser.advance(&mut p, b'[');
    parser.advance(&mut p, b'1');
    parser.advance(&mut p, b';');
    parser.advance(&mut p, b'4');
    parser.advance(&mut p, b'H');

    assert_eq!(parser.state, State::Ground);
    if let Action::CsiDispatch(params, _sep, _intermediates, _ignore, action) = &p.actions[0] {
        assert_eq!(*action, 'H');
        assert_eq!(params.len(), 2);
        assert_eq!(params[0], 1);
        assert_eq!(params[1], 4);
    } else {
        panic!("Wrong action");
    }
}

#[test]
fn test_csi_sgr_colon() {
    let mut parser = Parser::new();
    let mut p = MockPerformer {
        actions: Vec::new(),
    };
    for b in b"\x1B[38:2m" {
        parser.advance(&mut p, *b);
    }

    assert_eq!(parser.state, State::Ground);
    if let Action::CsiDispatch(params, sep, _intermediates, _ignore, action) = &p.actions[0] {
        assert_eq!(*action, 'm');
        assert_eq!(params.len(), 2);
        assert_eq!(params[0], 38);
        assert_eq!(params[1], 2);
        assert_eq!(sep & (1 << 0), 1); // first sep is colon
    } else {
        panic!("Wrong action");
    }
}
