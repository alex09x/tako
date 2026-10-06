/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::helpers::b64;
use crate::graphics::*;

#[test]
fn parses_key_value_pairs_and_keeps_unknown_keys() {
    let cmd = parse_control_data("a=T,f=32,s=1,v=1,i=7,z=99,X=hello");
    assert_eq!(cmd.get_char('a'), Some('T'));
    assert_eq!(cmd.get_u32('s'), Some(1));
    assert_eq!(cmd.get_u32('i'), Some(7));
    assert_eq!(cmd.get('z'), Some("99"));
    assert_eq!(cmd.get('X'), Some("hello"));
    assert_eq!(cmd.get('q'), None);
    assert_eq!(cmd.len(), 7);
}

#[test]
fn parses_empty_and_malformed_fragments_without_panicking() {
    let cmd = parse_control_data("");
    assert!(cmd.is_empty());

    let cmd = parse_control_data("a=T,,garbage,=5,ab=3,f=32");
    assert_eq!(cmd.get_char('a'), Some('T'));
    assert_eq!(cmd.get('f'), Some("32"));
    assert_eq!(cmd.len(), 2);
}

#[test]
fn missing_or_unknown_action_errors() {
    let mut state = GraphicsState::new();
    // Since action 'a' defaults to 't' (transmit), omitting 'a' when 't' medium is also omitted
    // returns Unsupported (transmission without medium is unsupported).
    assert_eq!(
        state.handle("f=32,s=1,v=1", b""),
        GraphicsResponse::Unsupported
    );
    // Unknown action returns Error.
    assert!(matches!(
        state.handle("a=z", b""),
        GraphicsResponse::Error(_)
    ));
    // Multi-character action values are not valid either.
    assert!(matches!(
        state.handle("a=TT", b""),
        GraphicsResponse::Error(_)
    ));
}

#[test]
fn missing_action_defaults_to_transmit() {
    let mut state = GraphicsState::new();
    let pixel = [0x55_u8, 0x66, 0x77, 0x88];
    // Without 'a', action defaults to 't' (transmit).
    let resp = state.handle("t=d,f=32,s=1,v=1,i=99", b64(&pixel).as_bytes());
    assert_eq!(resp, GraphicsResponse::Stored { image_id: 99 });
    assert_eq!(state.image(99).unwrap().pixels, pixel.to_vec());
}

#[test]
fn query_graphics_protocol_replies_ok_and_reflects_keys() {
    let mut state = GraphicsState::new();
    let resp = state.handle("a=q,t=d,i=1,s=100,v=50", b"");
    assert_eq!(
        resp,
        GraphicsResponse::Query {
            reply: "\x1b_Gi=1,s=100,v=50;OK\x1b\\".to_string()
        }
    );
    assert_eq!(
        state.take_last_reply(),
        Some("\x1b_Gi=1,s=100,v=50;OK\x1b\\".to_string())
    );

    // Query with unsupported medium returns ENOTSUP
    let resp = state.handle("a=q,t=f,i=2", b"");
    assert_eq!(
        resp,
        GraphicsResponse::Query {
            reply: "\x1b_Gi=2;ENOTSUP\x1b\\".to_string()
        }
    );
}

#[test]
fn response_control_q2_generates_replies_for_displayed_and_deleted() {
    let mut state = GraphicsState::new();
    let pixel = [1_u8, 2, 3, 4];
    state.handle("a=T,t=d,f=32,s=1,v=1,i=5,q=2", b64(&pixel).as_bytes());
    assert_eq!(
        state.take_last_reply(),
        Some("\x1b_Gi=5,p=0;OK\x1b\\".to_string())
    );

    state.handle("a=d,d=i,i=5,q=2", b"");
    assert_eq!(state.take_last_reply(), Some("\x1b_G;OK\x1b\\".to_string()));
}

#[test]
fn default_matches_new() {
    let state = GraphicsState::default();
    assert!(state.placements().is_empty());
    assert!(state.image(1).is_none());
}
