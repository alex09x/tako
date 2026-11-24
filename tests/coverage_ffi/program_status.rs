/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

//! OSC 7501 program status as a Swift host sees it through `TakoCore`:
//! every state, blocked kind and removal reason crosses the FFI as itself,
//! the update stream drains in order, and the host's lifecycle calls remove
//! exactly the records they are meant to.

use super::common::{TakoCore, base64_encode};
use tako_core::ffi::program_status_types::{
    FfiProgramStatusLifecycle, FfiProgramStatusLifecycleOutcome,
};
use tako_core::ffi::{
    FfiProgramStatusBlockedKind as Kind, FfiProgramStatusMutation as Mutation,
    FfiProgramStatusRemovalReason as Reason, FfiProgramStatusState as State, FfiTerminalReplyClass,
};

fn report(core: &TakoCore, fields: &str) {
    core.feed(format!("\x1b]7501;{fields}\x1b\\").into_bytes());
}

fn state_of(core: &TakoCore, id: &str) -> Option<(State, Option<Kind>)> {
    core.program_status_snapshot()
        .records
        .into_iter()
        .find(|r| r.id == id)
        .map(|r| (r.state, r.kind))
}

/// What the stream said since the last drain, as (removed id, reason) pairs
/// plus the reasons of any whole-table reset.
fn drained(core: &TakoCore) -> (Vec<(String, Reason)>, Vec<(u32, Reason)>, Vec<String>) {
    let batch = core.drain_program_status_updates(64);
    assert!(!batch.has_more);
    let (mut removed, mut resets, mut upserted) = (vec![], vec![], vec![]);
    for update in batch.updates {
        for mutation in update.mutations {
            match mutation {
                Mutation::Upserted { record } => upserted.push(record.id),
                Mutation::Removed {
                    id,
                    previous,
                    reason,
                } => {
                    assert_eq!(id, previous.id, "a removal names the record it removed");
                    removed.push((id, reason));
                }
                Mutation::Reset {
                    removed_count,
                    reason,
                } => resets.push((removed_count, reason)),
            }
        }
    }
    (removed, resets, upserted)
}

#[test]
fn every_state_and_blocked_kind_reaches_the_host_as_reported() {
    let core = TakoCore::new(80, 24);
    let msg = base64_encode("Approve the edit?".as_bytes());
    report(&core, "state=idle:id=a");
    report(&core, "state=working:id=b:app=codex:progress=40");
    report(&core, "state=done:id=c");
    report(&core, "state=error:id=d");
    report(
        &core,
        &format!("state=blocked:id=e:kind=permission:msg={msg}"),
    );
    report(&core, "state=blocked:id=f:kind=question");
    report(&core, "state=blocked:id=g:kind=auth");

    assert_eq!(state_of(&core, "a"), Some((State::Idle, None)));
    assert_eq!(state_of(&core, "b"), Some((State::Working, None)));
    assert_eq!(state_of(&core, "c"), Some((State::Done, None)));
    assert_eq!(state_of(&core, "d"), Some((State::Error, None)));
    assert_eq!(
        state_of(&core, "e"),
        Some((State::Blocked, Some(Kind::Permission)))
    );
    assert_eq!(
        state_of(&core, "f"),
        Some((State::Blocked, Some(Kind::Question)))
    );
    assert_eq!(
        state_of(&core, "g"),
        Some((State::Blocked, Some(Kind::Auth)))
    );

    let snap = core.program_status_snapshot();
    assert!(snap.osc7501_active);
    assert_eq!(snap.records.len(), 7);
    let working = snap.records.iter().find(|r| r.id == "b").unwrap();
    assert_eq!(
        (working.app.as_deref(), working.progress),
        (Some("codex"), Some(40))
    );
    let blocked = snap.records.iter().find(|r| r.id == "e").unwrap();
    assert_eq!(blocked.msg.as_deref(), Some("Approve the edit?"));
    assert!(snap.effective.is_some());

    let (_, _, upserted) = drained(&core);
    assert_eq!(
        upserted,
        ["a", "b", "c", "d", "e", "f", "g"],
        "one upsert each, in order"
    );
}

