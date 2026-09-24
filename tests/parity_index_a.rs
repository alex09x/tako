// Upstream tests ported from the upstream `index_a` test suite

use tako_core::grid::Color;
use tako_core::terminal::Terminal;

/// Upstream test: "Terminal: index"
#[test]
fn index() {
    let mut term = Terminal::new(2, 5);

    term.feed(b"\x1bD");
    term.feed(b"A");

    // upstream: dirty-tracking assert, not modeled
    // upstream: dirty-tracking assert, not modeled

    assert_eq!(term.plain_string(), "\nA");
}

/// Upstream test: "Terminal: index from the bottom"
#[test]
fn index_from_the_bottom() {
    let mut term = Terminal::new(2, 5);

    term.feed(b"\x1b[5;1H");
    term.feed(b"A");
    term.feed(b"\x1b[1D"); // undo moving right from 'A'

    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1bD");
    term.feed(b"B");

    // upstream: dirty-tracking assert, not modeled
    // upstream: dirty-tracking assert, not modeled

    assert_eq!(term.plain_string(), "\n\n\nA\nB");
}

/// Upstream test: "Terminal: index scrolling with hyperlink"
#[test]
fn index_scrolling_with_hyperlink() {
    let mut term = Terminal::new(2, 5);

    term.feed(b"\x1b[5;1H");
    term.feed(b"\x1b]8;;http://example.com\x1b\\");
    term.feed(b"A");
    term.feed(b"\x1b]8;;\x1b\\");
    term.feed(b"\x1b[1D"); // undo moving right from 'A'
    term.feed(b"\x1bD");
    term.feed(b"B");

    assert_eq!(term.plain_string(), "\n\n\nA\nB");

    let cell_y3 = term.active_grid().get(3, 0).unwrap();
    assert!(cell_y3.hyperlink.is_some());
    assert_eq!(cell_y3.hyperlink, Some(1));

    let cell_y4 = term.active_grid().get(4, 0).unwrap();
    assert!(cell_y4.hyperlink.is_none());
}

/// Upstream test: "Terminal: index outside of scrolling region"
#[test]
fn index_outside_of_scrolling_region() {
    let mut term = Terminal::new(2, 5);

    assert_eq!(term.cursor().0, 0);
    term.feed(b"\x1b[2;5r");
    term.feed(b"\x1bD");
    assert_eq!(term.cursor().0, 1);
}

/// Upstream test: "Terminal: index from the bottom outside of scroll region"
#[test]
fn index_from_the_bottom_outside_of_scroll_region() {
    let mut term = Terminal::new(2, 5);

    term.feed(b"\x1b[1;2r");
    term.feed(b"\x1b[5;1H");
    term.feed(b"A");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1bD");
    term.feed(b"B");
    // upstream: dirty-tracking assert, not modeled

    assert_eq!(term.plain_string(), "\n\n\n\nAB");
}

/// Upstream test: "Terminal: index no scroll region, top of screen"
#[test]
fn index_no_scroll_region_top_of_screen() {
    let mut term = Terminal::new(5, 5);

    term.feed(b"A");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1bD");
    term.feed(b"X");

    // upstream: dirty-tracking assert, not modeled
    // upstream: dirty-tracking assert, not modeled

    assert_eq!(term.plain_string(), "A\n X");
}

/// Upstream test: "Terminal: index bottom of primary screen"
#[test]
fn index_bottom_of_primary_screen() {
    let mut term = Terminal::new(5, 5);

    term.feed(b"\x1b[5;1H");
    term.feed(b"A");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1bD");
    term.feed(b"X");

    // upstream: dirty-tracking assert, not modeled
    // upstream: dirty-tracking assert, not modeled

    assert_eq!(term.plain_string(), "\n\n\nA\n X");
}

/// Upstream test: "Terminal: index bottom of primary screen background sgr"
#[test]
fn index_bottom_of_primary_screen_background_sgr() {
    let mut term = Terminal::new(5, 5);

    term.feed(b"\x1b[5;1H");
    term.feed(b"A");
    term.feed(b"\x1b[48;2;255;0;0m");
    term.feed(b"\x1bD");

    assert_eq!(term.plain_string(), "\n\n\nA");
    for x in 0..5 {
        let cell = term.active_grid().get(4, x).unwrap();
        assert_eq!(cell.bg, Color::Rgb(255, 0, 0));
    }
}

/// Upstream test: "Terminal: index inside scroll region"
#[test]
fn index_inside_scroll_region() {
    let mut term = Terminal::new(5, 5);

    term.feed(b"\x1b[1;3r");
    term.feed(b"A");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1bD");
    term.feed(b"X");

    // upstream: dirty-tracking assert, not modeled
    // upstream: dirty-tracking assert, not modeled

    assert_eq!(term.plain_string(), "A\n X");
}

/// Upstream test: "Terminal: index bottom of scroll region with hyperlinks"
#[test]
fn index_bottom_of_scroll_region_with_hyperlinks() {
    let mut term = Terminal::new(5, 5);

    term.feed(b"\x1b[1;2r");
    term.feed(b"A");
    term.feed(b"\x1bD");
    term.feed(b"\r");
    term.feed(b"\x1b]8;;http://example.com\x1b\\");
    term.feed(b"B");
    term.feed(b"\x1b]8;;\x1b\\");
    term.feed(b"\x1bD");
    term.feed(b"\r");
    term.feed(b"C");

    assert_eq!(term.plain_string(), "B\nC");

    let cell_y0 = term.active_grid().get(0, 0).unwrap();
    assert!(cell_y0.hyperlink.is_some());
    assert_eq!(cell_y0.hyperlink, Some(1));

    let cell_y1 = term.active_grid().get(1, 0).unwrap();
    assert!(cell_y1.hyperlink.is_none());
}

/// Upstream test: "Terminal: index bottom of scroll region clear hyperlinks"
#[test]
fn index_bottom_of_scroll_region_clear_hyperlinks() {
    let mut term = Terminal::new(5, 5);

    term.feed(b"\x1b[2;3r");
    term.feed(b"\x1b[2;1H");
    term.feed(b"\x1b]8;;http://example.com\x1b\\");
    term.feed(b"A");
    term.feed(b"\x1b]8;;\x1b\\");
    term.feed(b"\x1bD");
    term.feed(b"\r");
    term.feed(b"B");
    term.feed(b"\x1bD");
    term.feed(b"\r");
    term.feed(b"C");

    assert_eq!(term.plain_string(), "\nB\nC");

    for y in 1..3 {
        let cell = term.active_grid().get(y, 0).unwrap();
        assert!(cell.hyperlink.is_none());
    }
}
