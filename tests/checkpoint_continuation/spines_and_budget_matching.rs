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

/// Reserving a container costs memory before a single byte of its contents is
/// read, and a budget that does not charge for it is not a budget.
///
/// The forged grid is chosen so that the cells alone land *exactly* on the
/// limit: only the per-row spine pushes it over. Stop charging the spine and
/// the import is admitted and fails later on the truncated payload instead,
/// which is a different error -- so this test cannot pass by accident.
#[test]
fn test_container_spines_are_charged_against_the_allocation_budget() {
    use tako_core::terminal::checkpoint::{
        CELL_BYTES, CheckpointError, GRID_ROW_SPINE, MAX_DIM, MAX_IMPORT_ALLOC_BYTES,
    };

    // The primary grid is charged first and is decoded before the alternate is
    // charged at all, so the boundary has to be crossed on that first grid:
    // 2^24 cells put its cells alone exactly on the limit.
    const COLS: u32 = 8_192;
    const ROWS: u32 = 2_048;
    assert!(COLS as usize <= MAX_DIM && ROWS as usize <= MAX_DIM);
    let cells = (COLS as u64) * (ROWS as u64) * CELL_BYTES;
    assert_eq!(
        cells, MAX_IMPORT_ALLOC_BYTES,
        "the geometry must land on the limit, not past it"
    );
    assert!(
        cells + (ROWS as u64) * GRID_ROW_SPINE > MAX_IMPORT_ALLOC_BYTES,
        "and the row spines must be what carries it over"
    );

    let mut term = Terminal::new(80, 24);
    term.feed(b"honest source");
    let valid = term.export_checkpoint().unwrap();

    // cols and rows are the first two u32 of the payload.
    let mut forged = valid.clone();
    forged[20..24].copy_from_slice(&COLS.to_le_bytes());
    forged[24..28].copy_from_slice(&ROWS.to_le_bytes());
    let forged = reseal(forged);
    assert!(
        Terminal::verify_checkpoint(&forged),
        "still a well-formed container"
    );

    let mut dest = Terminal::new(60, 20);
    dest.feed(b"DESTINATION");
    let before = dest.export_checkpoint().unwrap();

    assert_eq!(
        dest.import_checkpoint(&forged),
        Err(CheckpointError::AllocationLimitExceeded),
        "charged for the row spines, this is over budget"
    );
    assert_eq!(dest.export_checkpoint().unwrap(), before, "fail-intact");
    assert_eq!(row_text(&dest, 0), "DESTINATION");
}

/// What export charges is what import charges, spines included: the number
/// export refuses above is the number a host can ask for in advance.
#[test]
fn test_import_cost_counts_the_spines_on_both_sides() {
    use tako_core::terminal::checkpoint::{
        CELL_BYTES, GRID_ROW_SPINE, MAX_IMPORT_ALLOC_BYTES, SCROLLBACK_ROW_SPINE, import_cost,
    };

    let mut bare = Terminal::new(80, 24);
    bare.feed(b"no history yet");
    let bare_cost = import_cost(&bare);

    // Two grids of cells, two grids of row spines, and whatever the parser
    // and title carry. The floor is exact; the extra is small and non-zero.
    let floor = 80u64 * 24 * CELL_BYTES * 2 + 24 * GRID_ROW_SPINE * 2;
    assert!(bare_cost >= floor, "{bare_cost} < {floor}");

    // What one more row of history costs, measured rather than asserted: two
    // terminals of the same shape, differing only in how much has scrolled off.
    // A row is its cells *and* the `ScrollbackRow` holding them, so dropping
    // the spine from the count moves this number and the test says so.
    let history_cost = |rows: usize| {
        let mut term = Terminal::new(80, 24);
        for _ in 0..(100 + rows) {
            term.feed(b"\r\n");
        }
        import_cost(&term)
    };
    const EXTRA_ROWS: u64 = 200;
    assert_eq!(
        history_cost(EXTRA_ROWS as usize) - history_cost(0),
        EXTRA_ROWS * (80 * CELL_BYTES + SCROLLBACK_ROW_SPINE),
        "a scrollback row costs its cells plus its own spine"
    );

    let mut scrolled = Terminal::new(80, 24);
    for line in 0..300 {
        scrolled.feed(format!("history line {line}\r\n").as_bytes());
    }
    let scrolled_cost = import_cost(&scrolled);
    assert!(scrolled_cost > bare_cost, "history is not free");

    // The cost survives a round trip: what was charged to build this terminal
    // is what will be charged to rebuild it.
    let blob = scrolled.export_checkpoint().unwrap();
    let mut dest = Terminal::new(10, 4);
    dest.import_checkpoint(&blob)
        .expect("honest checkpoint imports");
    assert_eq!(
        import_cost(&dest),
        scrolled_cost,
        "export and import must agree on what the state costs"
    );
    assert!(
        scrolled_cost < MAX_IMPORT_ALLOC_BYTES,
        "and a real terminal is nowhere near the cap"
    );
}

