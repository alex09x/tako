// Reading the end of a terminal's text without reading all of it.

use tako_core::terminal::Terminal;

#[test]
fn the_last_lines_come_back_in_order_without_the_blank_screen_below() {
    let mut t = Terminal::with_scrollback(20, 10, 1000);
    for i in 0..50 {
        t.feed(format!("line {i}\r\n").as_bytes());
    }
    let tail = t.text_tail(3, 1 << 20);
    assert_eq!(tail.text, "line 47\nline 48\nline 49");
    assert_eq!(tail.lines, 3);
    assert!(tail.more && !tail.truncated);
}

#[test]
fn soft_wrapped_rows_are_one_line() {
    let mut t = Terminal::new(5, 4);
    t.feed(b"abcdefghij\r\nxy");
    assert_eq!(t.text_tail(2, 1024).text, "abcdefghij\nxy");
}

#[test]
fn everything_when_fewer_lines_exist_than_asked() {
    let mut t = Terminal::new(20, 6);
    t.feed(b"only\r\ntwo");
    let tail = t.text_tail(100, 1024);
    assert_eq!(tail.text, "only\ntwo");
    assert!(!tail.more);
}

#[test]
fn the_byte_limit_cuts_the_oldest_line_at_a_character_boundary() {
    let mut t = Terminal::new(40, 4);
    t.feed("ёёёёёёёёёё\r\nend".as_bytes());
    let tail = t.text_tail(10, 9);
    assert!(tail.truncated);
    assert!(tail.text.ends_with("\nend"), "{:?}", tail.text);
    assert!(tail.text.len() <= 9, "{:?}", tail.text);
    // Whole characters only.
    assert!(tail.text.chars().all(|c| c == 'ё' || c == '\n' || "end".contains(c)));
}

#[test]
fn a_huge_history_costs_only_the_tail() {
    let mut t = Terminal::with_scrollback(80, 24, 100_000);
    let line = "x".repeat(70);
    for _ in 0..100_000 {
        t.feed(format!("{line}\r\n").as_bytes());
    }
    t.feed(b"last");
    let start = std::time::Instant::now();
    for _ in 0..100 {
        assert_eq!(t.text_tail(1, 1 << 20).text, "last");
    }
    // A hundred one-line reads: nowhere near a hundred walks of 100k rows.
    assert!(start.elapsed() < std::time::Duration::from_millis(500), "{:?}", start.elapsed());
}
