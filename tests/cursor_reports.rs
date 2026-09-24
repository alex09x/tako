// DSR — cursor position reports.
//
// A program that asks where the cursor is has no other way to find out, so a
// wrong answer here is not cosmetic: it is what shell line editors and TUI
// layout code build their idea of the screen on. ucs-detect measures every
// character width through this sequence.
//
// The origin-mode cases below came out of esctest, which crashed the engine
// on the first one.

use tako_core::terminal::Terminal;

/// Feeds `data` and returns the reply as text.
fn reply(term: &mut Terminal, data: &str) -> String {
    let _ = term.take_output();
    term.feed(data.as_bytes());
    String::from_utf8(term.take_output()).expect("reply is not utf-8")
}

fn feed(term: &mut Terminal, data: &str) {
    term.feed(data.as_bytes());
    let _ = term.take_output();
}

#[test]
fn reports_the_cursor_position_one_based() {
    let mut t = Terminal::new(80, 24);
    feed(&mut t, "\x1b[5;10H");

    assert_eq!(reply(&mut t, "\x1b[6n"), "\x1b[5;10R");
}

#[test]
fn reports_the_home_position_of_a_fresh_screen() {
    let mut t = Terminal::new(80, 24);

    assert_eq!(reply(&mut t, "\x1b[6n"), "\x1b[1;1R");
}

#[test]
fn device_status_reports_ok() {
    let mut t = Terminal::new(80, 24);

    assert_eq!(reply(&mut t, "\x1b[5n"), "\x1b[0n");
}

// ── Origin mode ──────────────────────────────────────────────────────────────

#[test]
fn origin_mode_reports_relative_to_the_scroll_region() {
    let mut t = Terminal::new(80, 24);
    feed(&mut t, "\x1b[5;20r"); // region rows 5..20
    feed(&mut t, "\x1b[?6h"); // origin mode
    feed(&mut t, "\x1b[3;1H"); // third row *of the region* = screen row 7

    assert_eq!(reply(&mut t, "\x1b[6n"), "\x1b[3;1R");
}

/// Found by esctest: the engine subtracted the top margin from the cursor row
/// without checking it was below it, so a cursor sitting above the region
/// underflowed. In a debug build that panicked; in the shipping release build
/// it wrapped silently and reported a nonsense position, which is worse.
///
/// The cursor gets there whenever origin mode is turned on after it was
/// positioned, because enabling DECOM does not move it.
#[test]
fn a_cursor_above_the_scroll_region_still_reports_a_valid_position() {
    let mut t = Terminal::new(80, 24);
    feed(&mut t, "\x1b[5;20r"); // region starts at row 5
    feed(&mut t, "\x1b[1;1H"); // cursor at row 1, above the region
    feed(&mut t, "\x1b[?6h"); // now switch to region-relative reporting

    let answer = reply(&mut t, "\x1b[6n");
    assert_eq!(answer, "\x1b[1;1R", "expected a clamped 1-based report");
}

/// The same underflow on the horizontal axis, reached through left/right
/// margins rather than the scroll region.
#[test]
fn a_cursor_left_of_the_margin_still_reports_a_valid_position() {
    let mut t = Terminal::new(80, 24);
    feed(&mut t, "\x1b[?69h"); // enable left/right margins
    feed(&mut t, "\x1b[10;40s"); // margins at columns 10..40
    feed(&mut t, "\x1b[1;1H"); // cursor at column 1, left of the margin
    feed(&mut t, "\x1b[?6h");

    let answer = reply(&mut t, "\x1b[6n");
    assert!(
        answer.ends_with("R") && !answer.contains("65535"),
        "underflowed instead of clamping: {answer:?}"
    );
}

#[test]
fn leaving_origin_mode_reports_absolute_coordinates_again() {
    let mut t = Terminal::new(80, 24);
    feed(&mut t, "\x1b[5;20r");
    feed(&mut t, "\x1b[?6h");
    feed(&mut t, "\x1b[3;1H"); // third row of the region
    feed(&mut t, "\x1b[?6l"); // back to absolute, which re-homes
    feed(&mut t, "\x1b[7;1H"); // now address the screen directly

    assert_eq!(reply(&mut t, "\x1b[6n"), "\x1b[7;1R");
}

/// Changing DECOM changes what every cursor address means, so the cursor is
/// moved to the origin of whichever system now applies rather than left
/// holding a coordinate that has quietly been reinterpreted. xterm does the
/// same; we used to only flip the flag.
#[test]
fn entering_origin_mode_homes_the_cursor_into_the_region() {
    let mut t = Terminal::new(80, 24);
    feed(&mut t, "\x1b[5;20r"); // region rows 5..20
    feed(&mut t, "\x1b[12;40H"); // somewhere in the middle
    feed(&mut t, "\x1b[?6h");

    // Region-relative 1;1, which is screen row 5.
    assert_eq!(reply(&mut t, "\x1b[6n"), "\x1b[1;1R");
    feed(&mut t, "\x1b[?6l");
    assert_eq!(reply(&mut t, "\x1b[6n"), "\x1b[1;1R", "leaving homes too");
}

