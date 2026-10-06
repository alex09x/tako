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
fn test_osc_title() {
    let mut parser = Parser::new();
    let mut p = MockPerformer {
        actions: Vec::new(),
    };
    for b in b"\x1B]0;Hello\x07" {
        parser.advance(&mut p, *b);
    }

    assert_eq!(parser.state, State::Ground);
    if let Action::OscDispatch(params, bell) = &p.actions[0] {
        assert!(*bell);
        assert_eq!(params.len(), 2);
        assert_eq!(params[0], b"0");
        assert_eq!(params[1], b"Hello");
    } else {
        panic!("Wrong action");
    }
}

#[test]
fn test_osc_title_st() {
    let mut parser = Parser::new();
    let mut p = MockPerformer {
        actions: Vec::new(),
    };
    for b in b"\x1B]0;Hello\x1B\\" {
        parser.advance(&mut p, *b);
    }

    assert_eq!(parser.state, State::Ground);
    if let Action::OscDispatch(params, bell) = &p.actions[0] {
        assert!(!(*bell));
        assert_eq!(params.len(), 2);
        assert_eq!(params[0], b"0");
        assert_eq!(params[1], b"Hello");
    } else {
        panic!("Wrong action");
    }
}

#[test]
fn test_osc_utf8_claude_symbol_whole_and_split_feed() {
    // Claude symbol U+2733 is UTF-8 encoded as E2 9C B3.
    let claude_symbol_bytes = "\u{2733}".as_bytes(); // [0xE2, 0x9C, 0xB3]
    assert_eq!(claude_symbol_bytes, &[0xE2, 0x9C, 0xB3]);

    // 1. Whole feed terminated with BEL (0x07)
    {
        let mut parser = Parser::new();
        let mut p = MockPerformer {
            actions: Vec::new(),
        };
        for &b in b"\x1B]0;Claude \xE2\x9C\xB3 symbol\x07" {
            parser.advance(&mut p, b);
        }
        assert_eq!(parser.state, State::Ground);
        assert_eq!(p.actions.len(), 1);
        if let Action::OscDispatch(params, bell) = &p.actions[0] {
            assert!(*bell);
            assert_eq!(params.len(), 2);
            assert_eq!(params[0], b"0");
            assert_eq!(params[1], "Claude \u{2733} symbol".as_bytes());
        } else {
            panic!("Expected OscDispatch");
        }
    }

    // 2. Whole feed terminated with ESC \ (0x1B 0x5C)
    {
        let mut parser = Parser::new();
        let mut p = MockPerformer {
            actions: Vec::new(),
        };
        for &b in b"\x1B]0;Claude \xE2\x9C\xB3 symbol\x1B\\" {
            parser.advance(&mut p, b);
        }
        assert_eq!(parser.state, State::Ground);
        assert_eq!(
            p.actions,
            vec![
                Action::OscDispatch(
                    vec![b"0".to_vec(), "Claude \u{2733} symbol".as_bytes().to_vec()],
                    false
                ),
                Action::EscDispatch(vec![], false, b'\\'),
            ]
        );
    }

    // 3. Whole feed terminated with genuine bare C1 ST (0x9C)
    {
        let mut parser = Parser::new();
        let mut p = MockPerformer {
            actions: Vec::new(),
        };
        for &b in b"\x1B]0;Claude \xE2\x9C\xB3 symbol\x9C" {
            parser.advance(&mut p, b);
        }
        assert_eq!(parser.state, State::Ground);
        assert_eq!(
            p.actions,
            vec![Action::OscDispatch(
                vec![b"0".to_vec(), "Claude \u{2733} symbol".as_bytes().to_vec()],
                false
            )]
        );
    }

    // 4. Split feed split right on the continuation byte 0x9C
    {
        let mut parser = Parser::new();
        let mut p = MockPerformer {
            actions: Vec::new(),
        };
        let chunk1 = b"\x1B]0;Claude \xE2";
        let chunk2 = b"\x9C\xB3 symbol\x07";
        for &b in chunk1 {
            parser.advance(&mut p, b);
        }
        assert_eq!(parser.state, State::OscString);
        for &b in chunk2 {
            parser.advance(&mut p, b);
        }
        assert_eq!(parser.state, State::Ground);
        assert_eq!(
            p.actions,
            vec![Action::OscDispatch(
                vec![b"0".to_vec(), "Claude \u{2733} symbol".as_bytes().to_vec()],
                true
            )]
        );
    }

    // 5. Byte-by-byte feed terminated by bare C1 ST
    {
        let mut parser = Parser::new();
        let mut p = MockPerformer {
            actions: Vec::new(),
        };
        for &b in b"\x1B]0;Claude \xE2\x9C\xB3 symbol\x9C" {
            parser.advance(&mut p, b);
        }
        assert_eq!(parser.state, State::Ground);
        assert_eq!(
            p.actions,
            vec![Action::OscDispatch(
                vec![b"0".to_vec(), "Claude \u{2733} symbol".as_bytes().to_vec()],
                false
            )]
        );
    }
}