#[test]
fn clears_prompt_return_and_reset_reach_the_host_with_their_reasons() {
    let core = TakoCore::new(80, 24);
    report(&core, "state=working:id=build");
    report(&core, "state=done:id=test");
    report(&core, "state=working:id=lint");
    drained(&core);

    // An id clears that record only.
    report(&core, "state=clear:id=build");
    let (removed, resets, _) = drained(&core);
    assert_eq!(removed, [("build".to_string(), Reason::ExplicitClear)]);
    assert!(resets.is_empty());

    // A returning prompt ends work in progress, not a finished outcome.
    core.feed(b"\x1b]133;A\x07".to_vec());
    let (removed, _, _) = drained(&core);
    assert_eq!(removed, [("lint".to_string(), Reason::PromptReturn)]);
    assert_eq!(state_of(&core, "test"), Some((State::Done, None)));

    // A clear without an id empties the table at once.
    report(&core, "state=clear");
    let (_, resets, _) = drained(&core);
    assert_eq!(resets, [(1, Reason::ExplicitClear)]);
    assert!(core.program_status_snapshot().records.is_empty());

    // A hard reset drops whatever is left.
    report(&core, "state=error:id=late");
    drained(&core);
    core.feed(b"\x1bc".to_vec());
    let (_, resets, _) = drained(&core);
    assert_eq!(
        resets.iter().map(|r| r.1).collect::<Vec<_>>(),
        [Reason::HardReset]
    );
    assert!(
        !core.program_status_snapshot().osc7501_active,
        "a hard reset ends OSC 7501 for the session"
    );
}

#[test]
fn the_oldest_record_is_evicted_past_the_cap() {
    let core = TakoCore::new(80, 24);
    for i in 0..=256 {
        report(&core, &format!("state=working:id=r{i}"));
    }
    let mut evicted = vec![];
    loop {
        let batch = core.drain_program_status_updates(64);
        for update in batch.updates {
            for mutation in update.mutations {
                if let Mutation::Removed {
                    id,
                    reason: Reason::Evicted,
                    ..
                } = mutation
                {
                    evicted.push(id);
                }
            }
        }
        if let Some(resync) = batch.resync_snapshot {
            // Too many updates for the queue: the host gets one coalesced snapshot.
            assert!(batch.overflow_coalesced);
            assert_eq!(resync.records.len(), 256);
        }
        if !batch.has_more {
            break;
        }
    }
    let snap = core.program_status_snapshot();
    assert_eq!(snap.records.len(), 256);
    assert!(
        snap.records.iter().all(|r| r.id != "r0"),
        "r0, the oldest, is gone"
    );
    assert!(
        evicted.is_empty() || evicted == ["r0"],
        "if the eviction was not coalesced away it names r0: {evicted:?}"
    );
}

fn lifecycle(
    core: &TakoCore,
    l: FfiProgramStatusLifecycle,
) -> Option<FfiProgramStatusLifecycleOutcome> {
    core.apply_program_status_lifecycle(l)
}

