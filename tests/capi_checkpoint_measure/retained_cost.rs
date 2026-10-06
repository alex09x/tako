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

/// A queued host event is the destination's memory, and the reservation has to
/// say so.
///
/// Events are deliberately *not* in a checkpoint: they are host-bound side
/// effects, and replaying them on restore would ring the bell twice. But
/// `take_events` is the host's call to make, and until it makes it the
/// terminal owns every payload the byte stream produced -- an OSC 0 title, an
/// OSC 52 clipboard blob, an OSC 9 notification body. All of it is live for
/// the whole of a staged import, on the side of the ledger that is not freed
/// until the assignment.
///
/// Counting `events.capacity() * size_of::<TerminalEvent>()` charges the
/// vector's spine and nothing hanging off it: 24 bytes for a megabyte. This
/// measures the terminal against the allocator rather than against another
/// estimate, and pins the reservation to what the heap actually holds.
#[test]
fn test_retained_cost_counts_the_payloads_of_queued_events() {
    use tako_core::terminal::Terminal;
    use tako_core::terminal::checkpoint::retained_cost;

    const EVENTS: usize = 8;
    const EACH: usize = 1 << 20;
    const PAYLOADS: i64 = (EVENTS * EACH) as i64;

    let payload = {
        use base64::Engine as _;
        base64::engine::general_purpose::STANDARD.encode(vec![b'x'; EACH])
    };

    arm_counter();

    let mut term = Terminal::new(20, 6);
    for _ in 0..EVENTS {
        let mut osc = Vec::with_capacity(payload.len() + 16);
        osc.extend_from_slice(b"\x1b]52;c;");
        osc.extend_from_slice(payload.as_bytes());
        osc.push(0x07);
        term.feed(&osc);
        // The fixture's own buffer is not the terminal's memory. Dropping it
        // inside the window keeps it out of both numbers below.
        drop(osc);
    }

    let live_before = live_bytes();
    let charged_before = retained_cost(&term) as i64;

    let drained = term.take_events();
    let drained_count = drained.len();
    drop(drained);

    let live_after = live_bytes();
    let charged_after = retained_cost(&term) as i64;

    disarm_counter();

    assert_eq!(
        drained_count, EVENTS,
        "each OSC 52 should have queued exactly one clipboard event"
    );

    // What the events were actually holding, as the allocator saw it.
    let released = live_before - live_after;
    assert!(
        released >= PAYLOADS,
        "the fixture is wrong: draining {EVENTS} x {EACH}-byte events released \
         only {released} bytes"
    );

    // The finding: the reservation has to fall by what was released.
    let charged_drop = charged_before - charged_after;
    assert!(
        charged_drop >= PAYLOADS,
        "draining the events released {released} bytes but the reservation fell \
         by only {charged_drop} -- event payloads are not being charged \
         (before: live={live_before} charged={charged_before}, \
         after: live={live_after} charged={charged_after})"
    );

    // And the reservation as a whole must not be substantially under what the
    // terminal holds, in either state. One percent of slack covers the small
    // allocations `retained_cost` deliberately does not model (the `Terminal`
    // itself, `Vec` headers) without admitting a missing megabyte.
    for (label, live, charged) in [
        ("with the events queued", live_before, charged_before),
        ("after draining them", live_after, charged_after),
    ] {
        assert!(
            charged.saturating_mul(100) >= live.saturating_mul(99),
            "{label}: the terminal holds {live} bytes and the reservation \
             charges {charged}"
        );
    }
}
