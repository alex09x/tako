// DECRQCRA — Request Checksum of Rectangular Area.
//
// This is the sequence esctest reads the screen through, so getting it wrong
// does not fail loudly: it makes about a thousand borrowed tests assert
// against garbage. The expected values below are computed by hand from
// xterm's algorithm rather than captured from our own output, so they check
// the implementation instead of recording it.
//
// The algorithm, from xterm's xtermCheckRect:
//   * cells never written (NUL) are skipped entirely
//   * attributes are added to the character value:
//     protected +0x04, hidden +0x08, underline +0x10,
//     reverse +0x20, blink +0x40, bold +0x80
//   * a cell whose adjusted value is exactly ' ' is dropped, unless it is
//     the first counted cell of the rectangle
//   * the total is negated and reduced to 16 bits

use tako_core::terminal::Terminal;

/// Feeds `data`, then the query, and returns the four hex digits of the reply.
fn checksum(term: &mut Terminal, query: &str) -> String {
    let _ = term.take_output();
    term.feed(query.as_bytes());
    let out = String::from_utf8(term.take_output()).expect("reply is not utf-8");

    let body = out
        .strip_prefix('\x1b')
        .and_then(|s| s.strip_prefix('P'))
        .unwrap_or_else(|| panic!("reply is not a DCS: {out:?}"));
    let (head, _) = body
        .split_once("\x1b\\")
        .unwrap_or_else(|| panic!("reply is unterminated: {out:?}"));
    let (_, digits) = head
        .split_once("!~")
        .unwrap_or_else(|| panic!("reply lacks the !~ delimiter: {out:?}"));
    digits.to_string()
}

fn feed(term: &mut Terminal, data: &str) {
    term.feed(data.as_bytes());
    let _ = term.take_output();
}

/// The whole reply, for the tests that care about its shape.
fn raw_reply(term: &mut Terminal, query: &str) -> String {
    let _ = term.take_output();
    term.feed(query.as_bytes());
    String::from_utf8(term.take_output()).expect("reply is not utf-8")
}

// ── Wire format ──────────────────────────────────────────────────────────────

#[test]
fn reply_is_a_dcs_carrying_the_request_id_and_four_hex_digits() {
    let mut t = Terminal::new(10, 2);
    feed(&mut t, "AB");

    assert_eq!(raw_reply(&mut t, "\x1b[42;0;1;1;2;10*y"), "\x1bP42!~FF7D\x1b\\");
}

#[test]
fn a_missing_request_id_is_reported_as_zero() {
    let mut t = Terminal::new(10, 2);

    assert_eq!(raw_reply(&mut t, "\x1b[*y"), "\x1bP0!~0000\x1b\\");
}

#[test]
fn digits_are_uppercase_and_zero_padded() {
    let mut t = Terminal::new(10, 2);
    feed(&mut t, "A"); // 0x41 -> -0x41 -> 0xFFBF

    let digits = checksum(&mut t, "\x1b[1;0;1;1;2;10*y");
    assert_eq!(digits, "FFBF");
    assert_eq!(digits.len(), 4);
}

// ── The sum itself ───────────────────────────────────────────────────────────

#[test]
fn an_untouched_screen_checksums_to_zero() {
    // Every cell is NUL, so every cell is skipped: nothing is summed, and
    // negating nothing is still nothing.
    let mut t = Terminal::new(20, 5);

    assert_eq!(checksum(&mut t, "\x1b[1;0;1;1;5;20*y"), "0000");
}

#[test]
fn printable_text_sums_its_code_points_and_negates_the_result() {
    let mut t = Terminal::new(10, 2);
    feed(&mut t, "AB"); // 0x41 + 0x42 = 0x83; -0x83 = 0xFF7D

    assert_eq!(checksum(&mut t, "\x1b[1;0;1;1;2;10*y"), "FF7D");
}

#[test]
fn each_attribute_adds_its_documented_weight() {
    // 'A' is 0x41 throughout; only the attribute changes.
    for (sgr, weight) in [
        ("\x1b[4m", 0x10u32),  // underline
        ("\x1b[7m", 0x20),     // reverse
        ("\x1b[5m", 0x40),     // blink
        ("\x1b[1m", 0x80),     // bold
        ("\x1b[8m", 0x08),     // hidden
    ] {
        let mut t = Terminal::new(10, 2);
        feed(&mut t, &format!("{sgr}A\x1b[m"));

        let expected = format!("{:04X}", (0x41u32 + weight).wrapping_neg() & 0xffff);
        assert_eq!(
            checksum(&mut t, "\x1b[1;0;1;1;2;10*y"),
            expected,
            "attribute {sgr:?} did not add {weight:#x}"
        );
    }
}