#[test]
fn homing_on_origin_mode_respects_left_and_right_margins() {
    let mut t = Terminal::new(80, 24);
    feed(&mut t, "\x1b[5;20r");
    feed(&mut t, "\x1b[?69h\x1b[10;40s"); // left margin at column 10
    feed(&mut t, "\x1b[12;30H");
    feed(&mut t, "\x1b[?6h");

    // The report is region-relative, so the move is only visible on screen:
    // the character lands at the region's corner, row 5 and column 10.
    assert_eq!(reply(&mut t, "\x1b[6n"), "\x1b[1;1R");
    feed(&mut t, "X");

    let row = t.dump_text().lines().nth(4).unwrap_or_default().to_string();
    assert_eq!(row.find('X'), Some(9), "landed at the wrong column: {row:?}");
}

#[test]
fn leaving_origin_mode_homes_to_the_screen_not_the_region() {
    let mut t = Terminal::new(80, 24);
    feed(&mut t, "\x1b[5;20r");
    feed(&mut t, "\x1b[?6h");
    feed(&mut t, "\x1b[3;5H"); // inside the region
    feed(&mut t, "\x1b[?6l");

    // Origin mode is off, so home means the screen's top-left, not the one
    // the cursor was addressed against a moment ago.
    assert_eq!(reply(&mut t, "\x1b[6n"), "\x1b[1;1R");
}

// ── DECDSR, the private status reports ───────────────────────────────────────
//
// These ask about hardware a VT had and an emulator does not. The values
// matter less than the fact of answering: a program that sends one and gets
// nothing back blocks on the read rather than falling back. esctest caught
// all eleven of these as "Timeout waiting to read".

#[test]
fn private_operating_status_is_answered() {
    let mut t = Terminal::new(80, 24);

    assert_eq!(reply(&mut t, "\x1b[?5n"), "\x1b[?0n");
}

#[test]
fn extended_cursor_position_uses_the_private_prefix() {
    let mut t = Terminal::new(80, 24);
    feed(&mut t, "\x1b[5;6H");

    assert_eq!(reply(&mut t, "\x1b[?6n"), "\x1b[?5;6R");
}

#[test]
fn extended_cursor_position_respects_origin_mode() {
    let mut t = Terminal::new(80, 24);
    feed(&mut t, "\x1b[5;20r");
    feed(&mut t, "\x1b[?6h");
    feed(&mut t, "\x1b[3;1H");

    assert_eq!(reply(&mut t, "\x1b[?6n"), "\x1b[?3;1R");
}

#[test]
fn absent_hardware_reports_itself_absent() {
    for (query, expected, what) in [
        ("\x1b[?15n", "\x1b[?13n", "printer: none detected"),
        ("\x1b[?25n", "\x1b[?20n", "user-defined keys: unlocked"),
        ("\x1b[?26n", "\x1b[?27;1n", "keyboard: North American"),
        ("\x1b[?55n", "\x1b[?53n", "locator: none"),
        ("\x1b[?56n", "\x1b[?57;0n", "locator type: unknown"),
        ("\x1b[?62n", "\x1b[0000*{", "macro space: none"),
        ("\x1b[?75n", "\x1b[?70n", "link integrity: no errors"),
        ("\x1b[?85n", "\x1b[?83n", "sessions: not configured"),
    ] {
        let mut t = Terminal::new(80, 24);
        assert_eq!(reply(&mut t, query), expected, "{what}");
    }
}

#[test]
fn the_macro_checksum_echoes_its_request_id() {
    let mut t = Terminal::new(80, 24);

    // Same reply shape as DECRQCRA; with no macro memory there is nothing to
    // checksum, so the value is always zero.
    assert_eq!(reply(&mut t, "\x1b[?63;123n"), "\x1bP123!~0000\x1b\\");
}

#[test]
fn an_unknown_private_report_stays_silent() {
    let mut t = Terminal::new(80, 24);

    // Answering something we do not understand would be worse than silence:
    // the client would parse a reply it did not ask for.
    assert_eq!(reply(&mut t, "\x1b[?9999n"), "");
}

#[test]
fn a_status_query_does_not_disturb_the_cursor() {
    let mut t = Terminal::new(80, 24);
    feed(&mut t, "\x1b[7;9H");
    for query in ["\x1b[?15n", "\x1b[?26n", "\x1b[?62n", "\x1b[?63;1n"] {
        let _ = reply(&mut t, query);
    }

    assert_eq!(reply(&mut t, "\x1b[6n"), "\x1b[7;9R");
}
