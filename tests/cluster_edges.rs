// Where a grapheme cluster meets the rest of the stream: the character before
// a combining mark, an erase right after one, a single shift, a run of marks
// that never ends. Adapted from an MIT-licensed terminal emulator's test
// suite (see NOTICE.md).

use std::time::{Duration, Instant};

use tako_core::terminal::Terminal;

/// The text of each of the first `n` cells of row 0, "" for the column a
/// wide character covers.
fn cells(t: &Terminal, n: usize) -> Vec<String> {
    let grid = t.active_grid();
    (0..n)
        .map(|col| {
            let cell = grid.get(0, col).unwrap();
            if cell.is_wide_spacer {
                return String::new();
            }
            let mut out = String::new();
            grid.push_cell_text(&mut out, cell);
            out
        })
        .collect()
}

fn after(input: &str, n: usize) -> Vec<String> {
    let mut t = Terminal::new(10, 1);
    t.feed(input.as_bytes());
    cells(&t, n)
}

#[test]
fn a_combining_mark_joins_the_character_before_it() {
    // "e" then U+0301, however the "e" arrived.
    assert_eq!(after("bce\u{301}", 3), ["b", "c", "é"], "bare");
    assert_eq!(
        after("bce\u{301}\x1b[K", 3),
        ["b", "c", "é"],
        "then an erase"
    );
    assert_eq!(
        after("bce\u{301}x", 4),
        ["b", "c", "é", "x"],
        "then another character"
    );
    assert_eq!(
        after("a\u{301}b\u{301}c", 3),
        ["á", "b\u{301}", "c"],
        "several in a row"
    );
}

#[test]
fn a_combining_mark_joins_a_wide_character_whole() {
    assert_eq!(after("世\u{301}x", 3), ["世\u{301}", "", "x"]);
}

#[test]
fn a_skin_tone_joins_the_emoji_it_modifies() {
    assert_eq!(
        after("\u{1f44b}\u{1f3ff}x", 3),
        ["\u{1f44b}\u{1f3ff}", "", "x"]
    );
}

#[test]
fn the_last_character_of_a_write_is_on_screen_at_once() {
    assert_eq!(after("hi", 2), ["h", "i"]);
}

#[test]
fn a_single_shift_applies_to_one_character_only() {
    // G2 is DEC line drawing; ESC N (SS2) takes the next character from it.
    // Charsets map one codepoint at a time, as in xterm, so the "a" of a
    // cluster is mapped and its mark stays on it. What must hold is that the
    // shift is used up there and never reaches the "b".
    assert_eq!(
        after("\x1b*0\x1bNa\u{301}b", 2),
        ["▒\u{301}", "b"],
        "cluster, then plain"
    );
    assert_eq!(after("\x1b*0\x1bNab", 2), ["▒", "b"], "mapped, then plain");
}

#[test]
fn a_long_run_of_marks_stays_linear() {
    // One cluster that keeps growing. Re-segmenting it on every mark is
    // quadratic; the budget is thousands of times the linear cost and a
    // fraction of the quadratic one.
    let input = format!("a{}", "\u{301}".repeat(32 * 1024));
    let mut t = Terminal::new(80, 24);
    let start = Instant::now();
    t.feed(input.as_bytes());
    let elapsed = start.elapsed();
    assert!(
        elapsed < Duration::from_secs(10),
        "{} bytes of one cluster took {elapsed:?}",
        input.len()
    );
    assert_eq!(t.cursor(), (0, 1), "still one cell");
}
