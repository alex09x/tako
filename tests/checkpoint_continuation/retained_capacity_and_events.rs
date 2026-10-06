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

/// A terminal that has finished a large OSC still owns the buffer it used.
///
/// `Parser::clear` is `Vec::clear`: it drops the length and keeps the
/// allocation. So a terminal that consumed an 8 MiB title and then moved on is
/// holding 8 MiB (16, after the growth doubling) while every length inside it
/// reads zero -- and a checkpoint of it is a kilobyte.
///
/// That is the gap this pins: what a checkpoint of a state *decodes to* and
/// what that state *occupies* are different numbers, and only one of them is
/// the memory a live process is carrying.
#[test]
fn test_retained_capacity_outlives_a_logical_clear() {
    use tako_core::terminal::checkpoint::{import_cost, retained_cost};

    const PAYLOAD: usize = 32 * 1024;

    let mut term = Terminal::new(20, 6);
    let mut input = Vec::with_capacity(PAYLOAD + 8);
    input.extend_from_slice(b"\x1b]0;");
    input.extend(std::iter::repeat_n(b'x', PAYLOAD));
    term.feed(&input);
    drop(input);

    // Mid-sequence both numbers see the payload: it is live state, and a
    // checkpoint has to carry it.
    assert!(
        import_cost(&term) as usize > PAYLOAD,
        "an in-flight OSC belongs in the decoded cost"
    );
    assert!(
        retained_cost(&term) as usize >= PAYLOAD,
        "an in-flight OSC belongs in the retained cost"
    );

    // CAN abandons the sequence; within the 64 KiB pool threshold, the next
    // OSC calls `clear` on the same buffer. Logically the payload is gone.
    term.feed(b"\x18");
    term.feed(b"\x1b]0;short\x07");

    let decoded = import_cost(&term);
    let retained = retained_cost(&term);
    let measured = term.measure_checkpoint().expect("a small state measures");

    assert!(
        decoded < 64 * 1024 && measured < 64 * 1024,
        "the payload is logically gone, so a checkpoint of this state is small: \
         decoded={decoded} measured={measured}"
    );
    assert!(
        retained as usize >= PAYLOAD,
        "the buffer is still allocated and must still be counted: retained={retained}"
    );
    assert!(
        retained > decoded.saturating_add(PAYLOAD as u64 / 2),
        "this test is only meaningful when the two numbers diverge sharply: \
         retained={retained} decoded={decoded}"
    );
}

/// Storage the destination retained but is not using still has to be inside
/// the import budget.
///
/// The peak of a staged import is the destination plus the replacement: the
/// terminal being replaced is not freed until the assignment. Charging the
/// destination what a *checkpoint of it* would decode to gets that peak wrong
/// in exactly the case above -- a large buffer, logically empty -- because the
/// decoded cost cannot see an allocation no length reports.
///
/// Here the destination is holding 128 MiB it is not using, and the incoming
/// checkpoint decodes to 415 MiB. Either is legal alone. Both at once are not,
/// and the refusal has to happen before the replacement is built.
#[test]
fn test_import_counts_storage_the_destination_retained_after_a_logical_clear() {
    use tako_core::terminal::checkpoint::{
        CheckpointError, MAX_IMPORT_ALLOC_BYTES, import_cost, retained_cost,
    };

    // 9_996 x 839 calibrated to land ~73 KiB below MAX_IMPORT_ALLOC_BYTES,
    // so fresh accepts it while dest (holding pooled parser buffers) trips it.
    let (blob, incoming) = {
        let mut source = Terminal::new(9_996, 839);
        source.feed(b"the replacement state");
        let inc = import_cost(&source);
        let b = source
            .export_checkpoint()
            .expect("a big but legal state exports");
        (b, inc)
    };
    assert!(
        incoming < MAX_IMPORT_ALLOC_BYTES,
        "the incoming state must be legal on its own: {incoming}"
    );

    // A destination that has consumed pooled OSC and APC buffers within the
    // 64 KiB pool threshold and then abandoned them: both buffers retain their
    // capacity after a logical clear.
    let mut dest = Terminal::new(20, 6);
    dest.feed(b"the destination that must survive\r\n");
    let mut input = Vec::with_capacity((48 * 1024) + 8);
    input.extend_from_slice(b"\x1b]0;");
    input.extend(std::iter::repeat_n(b'x', 48 * 1024));
    dest.feed(&input);
    drop(input);
    dest.feed(b"\x18");
    dest.feed(b"\x1b]0;short\x07");

    let mut apc_input = Vec::with_capacity((48 * 1024) + 8);
    apc_input.extend_from_slice(b"\x1b_");
    apc_input.extend(std::iter::repeat_n(b'y', 48 * 1024));
    dest.feed(&apc_input);
    drop(apc_input);
    dest.feed(b"\x18");
    dest.feed(b"\x1b_short\x1b\\");

    let dest_decoded = import_cost(&dest);
    let dest_retained = retained_cost(&dest);

    // The premise: by the decoded measure this destination is free, and the
    // import would sail through. By what it actually occupies, it does not.
    assert!(
        dest_decoded.saturating_add(incoming) < MAX_IMPORT_ALLOC_BYTES,
        "this test proves nothing unless the decoded measure would admit the \
         import: {dest_decoded} + {incoming} vs {MAX_IMPORT_ALLOC_BYTES}"
    );
    assert!(
        dest_retained.saturating_add(incoming) > MAX_IMPORT_ALLOC_BYTES,
        "the retained destination plus the replacement must exceed the budget: \
         {dest_retained} + {incoming} vs {MAX_IMPORT_ALLOC_BYTES}"
    );

    // A terminal that is not holding anything accepts the same blob, so the
    // refusal below is about the destination and nothing else.
    let mut fresh = Terminal::new(20, 6);
    fresh
        .import_checkpoint(&blob)
        .expect("the blob is legal on its own");

    let before = dest.export_checkpoint().expect("destination exports");
    let err = dest
        .import_checkpoint(&blob)
        .expect_err("importing into a destination holding this much must be refused");
    assert!(
        matches!(err, CheckpointError::AllocationLimitExceeded),
        "expected the budget refusal, got {err:?}"
    );

    // Fail-intact, and specifically *not* by shrinking the destination to make
    // room: the retained buffer is still retained.
    let after = dest.export_checkpoint().expect("destination still exports");
    assert_eq!(before, after, "a refused import mutated the destination");
    assert_eq!(
        retained_cost(&dest),
        dest_retained,
        "a refused import must not release the destination's storage to fit"
    );
}

