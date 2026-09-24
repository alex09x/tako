// Ported from the upstream `index_b` test suite (upstream terminal core parity tests)

use tako_core::grid::Color;
use tako_core::terminal::Terminal;

fn dump_screen(term: &Terminal) -> String {
    let grid = term.active_grid();
    let mut lines: Vec<String> = Vec::new();

    for line_cells in grid.scrollback_iter() {
        let mut line = String::new();
        for cell in line_cells {
            if !cell.is_wide_spacer {
                line.push(if cell.char == '\0' { ' ' } else { cell.char });
            }
        }
        while line.ends_with(' ') {
            line.pop();
        }
        lines.push(line);
    }

    for row in 0..grid.rows() {
        let mut line = String::new();
        for col in 0..grid.cols() {
            let Some(cell) = grid.get(row, col) else { continue };
            if !cell.is_wide_spacer {
                line.push(if cell.char == '\0' { ' ' } else { cell.char });
            }
        }
        while line.ends_with(' ') {
            line.pop();
        }
        lines.push(line);
    }

    while lines.last().is_some_and(|l| l.is_empty()) {
        lines.pop();
    }
    lines.join("\r\n")
}

/// Upstream test: "Terminal: index bottom of scroll region with background SGR"
#[test]
fn index_bottom_of_scroll_region_with_background_sgr() {
    let mut term = Terminal::new(5, 5);

    term.feed(b"\x1b[1;3r");
    term.feed(b"\x1b[4;1H");
    term.feed(b"B");
    term.feed(b"\x1b[3;1H");
    term.feed(b"A");
    term.feed(b"\x1b[48;2;255;0;0m");
    term.feed(b"\x1bD");

    assert_eq!(term.plain_string(), "\nA\n\nB");

    for x in 0..5 {
        let cell = term.active_grid().get(2, x).unwrap();
        assert_eq!(cell.bg, Color::Rgb(255, 0, 0));
    }
}

/// Upstream test: "Terminal: index bottom of primary screen with scroll region"
#[test]
fn index_bottom_of_primary_screen_with_scroll_region() {
    let mut term = Terminal::new(5, 5);

    term.feed(b"\x1b[1;3r");
    term.feed(b"\x1b[3;1H");
    term.feed(b"A");
    term.feed(b"\x1b[5;1H");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1bD");
    term.feed(b"\x1bD");
    term.feed(b"\x1bD");
    term.feed(b"X");

    // upstream: dirty-tracking assert, not modeled
    assert_eq!(term.plain_string(), "\n\nA\n\nX");
}

/// Upstream test: "Terminal: index bottom of scroll region creates scrollback"
#[test]
fn index_bottom_of_scroll_region_creates_scrollback() {
    let mut term = Terminal::new(5, 5);

    term.feed(b"\x1b[1;3r");
    term.feed(b"1\r\n2\r\n3");
    term.feed(b"\x1b[4;1H");
    term.feed(b"X");
    term.feed(b"\x1b[3;1H");
    term.feed(b"\x1bD");
    term.feed(b"Y");

    assert_eq!(term.plain_string(), "2\n3\nY\nX");
    assert_eq!(dump_screen(&term), "1\r\n2\r\n3\r\nY\r\nX");
}

/// Upstream test: "Terminal: index bottom of scroll region no scrollback"
#[test]
fn index_bottom_of_scroll_region_no_scrollback() {
    let mut term = Terminal::new(5, 5);

    term.feed(b"\x1b[1;3r");
    term.feed(b"\x1b[4;1H");
    term.feed(b"B");
    term.feed(b"\x1b[3;1H");
    term.feed(b"A");
    // upstream: dirty-tracking assert, not modeled
    term.feed(b"\x1bD");
    term.feed(b"X");

    assert_eq!(term.plain_string(), "\nA\n X\nB");
}

/// Upstream test: "Terminal: index bottom of scroll region blank line preserves SGR"
#[test]
fn index_bottom_of_scroll_region_blank_line_preserves_sgr() {
    let mut term = Terminal::new(5, 5);

    term.feed(b"\x1b[1;3r");
    term.feed(b"1\r\n2\r\n3");
    term.feed(b"\x1b[4;1H");
    term.feed(b"X");
    term.feed(b"\x1b[3;1H");
    term.feed(b"\x1b[48;2;255;0;0m");
    term.feed(b"\x1bD");

    assert_eq!(term.plain_string(), "2\n3\n\nX");
    assert_eq!(dump_screen(&term), "1\r\n2\r\n3\r\n\r\nX");

    for x in 0..5 {
        let cell = term.active_grid().get(2, x).unwrap();
        assert_eq!(cell.bg, Color::Rgb(255, 0, 0));
    }
}

/// Upstream test: "Terminal: index bottom of scroll region with top margin and background SGR"
#[test]
fn index_bottom_of_scroll_region_with_top_margin_and_background_sgr() {
    let mut term = Terminal::new(5, 5);

    term.feed(b"1\r\n2\r\n3\r\n4\r\n5");
    term.feed(b"\x1b[2;4r");
    term.feed(b"\x1b[4;1H");
    term.feed(b"\x1b[48;2;255;0;0m");
    term.feed(b"\x1bD");

    assert_eq!(term.plain_string(), "1\n3\n4\n\n5");

    assert_eq!(term.cursor().0, 3);

    for x in 0..5 {
        let cell = term.active_grid().get(3, x).unwrap();
        assert_eq!(cell.bg, Color::Rgb(255, 0, 0));
    }
}

/// Upstream test: "Terminal: index bottom of alt screen full region"
#[test]
fn index_bottom_of_alt_screen_full_region() {
    let mut term = Terminal::new(5, 3);

    term.feed(b"\x1b[?1049h");
    term.feed(b"A\r\nB\r\nC");
    term.feed(b"\x1bD");
    term.feed(b"\r");
    term.feed(b"D");

    assert_eq!(term.plain_string(), "B\nC\nD");
    assert_eq!(dump_screen(&term), "B\r\nC\r\nD");

    term.feed(b"\x1b[?1049l");
    assert_eq!(term.plain_string(), "");
}

/// Upstream test: "Terminal: index bottom of alt screen top region"
#[test]
fn index_bottom_of_alt_screen_top_region() {
    let mut term = Terminal::new(5, 5);

    term.feed(b"\x1b[?1049h");
    term.feed(b"1\r\n2\r\n3\r\n4\r\n5");

    term.feed(b"\x1b[1;4r");
    term.feed(b"\x1b[4;1H");
    term.feed(b"\x1bD");
    term.feed(b"X");

    assert_eq!(term.plain_string(), "2\n3\n4\nX\n5");
    assert_eq!(dump_screen(&term), "2\r\n3\r\n4\r\nX\r\n5");
}

// PORTED in tests/parity_semantic_prompt.rs: "Terminal: index in prompt mode marks new row as prompt continuation"
// PORTED in tests/parity_semantic_prompt.rs: "Terminal: index in input mode does not mark new row as prompt"
// PORTED in tests/parity_semantic_prompt.rs: "Terminal: index in output mode does not mark new row as prompt"
