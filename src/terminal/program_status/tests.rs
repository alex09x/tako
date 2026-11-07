/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use base64::Engine as _;
use base64::engine::general_purpose::{STANDARD, STANDARD_NO_PAD};

use crate::response::TerminalReplyClass;
use crate::terminal::{
    ProgramStatusBlockedKind, ProgramStatusMutation, ProgramStatusRemovalReason,
    ProgramStatusState, Terminal, TerminalEvent,
};

use super::{CAPABILITY_REPLY, MAX_PENDING_STATUS_UPDATES, MAX_RECORDS};

fn b64(s: &str) -> String {
    STANDARD.encode(s.as_bytes())
}

#[test]
fn capability_probe_and_da1_preserve_fifo_order_and_selective_policy() {
    let mut term = Terminal::new(80, 24);
    term.feed(b"\x1b]7501;?\x1b\\\x1b[c");

    let drain = term.drain_classified_replies(16);
    assert_eq!(drain.replies.len(), 2);
    assert_eq!(drain.overflow_dropped_count, 0);
    assert!(!drain.has_more);
    assert_eq!(
        drain.replies[0].class,
        TerminalReplyClass::ProgramStatusCapability
    );
    assert_eq!(drain.replies[0].bytes, CAPABILITY_REPLY.as_bytes());
    assert_eq!(drain.replies[1].class, TerminalReplyClass::StandardDevice);
    assert_eq!(drain.replies[1].bytes, b"\x1b[?62;22c");
    assert!(term.take_output().is_empty());

    // Passive client mode suppresses 7501 probe reply ONLY, keeping DA1 and status parsing.
    term.set_program_status_probe_reply_enabled(false);
    assert!(!term.is_program_status_probe_reply_enabled());
    let msg = b64("Running checks");
    let seq = format!("\x1b]7501;?\x1b\\\x1b[c\x1b]7501;state=working:app=codex:msg={msg}\x07");
    term.feed(seq.as_bytes());

    let passive_drain = term.drain_classified_replies(16);
    assert_eq!(passive_drain.replies.len(), 1);
    assert_eq!(
        passive_drain.replies[0].class,
        TerminalReplyClass::StandardDevice
    );
    assert_eq!(passive_drain.replies[0].bytes, b"\x1b[?62;22c");

    let snap = term.program_status_snapshot();
    assert!(snap.osc7501_active);
    let eff = snap.effective.expect("working status should still parse");
    assert_eq!(eff.state, ProgramStatusState::Working);
    assert_eq!(eff.app.as_deref(), Some("codex"));
    assert_eq!(eff.msg.as_deref(), Some("Running checks"));
}

#[test]
fn byte_by_byte_chunk_splitting_and_unpadded_base64_work() {
    let mut term = Terminal::new(80, 24);
    let title = STANDARD_NO_PAD.encode("Сборка crate 🚀".as_bytes());
    let msg = STANDARD_NO_PAD.encode("Тестирование модуля".as_bytes());
    let wire = format!(
        "\x1b]7501;state=working:id=build/rust:app=mitts:progress=42:title={title}:msg={msg}\x1b\\"
    );
    for &byte in wire.as_bytes() {
        term.feed(&[byte]);
    }
    let snap = term.program_status_snapshot();
    assert_eq!(snap.records.len(), 1);
    let rec = &snap.records[0];
    assert_eq!(rec.id, "build/rust");
    assert_eq!(rec.state, ProgramStatusState::Working);
    assert_eq!(rec.progress, Some(42));
    assert_eq!(rec.app.as_deref(), Some("mitts"));
    assert_eq!(rec.resolved_app.as_deref(), Some("mitts"));
    assert_eq!(rec.title.as_deref(), Some("Сборка crate 🚀"));
    assert_eq!(rec.msg.as_deref(), Some("Тестирование модуля"));
}

