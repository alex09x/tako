/*
 * tako — Malformed PS75 trailer & reset invariants tests
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::crc::crc32;
use super::program_status::PS75_MAGIC;
use super::types::{CheckpointError, HEADER_SIZE};
use super::writer::Writer;
use super::{export, import};
use crate::ffi::TakoCore;
use crate::terminal::events::TerminalEvent;
use crate::terminal::{
    ProgramStatusMutation, ProgramStatusRemovalReason, ProgramStatusState, Terminal,
};

#[derive(Clone)]
struct RawPsRecord<'a> {
    id: &'a str,
    state: u8,
    kind: u8,
    progress: Option<u8>,
    app: Option<&'a str>,
    title: Option<&'a str>,
    msg: Option<&'a str>,
    revision: u64,
    lru_tick: u64,
}

fn write_opt_str(w: &mut Writer, opt: Option<&str>) {
    if let Some(s) = opt {
        w.write_bool(true);
        w.write_string(s);
    } else {
        w.write_bool(false);
    }
}

/// Appends a custom `PS75` trailer onto a clean v7 checkpoint without `OSC 7501`
/// state and recomputes `payload_len` and `CRC32`.
fn craft_v7_with_ps75(
    osc7501_active: bool,
    revision: u64,
    lru_clock: u64,
    records: &[RawPsRecord<'_>],
) -> Vec<u8> {
    let mut base = Terminal::new(80, 24);
    base.feed(b"hello world");
    let mut container = export(&base).expect("clean v7 checkpoint export");

    let mut trailer = Writer::with_capacity(256, usize::MAX);
    trailer.push(&PS75_MAGIC);
    trailer.write_bool(osc7501_active);
    trailer.write_u64(revision);
    trailer.write_u64(lru_clock);
    trailer.write_u32(records.len() as u32);
    for rec in records {
        trailer.write_string(rec.id);
        trailer.write_u8(rec.state);
        trailer.write_u8(rec.kind);
        if let Some(pct) = rec.progress {
            trailer.write_bool(true);
            trailer.write_u8(pct);
        } else {
            trailer.write_bool(false);
        }
        write_opt_str(&mut trailer, rec.app);
        write_opt_str(&mut trailer, rec.title);
        write_opt_str(&mut trailer, rec.msg);
        trailer.write_u64(rec.revision);
        trailer.write_u64(rec.lru_tick);
    }

    container.extend_from_slice(&trailer.buf);
    let payload_len = (container.len() - HEADER_SIZE) as u32;
    let checksum = crc32(&container[HEADER_SIZE..]);
    container[12..16].copy_from_slice(&payload_len.to_le_bytes());
    container[16..20].copy_from_slice(&checksum.to_le_bytes());
    container
}

fn valid_record() -> RawPsRecord<'static> {
    RawPsRecord {
        id: "main/sub-1",
        state: 1, // Working
        kind: 0,
        progress: Some(45),
        app: Some("Codex"),
        title: Some("Running checks"),
        msg: Some("Step 1 of 2"),
        revision: 1,
        lru_tick: 1,
    }
}

#[test]
fn forged_ps75_accepts_valid_trailer_and_rejects_control_or_bidi_text_atomically() {
    let good = craft_v7_with_ps75(true, 1, 1, &[valid_record()]);
    let imported = import(&good).expect("valid PS75 trailer must import cleanly");
    let snap = imported.program_status_snapshot();
    assert!(snap.osc7501_active);
    assert_eq!(snap.revision, 1);
    assert_eq!(
        snap.effective.as_ref().unwrap().state,
        ProgramStatusState::Working
    );
    assert_eq!(
        snap.effective.as_ref().unwrap().msg.as_deref(),
        Some("Step 1 of 2")
    );

    // Control characters in msg/title must be rejected.
    let mut ctrl_msg = valid_record();
    ctrl_msg.msg = Some("bad\x07bell");
    assert!(matches!(
        import(&craft_v7_with_ps75(true, 1, 1, &[ctrl_msg])),
        Err(CheckpointError::InvalidData(_))
    ));

    let mut c1_title = valid_record();
    c1_title.title = Some("c1\u{009B}escape");
    assert!(matches!(
        import(&craft_v7_with_ps75(true, 1, 1, &[c1_title])),
        Err(CheckpointError::InvalidData(_))
    ));

    // Disarmed bidi/formatting chars must never survive into public snapshot via forged PS75.
    let mut bidi_msg = valid_record();
    bidi_msg.msg = Some("spoof\u{202E}txt");
    assert!(matches!(
        import(&craft_v7_with_ps75(true, 1, 1, &[bidi_msg])),
        Err(CheckpointError::InvalidData(_))
    ));

    // Empty Some("") text must also be rejected (canonical wire representation is None).
    let mut empty_title = valid_record();
    empty_title.title = Some("");
    assert!(matches!(
        import(&craft_v7_with_ps75(true, 1, 1, &[empty_title])),
        Err(CheckpointError::InvalidData(_))
    ));

    // Verify atomic non-mutation on live TakoCore when import fails.
    let core = TakoCore::new(80, 24);
    core.feed(b"\x1b]7501;state=done:id=keep:app=Claude\x1b\\".to_vec());
    let epoch_before = core.state_epoch();
    let mut bad = valid_record();
    bad.msg = Some("inject\x1b]52;c;YWJj\x07");
    let forged_blob = craft_v7_with_ps75(true, 5, 5, &[bad]);
    assert!(core.checkpoint_import(forged_blob).is_err());
    assert_eq!(core.state_epoch(), epoch_before);
    let preserved = core.program_status_snapshot();
    assert_eq!(preserved.records.len(), 1);
    assert_eq!(preserved.records[0].id, "keep");
}

#[test]
fn forged_ps75_rejects_oversized_malformed_duplicate_and_inconsistent_revisions() {
    // 1. Oversized id (> 128 bytes)
    let long_id = format!("{}/{}", "a".repeat(64), "b".repeat(64)); // 129 bytes
    let mut r_long_id = valid_record();
    r_long_id.id = &long_id;
    assert!(matches!(
        import(&craft_v7_with_ps75(true, 1, 1, &[r_long_id])),
        Err(CheckpointError::InvalidData(_))
    ));

    // 2. Malformed id syntax (empty segment / forbidden chars / depth > 8)
    for bad_id in [
        "bad//seg",
        "/leading",
        "trailing/",
        "bad space",
        "a/b/c/d/e/f/g/h/i",
    ] {
        let mut r = valid_record();
        r.id = bad_id;
        assert!(
            matches!(
                import(&craft_v7_with_ps75(true, 1, 1, &[r])),
                Err(CheckpointError::InvalidData(_))
            ),
            "expected rejection for malformed id: {bad_id}"
        );
    }

    // 3. Oversized or invalid app (> 32 bytes or invalid chars or empty Some(""))
    let long_app = "A".repeat(33);
    for bad_app in [long_app.as_str(), "", "Bad App!"] {
        let mut r = valid_record();
        r.app = Some(bad_app);
        assert!(
            matches!(
                import(&craft_v7_with_ps75(true, 1, 1, &[r])),
                Err(CheckpointError::InvalidData(_))
            ),
            "expected rejection for invalid app: {bad_app}"
        );
    }

    // 4. Oversized title (> 192 bytes) and oversized msg (> 2048 bytes)
    let long_title = "T".repeat(193);
    let mut r_title = valid_record();
    r_title.title = Some(&long_title);
    assert!(matches!(
        import(&craft_v7_with_ps75(true, 1, 1, &[r_title])),
        Err(CheckpointError::InvalidData(_))
    ));

    let long_msg = "M".repeat(2049);
    let mut r_msg = valid_record();
    r_msg.msg = Some(&long_msg);
    assert!(matches!(
        import(&craft_v7_with_ps75(true, 1, 1, &[r_msg])),
        Err(CheckpointError::InvalidData(_))
    ));

    // 5. Duplicate ids
    let mut dup_a = valid_record();
    dup_a.revision = 1;
    dup_a.lru_tick = 1;
    let mut dup_b = valid_record();
    dup_b.revision = 2;
    dup_b.lru_tick = 2;
    assert!(matches!(
        import(&craft_v7_with_ps75(true, 2, 2, &[dup_a, dup_b])),
        Err(CheckpointError::InvalidData(_))
    ));

    // 6. Cross-field state/kind/progress violations
    let mut kind_on_working = valid_record();
    kind_on_working.state = 1; // Working
    kind_on_working.kind = 1; // Permission (only valid on Blocked)
    assert!(matches!(
        import(&craft_v7_with_ps75(true, 1, 1, &[kind_on_working])),
        Err(CheckpointError::InvalidData(_))
    ));

    let mut progress_on_done = valid_record();
    progress_on_done.state = 2; // Done
    progress_on_done.progress = Some(50);
    assert!(matches!(
        import(&craft_v7_with_ps75(true, 1, 1, &[progress_on_done])),
        Err(CheckpointError::InvalidData(_))
    ));

    // 7. Inconsistent record/table revisions & lru_tick
    let mut zero_rev = valid_record();
    zero_rev.revision = 0;
    assert!(matches!(
        import(&craft_v7_with_ps75(true, 1, 1, &[zero_rev])),
        Err(CheckpointError::InvalidData(_))
    ));

    let mut rev_gt_table = valid_record();
    rev_gt_table.revision = 5;
    assert!(matches!(
        import(&craft_v7_with_ps75(true, 3, 3, &[rev_gt_table])),
        Err(CheckpointError::InvalidData(_))
    ));

    let mut r1 = valid_record();
    r1.id = "one";
    r1.revision = 2;
    r1.lru_tick = 1;
    let mut r2 = valid_record();
    r2.id = "two";
    r2.revision = 2; // duplicate record revision!
    r2.lru_tick = 2;
    assert!(matches!(
        import(&craft_v7_with_ps75(true, 2, 2, &[r1, r2])),
        Err(CheckpointError::InvalidData(_))
    ));

    let mut bad_lru = valid_record();
    bad_lru.lru_tick = 9;
    assert!(matches!(
        import(&craft_v7_with_ps75(true, 2, 3, &[bad_lru])),
        Err(CheckpointError::InvalidData(_))
    ));

    // 8. Inactive osc7501_active in PS75 trailer
    assert!(matches!(
        import(&craft_v7_with_ps75(false, 1, 1, &[valid_record()])),
        Err(CheckpointError::InvalidData(_))
    ));
}

#[test]
fn clear_then_hard_reset_emits_deactivation_revision_and_event() {
    let mut term = Terminal::new(80, 24);
    term.feed(b"\x1b]7501;state=working:id=main:app=Codex\x1b\\");
    let _ = term.drain_program_status_updates(64);
    let _ = term.take_events();
    assert!(term.program_status_snapshot().osc7501_active);
    assert_eq!(term.program_status_snapshot().revision, 1);

    // Explicit clear empties records while keeping osc7501_active = true.
    term.feed(b"\x1b]7501;state=clear\x1b\\");
    let _ = term.drain_program_status_updates(64);
    let _ = term.take_events();
    let after_clear = term.program_status_snapshot();
    assert!(after_clear.osc7501_active);
    assert!(after_clear.records.is_empty());
    assert_eq!(after_clear.revision, 2);

    // Subsequent RIS (ESC c) on an already-empty table MUST still bump revision and emit HardReset
    // so host consumers clear cached osc7501Active authority!
    term.feed(b"\x1bc");
    let after_ris = term.program_status_snapshot();
    assert!(!after_ris.osc7501_active);
    assert_eq!(after_ris.revision, 3);

    let drained = term.drain_program_status_updates(64);
    assert_eq!(drained.updates.len(), 1);
    assert_eq!(drained.updates[0].revision, 3);
    assert_eq!(
        drained.updates[0].mutations,
        vec![ProgramStatusMutation::Reset {
            removed_count: 0,
            reason: ProgramStatusRemovalReason::HardReset,
        }]
    );

    let events = term.take_events();
    let Some(TerminalEvent::ProgramStatusChanged(ev)) = events.last() else {
        panic!("expected ProgramStatusChanged on RIS after clear");
    };
    assert_eq!(ev.update.revision, 3);
    assert_eq!(ev.snapshot.revision, 3);
    assert!(!ev.snapshot.osc7501_active);
}