#[test]
fn a_protected_cell_adds_four() {
    let mut t = Terminal::new(10, 2);
    feed(&mut t, "\x1b[1\"qA\x1b[0\"q"); // DECSCA on, 'A', off

    let expected = format!("{:04X}", (0x41u32 + 0x4).wrapping_neg() & 0xffff);
    assert_eq!(checksum(&mut t, "\x1b[1;0;1;1;2;10*y"), expected);
}

#[test]
fn attributes_combine_additively() {
    let mut t = Terminal::new(10, 2);
    feed(&mut t, "\x1b[1;4;5mA\x1b[m"); // bold + underline + blink

    let expected = format!(
        "{:04X}",
        (0x41u32 + 0x80 + 0x10 + 0x40).wrapping_neg() & 0xffff
    );
    assert_eq!(checksum(&mut t, "\x1b[1;0;1;1;2;10*y"), expected);
}

// ── Trimming ─────────────────────────────────────────────────────────────────

#[test]
fn plain_spaces_are_dropped_from_the_sum() {
    // "A B" checksums identically to "AB": a written space contributes
    // nothing once something has already been counted.
    let mut spaced = Terminal::new(10, 2);
    feed(&mut spaced, "A B");

    let mut tight = Terminal::new(10, 2);
    feed(&mut tight, "AB");

    assert_eq!(
        checksum(&mut spaced, "\x1b[1;0;1;1;2;10*y"),
        checksum(&mut tight, "\x1b[1;0;1;1;2;10*y")
    );
}

#[test]
fn a_leading_space_still_counts() {
    // The first counted cell is never trimmed, so this is 0x20 + 0x41.
    let mut t = Terminal::new(10, 2);
    feed(&mut t, " A");

    let expected = format!("{:04X}", (0x20u32 + 0x41).wrapping_neg() & 0xffff);
    assert_eq!(checksum(&mut t, "\x1b[1;0;1;1;2;10*y"), expected);
}

#[test]
fn a_space_wearing_an_attribute_is_not_a_blank() {
    // 0x20 + 0x10 is 0x30, which is not ' ', so it survives trimming.
    // Sum: 'A' (0x41) + underlined space (0x30).
    let mut t = Terminal::new(10, 2);
    feed(&mut t, "A\x1b[4m \x1b[m");

    let expected = format!("{:04X}", (0x41u32 + 0x30).wrapping_neg() & 0xffff);
    assert_eq!(checksum(&mut t, "\x1b[1;0;1;1;2;10*y"), expected);
}

// ── The rectangle ────────────────────────────────────────────────────────────

#[test]
fn the_rectangle_bounds_what_is_summed() {
    let mut t = Terminal::new(10, 3);
    feed(&mut t, "AB\r\nCD");

    // Row 1 only.
    assert_eq!(
        checksum(&mut t, "\x1b[1;0;1;1;1;10*y"),
        format!("{:04X}", (0x41u32 + 0x42).wrapping_neg() & 0xffff)
    );
    // Row 2 only.
    assert_eq!(
        checksum(&mut t, "\x1b[1;0;2;1;2;10*y"),
        format!("{:04X}", (0x43u32 + 0x44).wrapping_neg() & 0xffff)
    );
    // A single column across both rows: 'A' and 'C'.
    assert_eq!(
        checksum(&mut t, "\x1b[1;0;1;1;2;1*y"),
        format!("{:04X}", (0x41u32 + 0x43).wrapping_neg() & 0xffff)
    );
}

#[test]
fn omitted_coordinates_default_to_the_whole_screen() {
    let mut t = Terminal::new(10, 2);
    feed(&mut t, "AB");

    assert_eq!(
        checksum(&mut t, "\x1b[1;0*y"),
        checksum(&mut t, "\x1b[1;0;1;1;2;10*y")
    );
}

#[test]
fn coordinates_beyond_the_screen_are_clamped_rather_than_rejected() {
    let mut t = Terminal::new(10, 2);
    feed(&mut t, "AB");

    assert_eq!(
        checksum(&mut t, "\x1b[1;0;1;1;99;99*y"),
        checksum(&mut t, "\x1b[1;0;1;1;2;10*y")
    );
}

#[test]
fn a_single_cell_rectangle_reads_one_cell() {
    let mut t = Terminal::new(10, 2);
    feed(&mut t, "AB");

    assert_eq!(
        checksum(&mut t, "\x1b[1;0;1;2;1;2*y"),
        format!("{:04X}", 0x42u32.wrapping_neg() & 0xffff)
    );
}

#[test]
fn an_inverted_rectangle_checksums_to_zero() {
    let mut t = Terminal::new(10, 4);
    feed(&mut t, "AB");

    // bottom above top: xterm rejects this outright rather than wrapping.
    assert_eq!(checksum(&mut t, "\x1b[1;0;3;1;2;10*y"), "0000");
}

// ── XTCHECKSUM extensions ────────────────────────────────────────────────────