/// Queued host events are the destination's memory too, and a refusal must
/// not drain them to make room.
///
/// The sibling test above is about storage a `clear` left behind. This one is
/// about storage nothing has released *yet*: events the byte stream produced
/// and the host has not collected. They are excluded from the checkpoint by
/// design -- a restore must not ring the bell again -- so a measure derived
/// from what a checkpoint of the destination would decode to cannot see them
/// at all, and neither can one that charges only `events.capacity()` times the
/// size of a slot. A megabyte of OSC 0 title lives in a 24-byte slot.
///
/// So the destination below is holding ~120 MiB entirely in event payloads,
/// the incoming checkpoint decodes to ~415 MiB, and the two together are over
/// budget. The refusal has to come before the replacement is built, and it has
/// to leave the events exactly where they were: they belong to the host, and
/// discarding them to fit an import would lose a title, a clipboard write or a
/// command exit the host never saw.
#[test]
fn test_import_counts_the_payloads_of_events_the_host_has_not_collected() {
    use tako_core::terminal::checkpoint::{CheckpointError, MAX_IMPORT_ALLOC_BYTES, retained_cost};

    const EVENTS: usize = 120;
    const EACH: usize = 1 << 20;

    /// A terminal carrying `EVENTS` undelivered OSC 52 clipboard writes of `EACH` bytes.
    fn destination_with_queued_events() -> Terminal {
        let mut term = Terminal::new(20, 6);
        term.feed(b"the destination that must survive\r\n");
        let payload = {
            use base64::Engine as _;
            base64::engine::general_purpose::STANDARD.encode(vec![b'A'; EACH])
        };
        let mut osc = Vec::with_capacity(payload.len() + 16);
        osc.extend_from_slice(b"\x1b]52;c;");
        osc.extend_from_slice(payload.as_bytes());
        osc.push(0x07);
        for _ in 0..EVENTS {
            term.feed(&osc);
        }
        term
    }

    // 10_000 x 680, primary and alternate: ~415 MiB decoded, from a container
    // of a few kilobytes.
    let blob = {
        let mut source = Terminal::new(10_000, 680);
        source.feed(b"the replacement state");
        source
            .export_checkpoint()
            .expect("a big but legal state exports")
    };
    let incoming = {
        let mut probe = Terminal::new(10_000, 680);
        probe.feed(b"the replacement state");
        tako_core::terminal::checkpoint::import_cost(&probe)
    };
    assert!(
        incoming < MAX_IMPORT_ALLOC_BYTES,
        "the incoming state must be legal on its own: {incoming}"
    );

    // The same destination with the events collected is the events-blind
    // measure: identical grid, identical parser buffers, nothing queued.
    let blind = {
        let mut twin = destination_with_queued_events();
        let collected = twin.take_events();
        assert_eq!(
            collected.len(),
            EVENTS,
            "the fixture should queue one event per OSC"
        );
        drop(collected);
        retained_cost(&twin)
    };

    // A terminal holding nothing accepts the same blob, so the refusal below
    // is about the destination and nothing else.
    {
        let mut fresh = Terminal::new(20, 6);
        fresh
            .import_checkpoint(&blob)
            .expect("the blob is legal on its own");
    }

    let mut dest = destination_with_queued_events();
    let dest_retained = retained_cost(&dest);

    // The premise: without the payloads this destination looks free and the
    // import sails through. With them, it does not.
    assert!(
        blind.saturating_add(incoming) < MAX_IMPORT_ALLOC_BYTES,
        "this test proves nothing unless an events-blind measure would admit \
         the import: {blind} + {incoming} vs {MAX_IMPORT_ALLOC_BYTES}"
    );
    assert!(
        dest_retained.saturating_add(incoming) > MAX_IMPORT_ALLOC_BYTES,
        "the queued payloads must count against the budget: {dest_retained} + \
         {incoming} vs {MAX_IMPORT_ALLOC_BYTES}"
    );

    let before = dest.export_checkpoint().expect("destination exports");
    let err = dest
        .import_checkpoint(&blob)
        .expect_err("importing into a destination holding this much must be refused");
    assert!(
        matches!(err, CheckpointError::AllocationLimitExceeded),
        "expected the budget refusal, got {err:?}"
    );

    // Fail-intact, and specifically not by draining or shrinking to fit.
    let after = dest.export_checkpoint().expect("destination still exports");
    assert_eq!(before, after, "a refused import mutated the destination");
    assert_eq!(
        retained_cost(&dest),
        dest_retained,
        "a refused import must not release the destination's storage to fit"
    );
    let survivors = dest.take_events();
    assert_eq!(
        survivors.len(),
        EVENTS,
        "the host's undelivered events must survive a refused import"
    );
}