#[test]
fn sequence_and_field_limits_are_enforced_all_or_nothing() {
    let mut term = Terminal::new(80, 24);
    term.feed(b"\x1b]7501;state=working:app=seed\x07");
    let baseline = term.program_status_snapshot();
    assert_eq!(baseline.revision, 1);

    // Exact 4096-byte sequence with BEL (1B) succeeds; 4097 bytes with ESC \ (2B) is rejected.
    // Prefix `\x1b]7501;state=done:u=` is 20 bytes; + 4075 'a' + 1 BEL = 4096.
    let filler = "a".repeat(4075);
    let exact_4096_bel = format!("\x1b]7501;state=done:u={filler}\x07");
    assert_eq!(exact_4096_bel.len(), 4096);
    term.feed(exact_4096_bel.as_bytes());
    assert_eq!(term.program_status_snapshot().revision, 2);
    assert_eq!(
        term.program_status_snapshot().effective.unwrap().state,
        ProgramStatusState::Done
    );

    let over_4097_st = format!("\x1b]7501;state=done:u={filler}\x1b\\");
    assert_eq!(over_4097_st.len(), 4097);
    term.feed(over_4097_st.as_bytes());
    assert_eq!(term.program_status_snapshot().revision, 2);

    // Key > 16 bytes rejected whole.
    term.feed(b"\x1b]7501;state=error:seventeenbytekeyx=1\x07");
    assert_eq!(term.program_status_snapshot().revision, 2);

    // app > 32 bytes rejected whole; invalid app charset treated as absent without rejecting.
    let app33 = "a".repeat(33);
    term.feed(format!("\x1b]7501;state=error:app={app33}\x07").as_bytes());
    assert_eq!(term.program_status_snapshot().revision, 2);
    term.feed(b"\x1b]7501;state=working:app=bad!chars\x07");
    assert_eq!(term.program_status_snapshot().revision, 3);
    assert_eq!(term.program_status_snapshot().effective.unwrap().app, None);

    // Malformed id rejected whole (must NOT overwrite root record).
    for bad_id in [
        "/leading",
        "trailing/",
        "double//slash",
        "a/b/c/d/e/f/g/h/i",
        &"x".repeat(33),
        &format!(
            "{}/{}/{}/{}/{}",
            "a".repeat(30),
            "b".repeat(30),
            "c".repeat(30),
            "d".repeat(30),
            "e".repeat(10)
        ),
    ] {
        term.feed(format!("\x1b]7501;state=error:id={bad_id}\x07").as_bytes());
    }
    assert_eq!(term.program_status_snapshot().revision, 3);

    // Title > 192 decoded bytes rejected; msg > 2048 decoded bytes rejected.
    let long_title = b64(&"t".repeat(193));
    term.feed(format!("\x1b]7501;state=error:title={long_title}\x07").as_bytes());
    let long_msg = b64(&"m".repeat(2049));
    term.feed(format!("\x1b]7501;state=error:msg={long_msg}\x07").as_bytes());
    assert_eq!(term.program_status_snapshot().revision, 3);
}

#[test]
fn hardening_rejects_controls_and_invalid_utf8_and_disarms_bidi() {
    let mut term = Terminal::new(80, 24);
    term.feed(b"\x1b]7501;state=working:app=claude\x07");
    let rev = term.program_status_snapshot().revision;

    // Invalid base64, invalid UTF-8, NUL, newline, ESC, DEL, C1 control (U+0085) all rejected.
    let bad_utf8 = STANDARD.encode([0xFF, 0xFE]);
    let c0_nl = b64("line1\nline2");
    let c0_esc = b64("bad\x1btitle");
    let del = b64("bad\x7ftext");
    let c1 = b64("bad\u{0085}next");
    for payload in ["%%%notb64%%%", &bad_utf8, &c0_nl, &c0_esc, &del, &c1] {
        term.feed(format!("\x1b]7501;state=error:msg={payload}\x07").as_bytes());
    }
    assert_eq!(term.program_status_snapshot().revision, rev);

    // Bidi overrides (RLO U+202E, PDF U+202C, RLI U+2067, PDI U+2069) are stripped.
    let spoofed = b64("safe \u{202E}txt.exe\u{202C} \u{2067}isolated\u{2069}");
    term.feed(format!("\x1b]7501;state=blocked:kind=permission:msg={spoofed}\x07").as_bytes());
    let eff = term.program_status_snapshot().effective.unwrap();
    assert_eq!(eff.state, ProgramStatusState::Blocked);
    assert_eq!(eff.kind, Some(ProgramStatusBlockedKind::Permission));
    assert_eq!(eff.msg.as_deref(), Some("safe txt.exe isolated"));

    // Malformed pair without `=`, uppercase key, unknown key ignored; last repeated key wins.
    term.feed(b"\x1b]7501;garbage:UPPER=1:future=ok_val:state=idle:state=done:progress=50\x07");
    let eff2 = term.program_status_snapshot().effective.unwrap();
    assert_eq!(eff2.state, ProgramStatusState::Done);
    assert_eq!(eff2.progress, None); // progress ignored on `done`
}

