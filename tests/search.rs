/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

// Search over scrollback and screen: absolute line numbers that survive
// scrolling and eviction, soft-wrapped lines searched whole, grapheme
// clusters and wide characters on the cells they occupy, bounded steps.

use tako_core::grid::SearchHit;
use tako_core::terminal::Terminal;

fn line(h: &SearchHit) -> String {
    format!("{}{}{}", h.before, h.matched, h.after)
}

fn all(t: &Terminal, needle: &str) -> Vec<SearchHit> {
    t.active_grid().search_chunk(needle, None, usize::MAX, usize::MAX).hits
}

#[test]
fn finds_matches_newest_first_case_insensitively() {
    let mut t = Terminal::new(20, 3);
    t.feed(b"Error one\r\nfine\r\nerror two");
    let hits = all(&t, "ERROR");
    assert_eq!(hits.len(), 2);
    assert_eq!(line(&hits[0]), "error two");
    assert_eq!(line(&hits[1]), "Error one");
    assert_eq!(hits[1].matched, "Error");
    assert_eq!((hits[1].start_col, hits[1].end_col), (0, 4));
}

#[test]
fn line_numbers_survive_scrolling_and_eviction() {
    let mut t = Terminal::with_scrollback(10, 2, 3);
    t.feed(b"needle\r\n");
    let before = all(&t, "needle");
    assert_eq!(before.len(), 1);
    // Scroll it into scrollback: same line number.
    t.feed(b"a\r\nb\r\n");
    let after = all(&t, "needle");
    assert_eq!(after, before);
    assert!(t.active_grid().search_hit_is_current("needle", &before[0]));
    // Push it out of the three-line scrollback: gone, and said to be gone.
    t.feed(b"c\r\nd\r\ne\r\nf\r\n");
    assert!(all(&t, "needle").is_empty());
    assert!(!t.active_grid().search_hit_is_current("needle", &before[0]));
}

#[test]
fn an_overwritten_line_is_no_longer_current() {
    let mut t = Terminal::new(20, 3);
    t.feed(b"build failed");
    let hit = all(&t, "failed").remove(0);
    t.feed(b"\x1b[2J\x1b[Hbuild passed");
    assert!(!t.active_grid().search_hit_is_current("failed", &hit));
}

#[test]
fn a_match_continues_across_a_soft_wrap() {
    let mut t = Terminal::new(5, 3);
    t.feed(b"abcdefgh");
    let hits = all(&t, "defg");
    assert_eq!(hits.len(), 1);
    let h = &hits[0];
    assert_eq!((h.start_col, h.end_col), (3, 1));
    assert_eq!(h.end_line, h.start_line + 1);
    assert_eq!(line(h), "abcdefgh");
    assert!(t.active_grid().search_hit_is_current("defg", h));
}

#[test]
fn cyrillic_wide_characters_and_combining_marks_land_on_their_cells() {
    let mut t = Terminal::new(20, 2);
    // "Ошибка" folds to "ошибка"; 漢 takes two columns; é is e + U+0301.
    t.feed("Ошибка 漢字 cafe\u{301}".as_bytes());
    let cyr = all(&t, "ошибка").remove(0);
    assert_eq!((cyr.start_col, cyr.end_col), (0, 5));
    let wide = all(&t, "字").remove(0);
    // 漢 is columns 7-8, 字 9-10.
    assert_eq!((wide.start_col, wide.end_col), (9, 10));
    let mark = all(&t, "e\u{301}").remove(0);
    assert_eq!((mark.start_col, mark.end_col), (15, 15));
    // A base letter alone does not match a cell that also holds a mark.
    assert!(all(&t, "cafe ").is_empty());
}

#[test]
fn steps_cover_everything_once_and_say_where_to_go_on() {
    let mut t = Terminal::with_scrollback(10, 2, 100);
    for i in 0..40 {
        t.feed(format!("x{i}\r\n").as_bytes());
    }
    let grid = t.active_grid();
    let whole = all(&t, "x");
    let mut stepped = Vec::new();
    let mut before = None;
    loop {
        let chunk = grid.search_chunk("x", before, 7, usize::MAX);
        stepped.extend(chunk.hits);
        match chunk.next_before {
            Some(next) => before = Some(next),
            None => break,
        }
    }
    assert_eq!(stepped, whole);
    assert_eq!(whole.len(), 40);
}

