// How much history the terminal keeps, set by the host (the app's
// scrollback-limit) after the terminal exists.

use tako_core::ffi::TakoCore;
use tako_core::terminal::Terminal;

fn lines(n: usize) -> Vec<u8> {
    (0..n).map(|i| format!("line {i}\r\n")).collect::<String>().into_bytes()
}

fn oldest_retained(t: &Terminal) -> String {
    let grid = t.active_grid();
    let line = grid.scrollback_line(grid.scrollback_len() - 1).unwrap();
    line.iter().map(|c| c.char).collect::<String>().trim_end_matches(['\0', ' ']).to_string()
}

#[test]
fn shrinking_the_limit_keeps_the_newest_history() {
    let mut t = Terminal::new(10, 4);
    t.feed(&lines(50));
    assert!(t.active_grid().scrollback_len() > 10);

    t.set_scrollback_capacity(10);

    assert_eq!(t.active_grid().scrollback_len(), 10);
    assert_eq!(t.active_grid().scrollback_capacity(), 10);
    // 50 lines and an empty prompt row: rows 47..50 are on screen, so the
    // ten newest history lines are 37..46.
    assert_eq!(oldest_retained(&t), "line 37");
}

#[test]
fn growing_the_limit_lets_more_history_accumulate() {
    let mut t = Terminal::with_scrollback(10, 4, 5);
    t.feed(&lines(20));
    assert_eq!(t.active_grid().scrollback_len(), 5);

    t.set_scrollback_capacity(100);
    t.feed(&lines(20));

    assert_eq!(t.active_grid().scrollback_len(), 25);
}

#[test]
fn a_limit_of_zero_keeps_no_history() {
    let mut t = Terminal::new(10, 4);
    t.feed(&lines(20));
    t.set_scrollback_capacity(0);
    t.feed(&lines(20));
    assert_eq!(t.active_grid().scrollback_len(), 0);
}

#[test]
fn a_viewport_scrolled_past_the_new_limit_moves_to_the_oldest_line_left() {
    let mut t = Terminal::new(10, 4);
    t.feed(&lines(50));
    t.scroll_viewport_up(40);
    assert_eq!(t.viewport_offset(), 40);

    t.set_scrollback_capacity(10);

    assert_eq!(t.viewport_offset(), 10);
}

#[test]
fn the_ffi_sets_the_limit_too() {
    let core = TakoCore::new(10, 4);
    core.feed(lines(50));
    core.set_scrollback_limit(3);
    core.feed(lines(10));
    assert!(core.buffer_text().lines().filter(|l| l.starts_with("line")).count() <= 3 + 4);
}
