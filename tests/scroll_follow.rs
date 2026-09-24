// Where the viewport goes when output arrives.
//
// Scrolling back to read something and having the next line of output yank
// you to the bottom makes scrollback useless next to anything that keeps
// writing -- `tail -f`, a build, a test run. The rule every modern terminal
// follows is: output leaves your position alone, your own keystrokes bring
// you back. xterm's `scrollTtyOutput` defaults the other way, which is where
// the habit of doing this came from, and it is a habit worth dropping.
//
// Staying put is not the same as doing nothing. The viewport is anchored to
// the live screen, so when a line is pushed into scrollback the offset has to
// grow by one just to keep showing the same text. Leaving it alone lets the
// content slide upward under a stationary window, which looks exactly like
// following the tail.

use tako_core::terminal::Terminal;

fn row_text(t: &Terminal, row: usize) -> String {
    t.viewport_row(row)
        .iter()
        .map(|c| if c.char == '\0' { ' ' } else { c.char })
        .collect::<String>()
        .trim_end()
        .to_string()
}

/// Fills the scrollback with numbered lines, then scrolls back.
fn scrolled_back(lines: usize, back: usize) -> Terminal {
    let mut t = Terminal::new(40, 6);
    for i in 0..lines {
        t.feed(format!("line{i}\r\n").as_bytes());
    }
    let _ = t.take_output();
    t.scroll_viewport_up(back);
    t
}

#[test]
fn output_does_not_drag_the_viewport_to_the_bottom() {
    let mut t = scrolled_back(50, 20);
    assert_eq!(t.viewport_offset(), 20);
    let before = row_text(&t, 0);

    // Something is still writing, the way `tail -f` does.
    t.feed(b"new output\r\n");
    let _ = t.take_output();

    assert_ne!(t.viewport_offset(), 0, "output snapped the view to the bottom");
    assert_eq!(row_text(&t, 0), before, "the visible text moved under us");
}

#[test]
fn many_lines_of_output_still_leave_the_view_where_it_was() {
    let mut t = scrolled_back(50, 20);
    let before: Vec<String> = (0..6).map(|r| row_text(&t, r)).collect();

    for i in 0..30 {
        t.feed(format!("noise{i}\r\n").as_bytes());
    }
    let _ = t.take_output();

    let after: Vec<String> = (0..6).map(|r| row_text(&t, r)).collect();
    assert_eq!(after, before, "30 lines of output scrolled the view");
}

#[test]
fn output_while_at_the_bottom_still_follows() {
    // The other half of the rule: someone who has not scrolled back is
    // watching the live screen and must keep seeing new output.
    let mut t = Terminal::new(40, 6);
    for i in 0..20 {
        t.feed(format!("line{i}\r\n").as_bytes());
    }
    let _ = t.take_output();
    assert_eq!(t.viewport_offset(), 0);

    t.feed(b"newest\r\n");
    let _ = t.take_output();

    assert_eq!(t.viewport_offset(), 0);
    let screen: Vec<String> = (0..6).map(|r| row_text(&t, r)).collect();
    assert!(
        screen.iter().any(|l| l == "newest"),
        "new output is not on the live screen: {screen:?}"
    );
}

#[test]
fn snapping_to_the_bottom_still_works_on_demand() {
    // What a keystroke does, and what the host calls when the user types.
    let mut t = scrolled_back(50, 20);
    assert_ne!(t.viewport_offset(), 0);

    t.scroll_viewport_bottom();

    assert_eq!(t.viewport_offset(), 0);
}

#[test]
fn scrolling_back_past_the_oldest_line_clamps() {
    let mut t = scrolled_back(50, 10_000);
    let max = t.viewport_offset();
    assert!(max > 0 && max < 10_000, "offset was not clamped: {max}");

    // And more output must not push it past the end either.
    for i in 0..10 {
        t.feed(format!("more{i}\r\n").as_bytes());
    }
    let _ = t.take_output();
    assert!(t.viewport_offset() > 0);
    // Row 0 is still readable rather than blank-or-panicking.
    let _ = row_text(&t, 0);
}

#[test]
fn a_scrolled_view_still_reaches_the_bottom_by_scrolling_down() {
    let mut t = scrolled_back(50, 20);
    t.feed(b"tail output\r\n");
    let _ = t.take_output();

    t.scroll_viewport_down(10_000);

    assert_eq!(t.viewport_offset(), 0);
    let screen: Vec<String> = (0..6).map(|r| row_text(&t, r)).collect();
    assert!(
        screen.iter().any(|l| l == "tail output"),
        "the newest line is not visible after scrolling back down: {screen:?}"
    );
}

/// The alternate screen has no scrollback, so a viewport offset left over
/// from the primary screen points at nothing there.
///
/// This used to be hidden: the old code reset the offset on every printed
/// character, so entering the alternate screen and drawing anything cleared
/// it as a side effect. With output no longer touching the viewport, the
/// switch has to do it itself -- otherwise scrolling back and then starting
/// vim or codex leaves the app drawing into a window scrolled off its own
/// screen.
#[test]
fn switching_to_the_alternate_screen_returns_to_the_live_view() {
    let mut t = scrolled_back(50, 20);
    assert_ne!(t.viewport_offset(), 0);

    t.feed(b"\x1b[?1049h"); // an app takes the alternate screen
    let _ = t.take_output();

    assert_eq!(t.viewport_offset(), 0, "alt screen inherited a scrollback offset");
}

#[test]
fn leaving_the_alternate_screen_returns_to_the_live_view() {
    let mut t = scrolled_back(50, 20);
    t.feed(b"\x1b[?1049h");
    t.feed(b"\x1b[?1049l");
    let _ = t.take_output();

    assert_eq!(t.viewport_offset(), 0);
}

#[test]
fn drawing_on_the_alternate_screen_shows_what_was_drawn() {
    // The symptom the reset prevents: an app's own output has to be visible.
    let mut t = scrolled_back(50, 20);
    t.feed(b"\x1b[?1049h\x1b[2J\x1b[H");
    t.feed(b"EDITOR");
    let _ = t.take_output();

    assert_eq!(row_text(&t, 0), "EDITOR");
}