#[test]
fn the_limit_is_reported_only_when_more_were_found() {
    let mut t = Terminal::new(20, 3);
    t.feed(b"aa\r\naa");
    let grid = t.active_grid();
    let exact = grid.search_chunk("a", None, usize::MAX, 4);
    assert_eq!(exact.hits.len(), 4);
    assert!(!exact.truncated);
    let short = grid.search_chunk("a", None, usize::MAX, 3);
    assert_eq!(short.hits.len(), 3);
    assert!(short.truncated);
}

#[test]
fn a_wrapped_line_is_not_split_between_steps() {
    // "abcdefgh" wraps over two rows; a blank row below takes one row of a
    // two-row step, so the line must wait for the next step whole.
    let mut t = Terminal::new(5, 3);
    t.feed(b"abcdefgh");
    let grid = t.active_grid();
    let mut found = Vec::new();
    let mut before = None;
    loop {
        let chunk = grid.search_chunk("defg", before, 2, usize::MAX);
        found.extend(chunk.hits);
        match chunk.next_before {
            Some(next) => before = Some(next),
            None => break,
        }
    }
    assert_eq!(found.len(), 1);
}

#[test]
fn a_hit_across_a_wrap_that_became_a_line_break_is_stale() {
    let mut t = Terminal::new(5, 3);
    t.feed(b"abcdefgh");
    let hit = all(&t, "defg").remove(0);
    t.feed(b"\x1b[2J\x1b[Habcde\r\nfgh");
    assert!(all(&t, "defg").is_empty());
    assert!(!t.active_grid().search_hit_is_current("defg", &hit));
}

#[test]
fn an_empty_needle_finds_nothing() {
    let mut t = Terminal::new(10, 2);
    t.feed(b"abc");
    assert!(all(&t, "").is_empty());
}

#[test]
fn each_hit_carries_its_own_place_in_the_line() {
    let mut t = Terminal::new(40, 2);
    t.feed(b"foo bar foo");
    let hits = all(&t, "foo");
    assert_eq!(hits.len(), 2);
    assert_eq!((hits[0].before.as_str(), hits[0].after.as_str()), ("foo bar ", ""));
    assert_eq!((hits[1].before.as_str(), hits[1].after.as_str()), ("", " bar foo"));
}

#[test]
fn a_huge_line_costs_only_what_was_asked_for() {
    // One logical line of 100,000 'a': a step must neither collect every
    // occurrence nor copy the line for each.
    let mut t = Terminal::with_scrollback(100, 5, 2_000);
    t.feed("a".repeat(100_000).as_bytes());
    let grid = t.active_grid();
    let started = std::time::Instant::now();
    let chunk = grid.search_chunk("a", None, 50, 3);
    assert_eq!(chunk.hits.len(), 3);
    assert!(chunk.truncated);
    assert!(chunk.hits.iter().all(|h| h.before.chars().count() <= 40 && h.after.chars().count() <= 80));
    assert!(started.elapsed() < std::time::Duration::from_millis(200), "{:?}", started.elapsed());
}

#[test]
fn a_step_reads_no_more_rows_than_allowed() {
    // A wrapped line of 1,000 rows, searched 10 rows at a time.
    let mut t = Terminal::with_scrollback(10, 5, 2_000);
    t.feed("x".repeat(10_000).as_bytes());
    let grid = t.active_grid();
    let end = grid.end_retained_line();
    let chunk = grid.search_chunk("nothing", None, 10, 5);
    assert_eq!(chunk.next_before, Some(end - 10));
}

#[test]
fn checking_a_hit_reads_only_its_rows_and_its_cells() {
    let mut t = Terminal::new(20, 3);
    t.feed(b"abc abc");
    let hits = all(&t, "abc");
    // Changing text next to the hit does not make it stale; changing its
    // cells does.
    t.feed(b"\x1b[1;4HX");
    assert!(t.active_grid().search_hit_is_current("abc", &hits[0]));
    t.feed(b"\x1b[1;5HZ");
    assert!(!t.active_grid().search_hit_is_current("abc", &hits[0]));
}
