//! Content printed before the first resize has to survive it.
//!
//! A session opens at the size the PTY was requested with and is resized to
//! what the view actually draws at a moment later, so everything a host says
//! on login -- the banner, the MOTD, the first prompt -- arrives at the old
//! width and has to be rewrapped rather than dropped.

use tako_core::terminal::Terminal;

#[test]
fn narrowing_keeps_what_was_printed() {
    let mut t = Terminal::new(80, 24);
    t.feed(b"PTY xterm-256color 80x24\r\nAUTH password\r\nTYPE SOMETHING\r\n");
    assert!(t.dump_text().contains("AUTH password"), "sanity: text is there at 80 cols");

    t.resize(47, 24);
    let after = t.dump_text();
    assert!(after.contains("AUTH password"), "narrowing lost the text:\n{after}");
    assert!(after.contains("TYPE SOMETHING"), "narrowing lost the text:\n{after}");
}

#[test]
fn keyboard_height_shrink_keeps_the_login_banner_on_screen() {
    // What the app actually does: the PTY is requested at 80x24, the view
    // first lays out at its full height, and autofocus then raises the software
    // keyboard and makes the terminal shorter. Everything the host said on
    // login arrives before either resize. The old regression test had the last
    // two sizes backwards, so it never exercised the failing row shrink.
    let mut t = Terminal::new(80, 24);
    t.feed(b"PTY xterm-256color 80x24\r\nAUTH password\r\nTYPE SOMETHING\r\n");
    t.resize(47, 41);
    t.resize(47, 24);

    let screen = t.dump_text();
    assert!(
        screen.contains("AUTH password"),
        "the login banner is no longer on screen after the resizes:\n{screen}"
    );
}

#[test]
fn orientation_round_trip_restores_rows_archived_by_a_transient_height() {
    // UIKit can hold an intermediate geometry long enough for the debounced
    // resize to apply: landscape width, but only one drawable terminal row.
    // The top two banner rows become history while the prompt remains active.
    // Growing the active area again must pull those adjacent history rows back
    // down, like upstream, instead of leaving a mostly blank screen containing
    // only the prompt.
    let mut t = Terminal::new(91, 7);
    t.feed(b"workspace - fixture pty ready\r\nUnicode OK\r\n$ ");

    t.resize(91, 1);
    assert!(t.buffer_text().contains("fixture pty ready"));
    assert!(!t.dump_text().contains("fixture pty ready"));

    t.resize(49, 17);
    let screen = t.dump_text();
    assert!(
        screen.contains("fixture pty ready"),
        "restored portrait left the banner in scrollback:\n{screen}"
    );
    assert!(screen.contains("Unicode OK"), "restored portrait lost row two:\n{screen}");
    assert!(screen.contains("$"), "restored portrait lost the prompt:\n{screen}");
    assert_eq!(t.cursor().0, 2, "cursor did not follow the restored prompt row");
}

#[test]
fn growing_while_alternate_is_active_does_not_pull_primary_history() {
    let mut t = Terminal::new(3, 4);
    t.feed(b"a\r\nb\r\nc\r\nd");
    t.resize(3, 2);
    assert_eq!(t.active_grid().scrollback_len(), 2);
    assert_eq!(t.dump_text(), "c\nd");

    t.feed(b"\x1b[?1049h");
    t.resize(3, 4);
    t.feed(b"\x1b[?1049l");

    assert_eq!(t.active_grid().scrollback_len(), 2);
    assert_eq!(t.dump_text(), "c\nd\n\n");
    assert!(t.buffer_text().contains("a\nb\nc\nd"));
}