/// The two sides of the budget are the same number.
///
/// [`import_cost`] is what export refuses above; `allocated` is what import
/// actually charged. If they drift, one direction is counting something the
/// other is not, and a checkpoint this build writes can be one it declines to
/// read back. Real terminal state, not a forgery: the symmetry has to hold on
/// the payloads that actually occur.
#[test]
fn test_export_and_import_charge_the_same_budget() {
    use tako_core::terminal::checkpoint::{import_cost, import_traced};

    let mut term = Terminal::new(100, 30);
    // Something from every charged section: history, styled cells, a title and
    // its stack, hyperlinks, tab stops, an in-flight OSC, kitty graphics, and
    // grapheme clusters (primary history/screen and alternate screen).
    for line in 0..250 {
        term.feed(format!("\x1b[3{}mhistory line {line}\x1b[0m\r\n", line % 8).as_bytes());
    }
    term.feed("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467} e\u{0301}\u{0302} \u{0938}\u{094D}\u{0924}\u{0947}\r\n".as_bytes());
    term.feed("\x1b[?1049h\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\x1b[?1049l".as_bytes());
    term.feed(b"\x1b]0;window title\x07");
    term.feed(b"\x1b[22t");
    term.feed(b"\x1b]8;id=one;https://example.invalid/a\x07linked\x1b]8;;\x07");
    term.feed(b"\x1b]8;id=two;https://example.invalid/b\x07more\x1b]8;;\x07");
    term.feed(b"\x1bH\t\x1bH");
    // A stored image and a placement, then a chunked transfer left open, so
    // the image map, the placement vector and the pending map are all charged.
    term.feed(b"\x1b_Ga=T,t=d,f=32,s=1,v=1,i=7;/4AA/w==\x1b\\");
    term.feed(b"\x1b_Ga=t,t=d,f=24,s=1,v=1,i=9,m=1;ESI=\x1b\\");
    term.feed(b"\x1b[>1u");
    term.feed(b"\x1b[>5u");

    // The fixture is only evidence while it actually populates every charged
    // container; assert that rather than trust the escape sequences.
    assert_eq!(term.graphics_placements().len(), 1, "placement vector");
    assert!(term.graphics_image(7).is_some(), "image map");
    assert!(
        term.buffer_text()
            .contains("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"),
        "cluster in buffer"
    );
    term.feed(b"\x1b]0;a title that never finish");

    let blob = term.export_checkpoint().unwrap();
    let predicted = import_cost(&term);
    let (restored, trace) = import_traced(&blob).expect("honest checkpoint imports");

    assert_eq!(
        trace.allocated, predicted,
        "import charged {} where export predicted {predicted}",
        trace.allocated
    );
    // And the restored terminal predicts the same cost again, so the number is
    // a property of the state rather than of one particular trip through it.
    assert_eq!(import_cost(&restored), predicted);
}

/// A checkpoint is refused when importing it *while the old terminal is still
/// alive* would exceed the budget, even though each state fits on its own.
///
/// `import_checkpoint` decodes the whole replacement before dropping `self`,
/// so both states are resident at the peak. Charging the incoming state from
/// zero therefore permits two individually-legal terminals to coexist above
/// the 512 MiB the container promises, which is the number a host sizes its
/// process against. The destination's own cost is what the decoder must
/// reserve before it allocates anything.
///
/// Sized so that the refusal happens *before* the replacement is built: at the
/// assert below only the destination and the (small) blob are resident, which
/// is the whole point of refusing early rather than after the fact.
#[test]
fn test_import_refuses_when_the_retained_destination_plus_replacement_exceeds_the_budget() {
    use tako_core::terminal::checkpoint::{CheckpointError, MAX_IMPORT_ALLOC_BYTES, import_cost};

    // Primary and alternate are both charged, so a cols x rows terminal costs
    // roughly 2 * cols * rows * CELL_BYTES. 10_000 x 420 lands just over half
    // the budget: legal alone, illegal in a pair.
    const COLS: usize = 10_000;
    const ROWS: usize = 420;

    let blob = {
        let mut source = Terminal::new(COLS, ROWS);
        source.feed(b"the replacement state");
        source
            .export_checkpoint()
            .expect("a big but legal state exports")
    };

    let mut dest = Terminal::new(COLS, ROWS);
    dest.feed(b"the destination that must survive\r\n");

    let dest_cost = import_cost(&dest);
    assert!(
        dest_cost < MAX_IMPORT_ALLOC_BYTES,
        "the destination alone must be legal: {dest_cost} vs {MAX_IMPORT_ALLOC_BYTES}"
    );

    let incoming = tako_core::terminal::checkpoint::inspect(&blob).expect("header parses");
    assert_eq!(
        (incoming.cols as usize, incoming.rows as usize),
        (COLS, ROWS)
    );

    // Each fits; together they do not.
    assert!(
        dest_cost.saturating_add(dest_cost) > MAX_IMPORT_ALLOC_BYTES,
        "the pair must exceed the budget for this test to mean anything"
    );

    let before = dest.export_checkpoint().expect("destination exports");
    let err = dest
        .import_checkpoint(&blob)
        .expect_err("importing into a live terminal this large must be refused");
    assert!(
        matches!(err, CheckpointError::AllocationLimitExceeded),
        "expected the budget refusal, got {err:?}"
    );

    // Fail-intact: the refusal cost the destination nothing.
    let after = dest.export_checkpoint().expect("destination still exports");
    assert_eq!(before, after, "a refused import mutated the destination");
}
