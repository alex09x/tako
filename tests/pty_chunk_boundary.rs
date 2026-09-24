// Regression fixture: a real byte capture from `agy --dangerously-skip-permissions`
// (Google's Antigravity CLI) redrawing its slash-command dropdown, recorded by
// spawning it under a pty and typing "/c". Captured live against TakoCore.app
// this exposed a rendering glitch (stale "Sh"/leftover glyphs where "/changelog"
// and "/codesearch" should be) -- but that turned out to be a Swift-side redraw
// race (SurfaceView's PTY.readLoop triggers `needsDisplay` per raw `read()`
// return with no coalescing, so AppKit can paint a frame mid-multi-write
// escape-sequence), not a parser bug.
//
// This test proves the parser side of that story: fed byte-by-byte (the most
// adversarial possible chunking -- every escape sequence split as many ways as
// it can be), the final terminal state must still be exactly correct. A real
// PTY reader may deliver these same bytes in almost any grouping depending on
// OS scheduling, so a parser that depended on chunk boundaries aligning with
// escape-sequence boundaries would be a latent bug independent of the Swift
// redraw-race story above.
use tako_core::terminal::Terminal;

const CAPTURE: &[u8] = include_bytes!("fixtures/agy_dropdown_capture.bin");

fn row_text(term: &Terminal, row: usize) -> String {
    let grid = term.active_grid();
    (0..grid.cols())
        .map(|col| {
            let ch = grid.get(row, col).map(|c| c.char).unwrap_or(' ');
            if ch == '\0' { ' ' } else { ch }
        })
        .collect::<String>()
        .trim_end()
        .to_string()
}

#[test]
fn dropdown_menu_survives_byte_at_a_time_feed() {
    let mut term = Terminal::new(100, 40);
    for &byte in CAPTURE {
        term.feed(std::slice::from_ref(&byte));
    }

    assert!(
        row_text(&term, 10).contains("/changelog"),
        "row 10 was: {:?}",
        row_text(&term, 10)
    );
    assert!(
        row_text(&term, 12).contains("/codesearch (cs)"),
        "row 12 was: {:?}",
        row_text(&term, 12)
    );
}

#[test]
fn dropdown_menu_matches_regardless_of_chunk_size() {
    // A few chunk sizes chosen to land at different offsets relative to the
    // capture's escape sequences, so no single size gets lucky by always
    // aligning on a sequence boundary.
    for chunk_size in [1usize, 3, 7, 16, 64, 4096] {
        let mut term = Terminal::new(100, 40);
        for chunk in CAPTURE.chunks(chunk_size) {
            term.feed(chunk);
        }
        assert!(
            row_text(&term, 10).contains("/changelog"),
            "chunk_size {chunk_size}: row 10 was {:?}",
            row_text(&term, 10)
        );
        assert!(
            row_text(&term, 12).contains("/codesearch (cs)"),
            "chunk_size {chunk_size}: row 12 was {:?}",
            row_text(&term, 12)
        );
    }
}