#[test]
fn hierarchy_priority_app_inheritance_subtree_clear_and_dedupe() {
    let mut term = Terminal::new(80, 24);
    term.feed(b"\x1b]7501;state=working:app=claude-code\x07");
    let _ = term.take_events();
    let _ = term.drain_program_status_updates(16);

    // Identical repeat does not bump revision or emit events.
    term.feed(b"\x1b]7501;state=working:app=claude-code\x07");
    assert!(term.take_events().is_empty());
    assert_eq!(term.program_status_snapshot().revision, 1);

    // Child `done` inherits `resolved_app = claude-code` and MUST NOT override root `working`.
    term.feed(b"\x1b]7501;id=agent/sub1:state=done\x07");
    let snap = term.program_status_snapshot();
    assert_eq!(snap.effective.as_ref().unwrap().id, "");
    assert_eq!(
        snap.effective.as_ref().unwrap().state,
        ProgramStatusState::Working
    );
    let sub1 = snap.records.iter().find(|r| r.id == "agent/sub1").unwrap();
    assert_eq!(sub1.app, None);
    assert_eq!(sub1.resolved_app.as_deref(), Some("claude-code"));

    // Blocked ranks: permission > auth > question > working.
    term.feed(b"\x1b]7501;id=agent/q:state=blocked:kind=question\x07");
    assert_eq!(
        term.program_status_snapshot().effective.unwrap().id,
        "agent/q"
    );
    term.feed(b"\x1b]7501;id=agent/a:state=blocked:kind=auth\x07");
    assert_eq!(
        term.program_status_snapshot().effective.unwrap().id,
        "agent/a"
    );
    term.feed(b"\x1b]7501;id=agent/p:state=blocked:kind=permission\x07");
    assert_eq!(
        term.program_status_snapshot().effective.unwrap().id,
        "agent/p"
    );

    // Sibling prefix `agent2` is NOT cleared when clearing subtree `agent`.
    term.feed(b"\x1b]7501;id=agent2:state=error:app=other\x07");
    term.feed(b"\x1b]7501;id=agent:state=clear\x07");
    let after_clear = term.program_status_snapshot();
    let ids: Vec<&str> = after_clear.records.iter().map(|r| r.id.as_str()).collect();
    assert_eq!(ids, vec!["", "agent2"]);
    assert_eq!(after_clear.effective.unwrap().id, ""); // working > error
}

#[test]
fn lru_eviction_caps_records_at_256_and_refreshes_on_duplicate() {
    let mut term = Terminal::new(80, 24);
    for i in 0..MAX_RECORDS {
        term.feed(format!("\x1b]7501;id=t{i}:state=idle\x07").as_bytes());
    }
    // Touch t0 with an identical report so t1 becomes the oldest LRU entry.
    term.feed(b"\x1b]7501;id=t0:state=idle\x07");
    let _ = term.take_events();

    term.feed(b"\x1b]7501;id=overflow:state=working\x07");
    let snap = term.program_status_snapshot();
    assert_eq!(snap.records.len(), MAX_RECORDS);
    assert!(snap.records.iter().any(|r| r.id == "t0"));
    assert!(!snap.records.iter().any(|r| r.id == "t1"));
    assert!(snap.records.iter().any(|r| r.id == "overflow"));

    let events = term.take_events();
    let Some(TerminalEvent::ProgramStatusChanged(upd)) = events.last() else {
        panic!("expected ProgramStatusChanged");
    };
    assert!(matches!(
        &upd.mutations[0],
        ProgramStatusMutation::Removed {
            id,
            reason: ProgramStatusRemovalReason::Evicted,
            ..
        } if id == "t1"
    ));
}

