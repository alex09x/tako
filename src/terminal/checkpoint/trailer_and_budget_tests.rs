/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

//! A session's OSC 7501 records survive a checkpoint round trip in every
//! state; a forged trailer whose header lies is refused; what a session
//! holds -- pending events, links -- is counted in its retained cost; and a
//! refusal says what was wrong.

use super::program_status_tests::{craft_v7_with_ps75, valid_record};
use super::types::CheckpointError;
use super::{export, import, retained_cost};
use crate::terminal::{ProgramStatusBlockedKind as Kind, ProgramStatusState as State, Terminal};

#[test]
fn every_status_record_survives_a_checkpoint_round_trip() {
    let mut term = Terminal::new(80, 24);
    for fields in [
        "state=idle:id=i",
        "state=working:id=w:app=codex:progress=30",
        "state=done:id=d",
        "state=error:id=e",
        "state=blocked:id=p:kind=permission:progress=90",
        "state=blocked:id=q:kind=question",
        "state=blocked:id=a:kind=auth",
    ] {
        term.feed(format!("\x1b]7501;{fields}\x07").as_bytes());
    }
    let before = term.program_status_snapshot();
    let back = import(&export(&term).expect("export"))
        .expect("import")
        .program_status_snapshot();
    assert_eq!(back.revision, before.revision);
    assert!(back.osc7501_active);
    let shape = |s: &crate::terminal::ProgramStatusSnapshot| {
        let mut v: Vec<_> = s
            .records
            .iter()
            .map(|r| (r.id.clone(), r.state, r.kind, r.progress, r.app.clone()))
            .collect();
        v.sort_by(|x, y| x.0.cmp(&y.0));
        v
    };
    assert_eq!(shape(&back), shape(&before));
    assert!(shape(&back).contains(&("a".into(), State::Blocked, Some(Kind::Auth), None, None)));
    assert!(shape(&back).contains(&(
        "w".into(),
        State::Working,
        None,
        Some(30),
        Some("codex".into())
    )));
}

#[test]
fn a_session_that_never_used_osc_7501_writes_no_trailer() {
    let mut term = Terminal::new(80, 24);
    term.feed(b"plain output");
    let back = import(&export(&term).unwrap())
        .unwrap()
        .program_status_snapshot();
    assert!(!back.osc7501_active && back.records.is_empty());
}

fn refused(blob: Vec<u8>, why: &str) {
    assert!(
        matches!(import(&blob), Err(CheckpointError::InvalidData(_))),
        "{why}"
    );
}

#[test]
fn a_forged_trailer_header_that_lies_is_refused() {
    refused(
        craft_v7_with_ps75(true, 0, 1, &[]),
        "an active table at revision 0",
    );
    // More records than the revision or the clock could have made.
    let mut a = valid_record();
    a.id = "a";
    let mut b = valid_record();
    b.id = "b";
    (b.revision, b.lru_tick) = (2, 2);
    refused(
        craft_v7_with_ps75(true, 1, 5, &[a.clone(), b.clone()]),
        "two records at revision 1",
    );
    refused(
        craft_v7_with_ps75(true, 5, 1, &[a, b]),
        "two records at lru clock 1",
    );
    // A state or kind byte outside the protocol.
    let mut state = valid_record();
    state.state = 9;
    refused(craft_v7_with_ps75(true, 1, 1, &[state]), "state 9");
    let mut kind = valid_record();
    (kind.state, kind.kind, kind.progress) = (3, 7, None);
    refused(craft_v7_with_ps75(true, 1, 1, &[kind]), "kind 7");
    let mut pct = valid_record();
    pct.progress = Some(101);
    refused(craft_v7_with_ps75(true, 1, 1, &[pct]), "101 percent");
}

#[test]
fn every_state_and_kind_byte_of_a_forged_trailer_reads_back() {
    // (state byte, kind byte, progress) for each state the wire can carry.
    for (state_byte, kind_byte, progress, want) in [
        (0, 0, None, (State::Idle, None)),
        (2, 0, None, (State::Done, None)),
        (4, 0, None, (State::Error, None)),
        (3, 1, Some(5), (State::Blocked, Some(Kind::Permission))),
        (3, 2, None, (State::Blocked, Some(Kind::Question))),
        (3, 3, None, (State::Blocked, Some(Kind::Auth))),
    ] {
        let mut rec = valid_record();
        (rec.state, rec.kind, rec.progress, rec.app) = (state_byte, kind_byte, progress, None);
        let snap = import(&craft_v7_with_ps75(true, 1, 1, &[rec]))
            .expect("a valid record")
            .program_status_snapshot();
        let r = &snap.records[0];
        assert_eq!(((r.state, r.kind), r.app.clone()), (want, None));
    }
}

#[test]
fn pending_events_and_links_count_in_the_retained_cost() {
    let mut term = Terminal::new(80, 24);
    let base = retained_cost(&term);
    let long = "x".repeat(4000);
    term.feed(format!("\x1b]8;;https://example.com/{long}\x07link\x1b]8;;\x07").as_bytes());
    let with_link = retained_cost(&term);
    assert!(
        with_link >= base + 4000,
        "a link's url is held: {base} -> {with_link}"
    );

    term.feed(format!("\x1b]0;{long}\x07").as_bytes()); // a title event
    term.feed(format!("\x1b]9;{long}\x07").as_bytes()); // a notification
    term.feed(format!("\x1b]9;5;working;{long}\x07").as_bytes()); // a status
    term.feed(format!("\x1b]99;i=n1:a=focus;{long}\x1b\\").as_bytes()); // a structured notification
    term.feed(b"\x1b]99;i=n1:p=close;\x1b\\");
    term.feed(b"\x1b]3008;push;container;web;#3b82f6\x07");
    term.feed(b"\x1b]7501;state=working:id=job\x07");
    term.feed(b"\x07\x1b]133;A\x07");
    let with_events = retained_cost(&term);
    assert!(
        with_events >= with_link + 4 * 1000,
        "pending events hold their text: {with_link} -> {with_events}"
    );
    let _ = term.take_events();
}

#[test]
fn a_refusal_says_what_was_wrong() {
    let say = |e: CheckpointError| e.to_string();
    assert!(say(CheckpointError::UnexpectedEof).contains("end of checkpoint"));
    assert!(say(CheckpointError::InvalidMagic).contains("TKCK"));
    assert!(say(CheckpointError::UnsupportedVersion(99)).contains("99"));
    assert!(
        say(CheckpointError::ChecksumMismatch {
            expected: 0xab,
            actual: 0xcd
        })
        .contains("0xab")
    );
    assert!(
        say(CheckpointError::InvalidPayloadLength {
            declared: 10,
            actual: 3
        })
        .contains("declared 10")
    );
    assert!(say(CheckpointError::InvalidData("bad record")).contains("bad record"));
    assert!(say(CheckpointError::DimensionOutOfBounds { cols: 0, rows: 5 }).contains("0x5"));
    assert!(say(CheckpointError::AllocationLimitExceeded).contains("import limit"));
    assert!(say(CheckpointError::TooLarge { size: 9, limit: 8 }).contains("9 bytes"));
}
