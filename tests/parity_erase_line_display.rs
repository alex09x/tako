// Source file: the upstream `erase_line_display` test suite

use tako_core::grid::Color;
use tako_core::terminal::Terminal;

/// Upstream test: "Terminal: eraseLine simple erase right"
#[test]
fn erase_line_simple_erase_right() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABCDE");
    term.feed(b"\x1b[1;3H");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[K");
    // upstream: dirty-tracking assert, not modeled
    assert_eq!(term.plain_string(), "AB");
}

/// Upstream test: "Terminal: eraseLine resets pending wrap"
#[test]
fn erase_line_resets_pending_wrap() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABCDE");
    assert!(term.pending_wrap());
    term.feed(b"\x1b[K");
    assert!(!term.pending_wrap());
    term.feed(b"B");
    assert_eq!(term.plain_string(), "ABCDB");
}

/// Upstream test: "Terminal: eraseLine right preserves background sgr"
#[test]
fn erase_line_right_preserves_background_sgr() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABCDE");
    term.feed(b"\x1b[1;2H");
    term.feed(b"\x1b[48;2;255;0;0m");
    term.feed(b"\x1b[K");

    assert_eq!(term.plain_string(), "A");
    for x in 1..5 {
        let cell = term.active_grid().get(0, x).unwrap();
        assert_eq!(cell.bg, Color::Rgb(255, 0, 0));
    }
}

/// Upstream test: "Terminal: eraseLine right wide character"
#[test]
fn erase_line_right_wide_character() {
    let mut term = Terminal::new(10, 5);
    term.feed(b"AB");
    term.feed("橋".as_bytes());
    term.feed(b"DE");
    term.feed(b"\x1b[1;4H");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[K");
    // upstream: dirty-tracking assert, not modeled
    assert_eq!(term.plain_string(), "AB");
}

/// Upstream test: "Terminal: eraseLine simple erase left"
#[test]
fn erase_line_simple_erase_left() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABCDE");
    term.feed(b"\x1b[1;3H");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[1K");
    // upstream: dirty-tracking assert, not modeled
    assert_eq!(term.plain_string(), "   DE");
}

/// Upstream test: "Terminal: eraseLine left resets wrap"
#[test]
fn erase_line_left_resets_wrap() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABCDE");
    assert!(term.pending_wrap());
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[1K");
    // upstream: dirty-tracking assert, not modeled
    assert!(!term.pending_wrap());
    term.feed(b"B");
    assert_eq!(term.plain_string(), "    B");
}

/// Upstream test: "Terminal: eraseLine left preserves background sgr"
#[test]
fn erase_line_left_preserves_background_sgr() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABCDE");
    term.feed(b"\x1b[1;2H");
    term.feed(b"\x1b[48;2;255;0;0m");
    term.feed(b"\x1b[1K");

    assert_eq!(term.plain_string(), "  CDE");
    for x in 0..2 {
        let cell = term.active_grid().get(0, x).unwrap();
        assert_eq!(cell.bg, Color::Rgb(255, 0, 0));
    }
}

/// Upstream test: "Terminal: eraseLine left wide character"
#[test]
fn erase_line_left_wide_character() {
    let mut term = Terminal::new(10, 5);
    term.feed(b"AB");
    term.feed("橋".as_bytes());
    term.feed(b"DE");
    term.feed(b"\x1b[1;3H");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[1K");
    // upstream: dirty-tracking assert, not modeled
    assert_eq!(term.plain_string(), "    DE");
}

/// Upstream test: "Terminal: eraseLine complete preserves background sgr"
#[test]
fn erase_line_complete_preserves_background_sgr() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABCDE");
    term.feed(b"\x1b[1;2H");
    term.feed(b"\x1b[48;2;255;0;0m");
    term.feed(b"\x1b[2K");

    assert_eq!(term.plain_string(), "");
    for x in 0..5 {
        let cell = term.active_grid().get(0, x).unwrap();
        assert_eq!(cell.bg, Color::Rgb(255, 0, 0));
    }
}

/// Upstream test: "Terminal: eraseDisplay simple erase below"
#[test]
fn erase_display_simple_erase_below() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABC");
    term.feed(b"\r\n");
    term.feed(b"DEF");
    term.feed(b"\r\n");
    term.feed(b"GHI");
    term.feed(b"\x1b[2;2H");

    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[J");
    // upstream: dirty-tracking assert, not modeled

    assert_eq!(term.plain_string(), "ABC\nD");
}

/// Upstream test: "Terminal: eraseDisplay erase below preserves SGR bg"
#[test]
fn erase_display_erase_below_preserves_sgr_bg() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABC");
    term.feed(b"\r\n");
    term.feed(b"DEF");
    term.feed(b"\r\n");
    term.feed(b"GHI");
    term.feed(b"\x1b[2;2H");

    term.feed(b"\x1b[48;2;255;0;0m");
    term.feed(b"\x1b[J");

    assert_eq!(term.plain_string(), "ABC\nD");
    for x in 1..5 {
        let cell = term.active_grid().get(1, x).unwrap();
        assert_eq!(cell.bg, Color::Rgb(255, 0, 0));
    }
}

/// Upstream test: "Terminal: eraseDisplay below split multi-cell"
#[test]
fn erase_display_below_split_multi_cell() {
    let mut term = Terminal::new(5, 5);
    term.feed("AB橋C".as_bytes());
    term.feed(b"\r\n");
    term.feed("DE橋F".as_bytes());
    term.feed(b"\r\n");
    term.feed("GH橋I".as_bytes());
    term.feed(b"\x1b[2;4H");
    term.feed(b"\x1b[J");

    assert_eq!(term.plain_string(), "AB橋C\nDE");
}

/// Upstream test: "Terminal: eraseDisplay simple erase above"
#[test]
fn erase_display_simple_erase_above() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABC");
    term.feed(b"\r\n");
    term.feed(b"DEF");
    term.feed(b"\r\n");
    term.feed(b"GHI");
    term.feed(b"\x1b[2;2H");

    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1b[1J");
    // upstream: dirty-tracking assert, not modeled

    assert_eq!(term.plain_string(), "\n  F\nGHI");
}

/// Upstream test: "Terminal: eraseDisplay erase above preserves SGR bg"
#[test]
fn erase_display_erase_above_preserves_sgr_bg() {
    let mut term = Terminal::new(5, 5);
    term.feed(b"ABC");
    term.feed(b"\r\n");
    term.feed(b"DEF");
    term.feed(b"\r\n");
    term.feed(b"GHI");
    term.feed(b"\x1b[2;2H");

    term.feed(b"\x1b[48;2;255;0;0m");
    term.feed(b"\x1b[1J");

    assert_eq!(term.plain_string(), "\n  F\nGHI");
    for x in 0..2 {
        let cell = term.active_grid().get(1, x).unwrap();
        assert_eq!(cell.bg, Color::Rgb(255, 0, 0));
    }
}

/// Upstream test: "Terminal: eraseDisplay above split multi-cell"
#[test]
fn erase_display_above_split_multi_cell() {
    let mut term = Terminal::new(5, 5);
    term.feed("AB橋C".as_bytes());
    term.feed(b"\r\n");
    term.feed("DE橋F".as_bytes());
    term.feed(b"\r\n");
    term.feed("GH橋I".as_bytes());
    term.feed(b"\x1b[2;3H");
    term.feed(b"\x1b[1J");

    assert_eq!(term.plain_string(), "\n    F\nGH橋I");
}

// SKIPPED "Terminal: eraseDisplay complete preserves cursor": depends on internal style_id refcounting not modeled in this port