#[test]
fn lifetimes_alt_screen_decstr_ris_prompt_exit_interrupt_ack_and_osc94() {
    let mut term = Terminal::new(80, 24);
    term.feed(b"\x1b]7501;id=w:state=working\x07");
    term.feed(b"\x1b]7501;id=b:state=blocked:kind=question\x07");
    term.feed(b"\x1b]7501;id=i:state=idle\x07");
    term.feed(b"\x1b]7501;id=d:state=done\x07");
    term.feed(b"\x1b]7501;id=e:state=error\x07");

    // Alt-screen (?1049h / ?1049l) and soft reset DECSTR (CSI ! p) preserve all records.
    term.feed(b"\x1b[?1049h\x1b[!p\x1b[?1049l");
    assert_eq!(term.program_status_snapshot().records.len(), 5);

    // Generic OSC 9;4 still emits TerminalEvent::Progress without clobbering 7501 records.
    let _ = term.take_events();
    term.feed(b"\x1b]9;4;1;75\x07");
    let progress_events = term.take_events();
    assert!(progress_events.iter().any(|e| matches!(
        e,
        TerminalEvent::Progress {
            state: 1,
            value: Some(75)
        }
    )));
    assert_eq!(term.program_status_snapshot().records.len(), 5);

    // Interrupt drops working + blocked, keeping idle + done + error.
    let interrupted = term
        .program_status_interrupted()
        .expect("interrupted update");
    assert_eq!(interrupted.mutations.len(), 2);
    assert_eq!(term.program_status_snapshot().records.len(), 3);

    // Prompt return (OSC 133;A) drops remaining idle/working/blocked, keeping done + error.
    term.feed(b"\x1b]7501;id=w2:state=working\x07");
    term.feed(b"\x1b]133;A\x07");
    let after_prompt: Vec<String> = term
        .program_status_snapshot()
        .records
        .into_iter()
        .map(|r| r.id)
        .collect();
    assert_eq!(after_prompt, vec!["d", "e"]);

    // Process exit also drops working/blocked/idle while preserving done + error.
    term.feed(b"\x1b]7501;id=w3:state=working\x07");
    let exited = term.program_status_process_exited().expect("exit update");
    assert_eq!(exited.mutations.len(), 1);
    assert_eq!(term.program_status_snapshot().records.len(), 2);

    // Acknowledge drops done + error.
    let ack = term.program_status_acknowledged().expect("ack update");
    assert_eq!(ack.mutations.len(), 2);
    assert!(term.program_status_snapshot().records.is_empty());

    // RIS (ESC c) clears everything and resets osc7501_active.
    term.feed(b"\x1b]7501;state=done\x07");
    assert!(term.program_status_snapshot().osc7501_active);
    term.feed(b"\x1bc");
    let after_ris = term.program_status_snapshot();
    assert!(!after_ris.osc7501_active);
    assert!(after_ris.records.is_empty());
}

#[test]
fn bounded_drain_paginates_without_new_bytes_and_coalesces_overflow() {
    let mut term = Terminal::new(80, 24);
    for i in 0..10 {
        term.feed(format!("\x1b]7501;id=j{i}:state=working\x07").as_bytes());
    }
    // Host drains with max_updates = 4 with zero further PTY bytes.
    let b1 = term.drain_program_status_updates(4);
    assert_eq!(b1.updates.len(), 4);
    assert!(b1.has_more);
    assert!(!b1.overflow_coalesced);
    let b2 = term.drain_program_status_updates(4);
    assert_eq!(b2.updates.len(), 4);
    assert!(b2.has_more);
    let b3 = term.drain_program_status_updates(4);
    assert_eq!(b3.updates.len(), 2);
    assert!(!b3.has_more);

    // Single feed burst exceeding MAX_PENDING_STATUS_UPDATES followed by total silence.
    let mut burst = Vec::new();
    for i in 0..(MAX_PENDING_STATUS_UPDATES + 25) {
        burst.extend_from_slice(format!("\x1b]7501;id=s{i}:state=done\x07").as_bytes());
    }
    term.feed(&burst);
    let over = term.drain_program_status_updates(16);
    assert!(over.overflow_coalesced);
    assert_eq!(over.overflow_from_revision, 11);
    assert!(!over.has_more);
    let resync = over.resync_snapshot.expect("coalesced resync snapshot");
    assert_eq!(resync.revision, over.snapshot_revision);
    assert_eq!(resync.records.len(), 10 + MAX_PENDING_STATUS_UPDATES + 25);
}