#[test]
fn the_positive_bit_stops_the_negation() {
    let mut t = Terminal::new(10, 2);
    feed(&mut t, "\x1b[1#yAB"); // extension bit 0

    assert_eq!(checksum(&mut t, "\x1b[1;0;1;1;2;10*y"), "0083");
}

#[test]
fn the_no_attribs_bit_leaves_styling_out() {
    let mut t = Terminal::new(10, 2);
    feed(&mut t, "\x1b[2#y\x1b[1mAB\x1b[m"); // extension bit 1, bold text

    // Bold would have added 0x80 twice; with the bit set it does not.
    assert_eq!(checksum(&mut t, "\x1b[1;0;1;1;2;10*y"), "FF7D");
}

#[test]
fn the_no_trim_bit_counts_plain_spaces() {
    let mut t = Terminal::new(10, 2);
    feed(&mut t, "\x1b[4#yA B"); // extension bit 2

    // Bounded to the three written cells, because the same bit also brings
    // never-written cells into the sum (see below).
    let expected = format!(
        "{:04X}",
        (0x41u32 + 0x20 + 0x42).wrapping_neg() & 0xffff
    );
    assert_eq!(checksum(&mut t, "\x1b[1;0;1;1;1;3*y"), expected);
}

/// Easy to miss, and it changes every whole-screen checksum: xterm skips a
/// never-written cell only when *neither* the no-trim nor the drawn bit is
/// set. Asking not to trim therefore also opts every blank cell on the
/// screen into the sum.
#[test]
fn the_no_trim_bit_also_counts_never_written_cells() {
    let mut t = Terminal::new(10, 2);
    feed(&mut t, "\x1b[4#yA B");

    // 3 written cells plus the 17 that were never touched, each a space.
    let expected = format!(
        "{:04X}",
        (0x41u32 + 0x20 + 0x42 + 0x20 * 17).wrapping_neg() & 0xffff
    );
    assert_eq!(checksum(&mut t, "\x1b[1;0;1;1;2;10*y"), expected);
}

#[test]
fn the_drawn_bit_counts_cells_nothing_ever_wrote() {
    let mut t = Terminal::new(4, 1);
    feed(&mut t, "\x1b[8#yA"); // extension bit 3

    // 'A' plus three untouched cells, each counted as a space. Trimming is
    // still on, so only the value change matters: the spaces are dropped
    // again by the trim, leaving 'A' alone.
    assert_eq!(
        checksum(&mut t, "\x1b[1;0;1;1;1;4*y"),
        format!("{:04X}", 0x41u32.wrapping_neg() & 0xffff)
    );

    // With trimming off as well, all four cells count.
    let mut u = Terminal::new(4, 1);
    feed(&mut u, "\x1b[12#yA"); // bits 3 and 2
    assert_eq!(
        checksum(&mut u, "\x1b[1;0;1;1;1;4*y"),
        format!("{:04X}", (0x41u32 + 0x20 * 3).wrapping_neg() & 0xffff)
    );
}

#[test]
fn the_extension_setting_persists_until_changed() {
    let mut t = Terminal::new(10, 2);
    feed(&mut t, "\x1b[1#yAB");
    assert_eq!(checksum(&mut t, "\x1b[1;0;1;1;2;10*y"), "0083");

    feed(&mut t, "\x1b[0#y"); // back to DEC behaviour
    assert_eq!(checksum(&mut t, "\x1b[1;0;1;1;2;10*y"), "FF7D");
}

// ── Interaction with the rest of the terminal ────────────────────────────────

#[test]
fn the_alternate_screen_is_checksummed_when_it_is_active() {
    let mut t = Terminal::new(10, 2);
    feed(&mut t, "AB");
    let primary = checksum(&mut t, "\x1b[1;0;1;1;2;10*y");

    feed(&mut t, "\x1b[?1049h"); // switch to a blank alternate screen
    assert_eq!(checksum(&mut t, "\x1b[1;0;1;1;2;10*y"), "0000");

    feed(&mut t, "\x1b[?1049l"); // and back
    assert_eq!(checksum(&mut t, "\x1b[1;0;1;1;2;10*y"), primary);
}

#[test]
fn erasing_a_cell_removes_it_from_the_sum() {
    let mut t = Terminal::new(10, 2);
    feed(&mut t, "AB");
    feed(&mut t, "\x1b[H\x1b[K"); // home, erase to end of line

    assert_eq!(checksum(&mut t, "\x1b[1;0;1;1;2;10*y"), "0000");
}

#[test]
fn a_checksum_query_does_not_disturb_the_screen() {
    let mut t = Terminal::new(10, 2);
    feed(&mut t, "AB");
    let before = t.dump();

    let _ = checksum(&mut t, "\x1b[1;0;1;1;2;10*y");

    assert_eq!(t.dump(), before);
}