#[test]
fn host_lifecycle_calls_remove_what_they_end_and_nothing_else() {
    let core = TakoCore::new(80, 24);
    report(&core, "state=working:id=w");
    report(&core, "state=blocked:id=b:kind=question");
    report(&core, "state=done:id=d");
    report(&core, "state=error:id=e");
    drained(&core);

    // Interrupting ends work and a pending question; the outcomes stay.
    let outcome = lifecycle(&core, FfiProgramStatusLifecycle::Interrupted)
        .expect("something was interrupted");
    let reasons: Vec<_> = outcome
        .update
        .mutations
        .iter()
        .map(|m| match m {
            Mutation::Removed { id, reason, .. } => (id.clone(), *reason),
            other => panic!("only removals: {other:?}"),
        })
        .collect();
    assert_eq!(
        reasons,
        [
            ("b".to_string(), Reason::Interrupted),
            ("w".to_string(), Reason::Interrupted)
        ]
    );
    assert_eq!(outcome.snapshot.records.len(), 2);
    assert_eq!(outcome.snapshot.revision, outcome.update.revision);
    // The lifecycle result is the host's copy: nothing of it is left to drain.
    assert!(core.drain_program_status_updates(64).updates.is_empty());
    assert!(
        lifecycle(&core, FfiProgramStatusLifecycle::Interrupted).is_none(),
        "nothing left to interrupt"
    );

    // Looking at the outcomes acknowledges them.
    let outcome =
        lifecycle(&core, FfiProgramStatusLifecycle::Acknowledged).expect("outcomes to acknowledge");
    assert_eq!(outcome.update.mutations.len(), 2);
    assert!(outcome.snapshot.records.is_empty());
    assert!(lifecycle(&core, FfiProgramStatusLifecycle::Acknowledged).is_none());

    // The process exiting ends idle and working records.
    report(&core, "state=idle:id=i");
    let outcome =
        lifecycle(&core, FfiProgramStatusLifecycle::ProcessExited).expect("an idle record to end");
    assert!(matches!(
        &outcome.update.mutations[..],
        [Mutation::Removed {
            reason: Reason::ProcessExit,
            ..
        }]
    ));
    assert!(lifecycle(&core, FfiProgramStatusLifecycle::ProcessExited).is_none());
}

#[test]
fn direct_lifecycle_calls_leave_their_update_in_the_stream() {
    let core = TakoCore::new(80, 24);
    assert!(core.program_status_process_exited().is_none());
    assert!(core.program_status_interrupted().is_none());
    assert!(core.program_status_acknowledged().is_none());

    report(&core, "state=working:id=w");
    report(&core, "state=done:id=d");
    drained(&core);
    let interrupted = core
        .program_status_interrupted()
        .expect("work to interrupt");
    assert!(matches!(
        &interrupted.mutations[..],
        [Mutation::Removed {
            reason: Reason::Interrupted,
            ..
        }]
    ));
    let acknowledged = core
        .program_status_acknowledged()
        .expect("an outcome to acknowledge");
    assert!(matches!(
        &acknowledged.mutations[..],
        [Mutation::Removed {
            reason: Reason::Acknowledged,
            ..
        }]
    ));
    report(&core, "state=blocked:id=q:kind=auth");
    let exited = core
        .program_status_process_exited()
        .expect("a question to end");
    assert!(matches!(
        &exited.mutations[..],
        [Mutation::Removed {
            reason: Reason::ProcessExit,
            ..
        }]
    ));

    let (removed, _, upserted) = drained(&core);
    assert_eq!(upserted, ["q"]);
    assert_eq!(
        removed.iter().map(|r| r.1).collect::<Vec<_>>(),
        [
            Reason::Interrupted,
            Reason::Acknowledged,
            Reason::ProcessExit
        ],
        "each direct call left its update for the next drain"
    );
}

#[test]
fn capability_replies_are_classified_and_the_probe_can_be_silenced() {
    let core = TakoCore::new(80, 24);
    assert!(core.is_program_status_probe_reply_enabled());
    core.feed(b"\x1b]7501;?\x1b\\\x1b[c".to_vec());
    let drain = core.drain_classified_replies(1);
    assert_eq!(drain.replies.len(), 1);
    assert!(drain.has_more, "one at a time: the second waits");
    assert_eq!(
        drain.replies[0].reply_class,
        FfiTerminalReplyClass::ProgramStatusCapability
    );
    assert!(String::from_utf8_lossy(&drain.replies[0].bytes).starts_with("\x1b]7501;?"));
    let rest = core.drain_classified_replies(8);
    assert_eq!(rest.replies.len(), 1);
    assert_eq!(
        rest.replies[0].reply_class,
        FfiTerminalReplyClass::StandardDevice
    );
    assert!(rest.replies[0].seq > drain.replies[0].seq);
    assert_eq!(rest.overflow_dropped_count, 0);

    core.set_program_status_probe_reply_enabled(false);
    assert!(!core.is_program_status_probe_reply_enabled());
    core.feed(b"\x1b]7501;?\x1b\\".to_vec());
    assert!(
        core.drain_classified_replies(8).replies.is_empty(),
        "a passive client answers no probe"
    );
}
