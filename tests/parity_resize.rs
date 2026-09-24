// Source: the upstream `resize` test suite

use tako_core::terminal::Terminal;

// SKIPPED "Terminal: resize failure paths preserve consistent state": depends
// on Zig's allocator fault-injection harness (resize_tw.FailPoint,
// tw.errorAlways(tag, error.OutOfMemory)) to verify state stays consistent
// after a simulated allocation failure mid-resize. Rust has no equivalent
// fallible-allocation injection point in this crate (allocation failure
// aborts, it isn't a recoverable `Result`), so the scenario isn't
// expressible -- same category as the two upstream `alt_screen` fault-injection
// tests above.

/// Upstream test: "Terminal: resize rejects zero dimensions before mutation"
#[test]
fn resize_rejects_zero_dimensions_before_mutation() {
    let mut term = Terminal::new(10, 5);
    term.resize(0, 5);
    term.resize(10, 0);

    assert_eq!(term.active_grid().cols(), 10);
    assert_eq!(term.active_grid().rows(), 5);
}

/// Not an upstream test -- a regression found live: a fresh app window's
/// AppKit layout pass resizes its terminal view through a near-zero
/// intermediate size (observed: 80x24 -> 2x1 -> 151x39) before settling on
/// the real one. `Terminal::resize` used to resize the tabstops bitset in
/// place (preserving old positions, padding new columns with no stop at
/// all), so collapsing to 2 columns silently discarded every default
/// every-8 tabstop; growing back to 151 never restored them, since growth
/// only pads with `false`. A `\t` afterward had nowhere to land short of
/// the last column -- instantly visible on any real app that leans on tabs
/// for output alignment (a TUI redraw, say), and exactly what happened.
/// Upstream's own resize (upstream `Terminal`) never has this problem because it
/// rebuilds tabstops from scratch on every column-count change instead of
/// resizing them in place.
#[test]
fn resize_through_tiny_intermediate_size_keeps_default_tabstops() {
    let mut term = Terminal::new(80, 24);
    term.resize(2, 1);
    term.resize(151, 39);

    term.feed(b"\t");
    assert_eq!(term.cursor(), (0, 8), "first tab should land on the default column-8 stop");

    term.feed(b"\t");
    assert_eq!(term.cursor(), (0, 16), "second tab should land on the default column-16 stop");
}

// PORTED in tests/parity_revived.rs: "Terminal: resize preserves pixel dimensions when omitted"