#[test]
fn test_apc_utf8_claude_symbol_whole_and_split_feed() {
    // 1. Whole feed terminated with ESC \
    {
        let mut parser = Parser::new();
        let mut p = MockPerformer {
            actions: Vec::new(),
        };
        for &b in b"\x1B_GClaude \xE2\x9C\xB3 symbol\x1B\\" {
            parser.advance(&mut p, b);
        }
        assert_eq!(parser.state, State::Ground);
        assert_eq!(
            p.actions,
            vec![
                Action::ApcDispatch("GClaude \u{2733} symbol".as_bytes().to_vec()),
                Action::EscDispatch(vec![], false, b'\\'),
            ]
        );
    }

    // 2. Whole feed terminated with bare C1 ST (0x9C)
    {
        let mut parser = Parser::new();
        let mut p = MockPerformer {
            actions: Vec::new(),
        };
        for &b in b"\x1B_GClaude \xE2\x9C\xB3 symbol\x9C" {
            parser.advance(&mut p, b);
        }
        assert_eq!(parser.state, State::Ground);
        assert_eq!(
            p.actions,
            vec![Action::ApcDispatch(
                "GClaude \u{2733} symbol".as_bytes().to_vec()
            )]
        );
    }

    // 3. Split feed split right on the continuation byte 0x9C
    {
        let mut parser = Parser::new();
        let mut p = MockPerformer {
            actions: Vec::new(),
        };
        let chunk1 = b"\x1B_GClaude \xE2";
        let chunk2 = b"\x9C\xB3 symbol\x9C";
        for &b in chunk1 {
            parser.advance(&mut p, b);
        }
        assert_eq!(parser.state, State::SosPmApcString);
        for &b in chunk2 {
            parser.advance(&mut p, b);
        }
        assert_eq!(parser.state, State::Ground);
        assert_eq!(
            p.actions,
            vec![Action::ApcDispatch(
                "GClaude \u{2733} symbol".as_bytes().to_vec()
            )]
        );
    }
}

#[test]
fn test_osc_and_apc_genuine_bare_c1_st() {
    // OSC string terminated by bare C1 ST 0x9C when no UTF-8 continuation is pending
    {
        let mut parser = Parser::new();
        let mut p = MockPerformer {
            actions: Vec::new(),
        };
        for &b in b"\x1B]0;My Title\x9C" {
            parser.advance(&mut p, b);
        }
        assert_eq!(parser.state, State::Ground);
        assert_eq!(
            p.actions,
            vec![Action::OscDispatch(
                vec![b"0".to_vec(), b"My Title".to_vec()],
                false
            )]
        );
    }

    // APC string terminated by bare C1 ST 0x9C when no UTF-8 continuation is pending
    {
        let mut parser = Parser::new();
        let mut p = MockPerformer {
            actions: Vec::new(),
        };
        for &b in b"\x1B_Ga=T,f=100;payload_data\x9C" {
            parser.advance(&mut p, b);
        }
        assert_eq!(parser.state, State::Ground);
        assert_eq!(
            p.actions,
            vec![Action::ApcDispatch(b"Ga=T,f=100;payload_data".to_vec())]
        );
    }
}

#[test]
fn test_osc_and_apc_encoded_u009c() {
    // U+009C encoded in UTF-8 is C2 9C.
    let encoded_c1_st = "\u{009C}".as_bytes();
    assert_eq!(encoded_c1_st, &[0xC2, 0x9C]);

    // OSC with encoded U+009C in payload, terminated with BEL
    {
        let mut parser = Parser::new();
        let mut p = MockPerformer {
            actions: Vec::new(),
        };
        for &b in b"\x1B]0;pre\xC2\x9Cpost\x07" {
            parser.advance(&mut p, b);
        }
        assert_eq!(parser.state, State::Ground);
        assert_eq!(
            p.actions,
            vec![Action::OscDispatch(
                vec![b"0".to_vec(), b"pre\xC2\x9Cpost".to_vec()],
                true
            )]
        );
    }

    // OSC with encoded U+009C in payload, terminated with ESC \
    {
        let mut parser = Parser::new();
        let mut p = MockPerformer {
            actions: Vec::new(),
        };
        for &b in b"\x1B]0;pre\xC2\x9Cpost\x1B\\" {
            parser.advance(&mut p, b);
        }
        assert_eq!(parser.state, State::Ground);
        assert_eq!(
            p.actions,
            vec![
                Action::OscDispatch(vec![b"0".to_vec(), b"pre\xC2\x9Cpost".to_vec()], false),
                Action::EscDispatch(vec![], false, b'\\'),
            ]
        );
    }

    // OSC with encoded U+009C in payload, terminated with bare C1 ST 0x9C
    {
        let mut parser = Parser::new();
        let mut p = MockPerformer {
            actions: Vec::new(),
        };
        for &b in b"\x1B]0;pre\xC2\x9Cpost\x9C" {
            parser.advance(&mut p, b);
        }
        assert_eq!(parser.state, State::Ground);
        assert_eq!(
            p.actions,
            vec![Action::OscDispatch(
                vec![b"0".to_vec(), b"pre\xC2\x9Cpost".to_vec()],
                false
            )]
        );
    }

    // APC with encoded U+009C in payload, terminated with bare C1 ST 0x9C
    {
        let mut parser = Parser::new();
        let mut p = MockPerformer {
            actions: Vec::new(),
        };
        for &b in b"\x1B_Gpre\xC2\x9Cpost\x9C" {
            parser.advance(&mut p, b);
        }
        assert_eq!(parser.state, State::Ground);
        assert_eq!(
            p.actions,
            vec![Action::ApcDispatch(b"Gpre\xC2\x9Cpost".to_vec())]
        );
    }
}
