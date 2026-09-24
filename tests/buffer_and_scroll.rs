// What a phone host needs from the engine that a desktop one never asked for.
//
// Two things, and both exist because the surface is detachable. A mobile view
// is torn down and rebuilt whenever the OS feels like it, so the host copies
// the whole buffer out as text and restores a scroll position it stored
// earlier. Neither survives being expressed in viewport coordinates: the
// viewport is the part you can see, and the part you can see is not the part
// you are copying or the place you were.

use tako_core::terminal::Terminal;

fn filled(cols: usize, rows: usize, lines: usize) -> Terminal {
    let mut t = Terminal::new(cols, rows);
    for i in 0..lines {
        t.feed(format!("line{i}\r\n").as_bytes());
    }
    let _ = t.take_output();
    t
}

// ── Buffer text ──────────────────────────────────────────────────────────────

#[test]
fn buffer_text_includes_scrollback_not_just_the_screen() {
    // 6 rows on screen, 50 lines written: 44 of them are only in scrollback.
    let t = filled(40, 6, 50);
    let text = t.buffer_text();

    assert!(text.contains("line0"), "the oldest line is missing: copy lost history");
    assert!(text.contains("line49"), "the newest line is missing");
    let seen = (0..50).filter(|i| text.contains(&format!("line{i}\n"))).count();
    assert_eq!(seen, 50, "not every line survived");
}

#[test]
fn buffer_text_of_a_short_session_is_just_its_lines() {
    let t = filled(40, 10, 3);

    let text = t.buffer_text();
    let lines: Vec<&str> = text.lines().filter(|l| !l.is_empty()).collect();
    assert_eq!(lines, vec!["line0", "line1", "line2"]);
}

#[test]
fn buffer_text_rejoins_a_soft_wrapped_line() {
    // Narrow enough that this wraps; whoever pastes it wants one line.
    let mut t = Terminal::new(20, 6);
    t.feed(b"this line is definitely longer than twenty\r\n");
    let _ = t.take_output();

    let first = t.buffer_text().lines().next().unwrap_or_default().to_string();
    assert_eq!(first, "this line is definitely longer than twenty");
}

#[test]
fn buffer_text_keeps_a_hard_newline_a_newline() {
    let mut t = Terminal::new(40, 6);
    t.feed(b"alpha\r\nbeta\r\n");
    let _ = t.take_output();

    let text = t.buffer_text();
    let lines: Vec<&str> = text.lines().filter(|l| !l.is_empty()).collect();
    assert_eq!(lines, vec!["alpha", "beta"]);
}

#[test]
fn buffer_text_counts_a_wide_glyph_once() {
    let mut t = Terminal::new(20, 4);
    t.feed("\u{4e16}\u{754c}\r\n".as_bytes());
    let _ = t.take_output();

    let text = t.buffer_text();
    assert_eq!(text.lines().next().unwrap(), "\u{4e16}\u{754c}");
}

#[test]
fn buffer_text_of_an_untouched_terminal_is_blank_lines_only() {
    let t = Terminal::new(20, 4);

    assert!(t.buffer_text().trim().is_empty());
}

// ── Scroll position ──────────────────────────────────────────────────────────

#[test]
fn a_fresh_terminal_is_at_the_tail() {
    let t = filled(40, 6, 50);

    assert_eq!(t.scroll_position(), 1.0);
}

#[test]
fn with_no_scrollback_there_is_nowhere_to_be_but_the_tail() {
    let t = Terminal::new(40, 6);

    assert_eq!(t.scroll_position(), 1.0);
}

#[test]
fn scrolling_all_the_way_back_is_zero() {
    let mut t = filled(40, 6, 50);
    t.scroll_viewport_up(100_000);

    assert_eq!(t.scroll_position(), 0.0);
}

#[test]
fn a_position_survives_a_round_trip() {
    let mut t = filled(40, 6, 60);
    t.scroll_viewport_up(20);
    let saved = t.scroll_position();
    assert!(saved > 0.0 && saved < 1.0, "expected a mid-buffer position, got {saved}");

    t.scroll_viewport_bottom();
    assert_eq!(t.scroll_position(), 1.0);

    t.set_scroll_position(saved);
    assert_eq!(t.viewport_offset(), 20, "restoring landed on a different line");
}

#[test]
fn restoring_shows_the_same_text_it_was_saved_on() {
    // The assertion that matters: a host stores a fraction, the view is torn
    // down and rebuilt, and the user is looking at what they were looking at.
    let mut t = filled(40, 6, 60);
    t.scroll_viewport_up(25);
    let saved = t.scroll_position();
    let before: Vec<String> = (0..6)
        .map(|r| {
            t.viewport_row(r)
                .iter()
                .map(|c| if c.char == '\0' { ' ' } else { c.char })
                .collect::<String>()
                .trim_end()
                .to_string()
        })
        .collect();

    t.scroll_viewport_bottom();
    t.set_scroll_position(saved);

    let after: Vec<String> = (0..6)
        .map(|r| {
            t.viewport_row(r)
                .iter()
                .map(|c| if c.char == '\0' { ' ' } else { c.char })
                .collect::<String>()
                .trim_end()
                .to_string()
        })
        .collect();
    assert_eq!(after, before);
}

#[test]
fn a_position_outside_the_range_is_clamped_not_rejected() {
    let mut t = filled(40, 6, 50);

    t.set_scroll_position(-5.0);
    assert_eq!(t.scroll_position(), 0.0);

    t.set_scroll_position(9.0);
    assert_eq!(t.scroll_position(), 1.0);
}

#[test]
fn restoring_on_a_terminal_with_no_scrollback_is_harmless() {
    let mut t = Terminal::new(40, 6);

    t.set_scroll_position(0.3);

    assert_eq!(t.viewport_offset(), 0);
    assert_eq!(t.scroll_position(), 1.0);
}

/// Scrollback is evicted as a session runs, so a stored fraction points at a
/// different line later. That is the deliberate trade -- a stored line number
/// would point at the wrong line *and* be out of range -- and it still has to
/// land somewhere valid.
#[test]
fn a_position_stored_before_eviction_still_lands_in_range() {
    let mut t = filled(40, 6, 60);
    t.scroll_viewport_up(30);
    let saved = t.scroll_position();

    for i in 0..5000 {
        t.feed(format!("later{i}\r\n").as_bytes());
    }
    let _ = t.take_output();

    t.set_scroll_position(saved);
    assert!(t.viewport_offset() <= t.active_grid().scrollback_len());
    let _ = t.viewport_row(0);
}
