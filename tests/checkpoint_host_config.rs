// What a checkpoint carries of the host's configuration (container v3), and
// writing an older container for a peer that reads no newer.
//
// A v2 checkpoint holds the live colours only, so its import has to guess
// which were a program's: every colour that differs from the built-in default
// is taken for an override. A host theme is exactly such a colour, so after a
// restore the source's theme stuck to the screen -- the destination's own
// theme could not reach it. v3 carries the bases and the override flags.

use tako_core::cursor_style::{CursorShape, CursorStyle};
use tako_core::ffi::TakoCore;
use tako_core::terminal::Terminal;
use tako_core::terminal::checkpoint::{
    self, CURRENT_VERSION, CheckpointError, MIN_EXPORT_VERSION,
};

const THEME_A_IDX2: (u8, u8, u8) = (100, 110, 120);
const THEME_B_IDX2: (u8, u8, u8) = (130, 140, 150);
const THEME_A_FG: (u8, u8, u8) = (10, 20, 30);
const THEME_B_FG: (u8, u8, u8) = (40, 50, 60);
const PROGRAM_IDX1: (u8, u8, u8) = (1, 2, 3);

/// A terminal under theme A in which a program has set palette entry 1.
fn themed_source() -> Terminal {
    let mut term = Terminal::new(20, 4);
    term.set_base_colors(Some(THEME_A_FG), None, None, &[(2, THEME_A_IDX2)]);
    term.feed(b"\x1b]4;1;#010203\x07");
    term.feed(b"hello");
    term
}

fn restored(blob: &[u8]) -> Terminal {
    let mut term = Terminal::new(20, 4);
    term.import_checkpoint(blob).unwrap();
    term
}

fn header_version(blob: &[u8]) -> u32 {
    u32::from_le_bytes(blob[4..8].try_into().unwrap())
}

#[test]
fn this_build_writes_version_3() {
    assert_eq!(CURRENT_VERSION, 3);
    assert_eq!(Terminal::checkpoint_version(), 3);
    let blob = themed_source().export_checkpoint().unwrap();
    assert_eq!(header_version(&blob), 3);
}

#[test]
fn a_theme_change_after_restore_reaches_what_the_theme_coloured() {
    let blob = themed_source().export_checkpoint().unwrap();
    let mut term = restored(&blob);

    // Before the destination says anything, the source's colours are on
    // screen, the program's among them.
    assert_eq!(term.palette().get(2), THEME_A_IDX2);
    assert_eq!(term.palette().get(1), PROGRAM_IDX1);
    assert_eq!(term.default_colors().0, Some(THEME_A_FG));

    term.set_base_colors(Some(THEME_B_FG), None, None, &[(2, THEME_B_IDX2)]);
    assert_eq!(term.palette().get(2), THEME_B_IDX2, "the theme's entry follows the new theme");
    assert_eq!(term.default_colors().0, Some(THEME_B_FG), "so does the theme's foreground");
    assert_eq!(term.palette().get(1), PROGRAM_IDX1, "the program's entry stays the program's");

    // And a reset goes to the base the checkpoint carried, not the built-in.
    let mut again = restored(&blob);
    again.feed(b"\x1b]104\x07");
    assert_eq!(again.palette().get(1), tako_core::palette::Palette::new().get(1));
    assert_eq!(again.palette().get(2), THEME_A_IDX2);
}

#[test]
fn a_v2_checkpoint_still_infers_what_it_does_not_carry() {
    let blob = themed_source().export_checkpoint_version(2, 0).unwrap();
    assert_eq!(header_version(&blob), 2);
    let mut term = restored(&blob);

    // Same screen...
    assert_eq!(term.palette().get(1), PROGRAM_IDX1);
    assert_eq!(term.palette().get(2), THEME_A_IDX2);
    // ...but no way to tell the theme's colour from a program's, so it is
    // kept as one: the behaviour v3 exists to fix, preserved for v2.
    term.set_base_colors(Some(THEME_B_FG), None, None, &[(2, THEME_B_IDX2)]);
    assert_eq!(term.palette().get(2), THEME_A_IDX2);
    assert_eq!(term.default_colors().0, Some(THEME_A_FG));
}

#[test]
fn the_default_cursor_style_travels_and_a_programs_style_stays_a_programs() {
    const BAR: CursorStyle = CursorStyle { shape: CursorShape::Bar, blinking: true };
    const UNDERLINE: CursorStyle = CursorStyle { shape: CursorShape::Underline, blinking: false };

    let mut host_styled = Terminal::new(20, 4);
    host_styled.set_default_cursor_style(BAR);
    let mut term = restored(&host_styled.export_checkpoint().unwrap());
    assert_eq!(term.cursor_style(), BAR);
    term.set_default_cursor_style(UNDERLINE);
    assert_eq!(term.cursor_style(), UNDERLINE, "the host's default follows the host");

    let mut program_styled = Terminal::new(20, 4);
    program_styled.set_default_cursor_style(BAR);
    program_styled.feed(b"\x1b[4 q"); // DECSCUSR steady underline
    let mut term = restored(&program_styled.export_checkpoint().unwrap());
    term.set_default_cursor_style(BAR);
    assert_eq!(term.cursor_style(), UNDERLINE, "a program's choice outlives a host default");
    // DECSCUSR 0 goes back to the default the checkpoint carried.
    let mut term = restored(&program_styled.export_checkpoint().unwrap());
    term.feed(b"\x1b[0 q");
    assert_eq!(term.cursor_style(), BAR);
}

#[test]
fn export_version_writes_what_was_asked_or_refuses() {
    let term = themed_source();
    assert_eq!(MIN_EXPORT_VERSION, 2);
    assert_eq!(header_version(&term.export_checkpoint_version(0, 0).unwrap()), 3);
    assert_eq!(header_version(&term.export_checkpoint_version(3, 0).unwrap()), 3);
    for version in [1, 4, u32::MAX] {
        assert_eq!(
            term.export_checkpoint_version(version, 0),
            Err(CheckpointError::UnsupportedVersion(version))
        );
        assert_eq!(
            term.measure_checkpoint_version(version, 0),
            Err(CheckpointError::UnsupportedVersion(version))
        );
    }
    // The measurement is the export's exact length, per version; v3 is v2
    // plus the host block.
    for version in [2, 3] {
        let blob = term.export_checkpoint_version(version, 0).unwrap();
        assert_eq!(term.measure_checkpoint_version(version, 0).unwrap(), blob.len() as u64);
        assert!(checkpoint::verify(&blob));
    }
    let v2 = term.export_checkpoint_version(2, 0).unwrap().len();
    let v3 = term.export_checkpoint_version(3, 0).unwrap().len();
    // 256 base colours, 256 override bits, the fg base (set: flag + rgb) and
    // the bg and cursor bases (unset: flag only), three override flags, the
    // default cursor style and whether a program changed it, and two empty
    // cluster lists.
    assert_eq!(v3 - v2, 256 * 3 + 32 + 4 + 1 + 1 + 3 + 2 + 1 + 4 + 4);
    // A cap still applies to the version asked for.
    assert!(matches!(
        term.export_checkpoint_version(2, 64),
        Err(CheckpointError::TooLarge { .. })
    ));
}

#[test]
fn a_truncated_host_block_is_refused_not_half_applied() {
    let term = themed_source();
    let blob = term.export_checkpoint().unwrap();
    let mut short = blob[..blob.len() - 1].to_vec();
    let payload_len = (short.len() - 20) as u32;
    short[12..16].copy_from_slice(&payload_len.to_le_bytes());
    let crc = checkpoint::crc32(&short[20..]);
    short[16..20].copy_from_slice(&crc.to_le_bytes());

    let mut dest = Terminal::new(20, 4);
    dest.feed(b"DEST");
    assert_eq!(dest.import_checkpoint(&short), Err(CheckpointError::UnexpectedEof));
    assert_eq!(dest.palette().get(1), tako_core::palette::Palette::new().get(1));
}

#[test]
fn ffi_exports_the_version_a_peer_asks_for() {
    let core = TakoCore::new(20, 4);
    core.feed(b"negotiate".to_vec());
    let v2 = core.checkpoint_export_version(2, 0).unwrap();
    assert_eq!(header_version(&v2), 2);
    assert_eq!(header_version(&core.checkpoint_export_version(0, 0).unwrap()), 3);
    assert!(core.checkpoint_export_version(1, 0).is_err());

    let dest = TakoCore::new(20, 4);
    dest.checkpoint_import(v2).unwrap();
}

// ── The host's scrollback limit survives a reset ─────────────────────────

#[test]
fn ris_keeps_the_hosts_scrollback_limit() {
    let mut term = Terminal::new(20, 4);
    term.set_scrollback_capacity(50_000);
    term.feed(b"\x1bc");
    assert_eq!(term.active_grid().scrollback_capacity(), 50_000);

    // And it is honoured, not just reported: 60 lines through a 4-row
    // screen with a 10-line limit keep 10.
    let mut small = Terminal::new(20, 4);
    small.set_scrollback_capacity(10);
    small.feed(b"\x1bc");
    for i in 0..60 {
        small.feed(format!("line {i}\r\n").as_bytes());
    }
    assert_eq!(small.active_grid().scrollback_len(), 10);
}

#[test]
fn a_host_reset_keeps_the_hosts_scrollback_limit() {
    let mut term = Terminal::new(20, 4);
    term.set_scrollback_capacity(123);
    let fresh = term.fresh_keeping_host_config();
    assert_eq!(fresh.active_grid().scrollback_capacity(), 123);

    let core = TakoCore::new(20, 4);
    core.set_scrollback_limit(10);
    core.reset();
    for i in 0..60 {
        core.feed(format!("line {i}\r\n").into_bytes());
    }
    assert_eq!(core.scrollback_len(), 10);
}

// ── Grapheme clusters travel in v3 ───────────────────────────────────────

const FAMILY: &str = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}";
const STACKED: &str = "e\u{0301}\u{0302}";
const DEVANAGARI: &str = "\u{0938}\u{094D}\u{0924}\u{0947}";

fn text(term: &Terminal) -> String {
    term.buffer_text()
}

#[test]
fn clusters_survive_a_v3_round_trip_on_screen_in_scrollback_and_on_the_alternate_screen() {
    let mut term = Terminal::new(20, 4);
    term.feed(format!("{FAMILY} {STACKED}\r\n").as_bytes());
    // Push it into scrollback, then put another on screen.
    for i in 0..6 {
        term.feed(format!("line {i}\r\n").as_bytes());
    }
    term.feed(DEVANAGARI.as_bytes());
    let before = text(&term);
    assert!(before.contains(FAMILY) && before.contains(DEVANAGARI) && before.contains('\u{0302}'));

    let restored = restored(&term.export_checkpoint().unwrap());
    assert_eq!(text(&restored), before, "the clusters did not come back whole");

    let mut alt = Terminal::new(20, 4);
    alt.feed(format!("\x1b[?1049h{FAMILY}").as_bytes());
    let alt_before = text(&alt);
    assert_eq!(text(&restored_from(&alt)), alt_before, "the alternate screen's cluster was lost");
}

fn restored_from(term: &Terminal) -> Terminal {
    restored(&term.export_checkpoint().unwrap())
}

#[test]
fn a_restored_cluster_keeps_its_width() {
    let mut term = Terminal::new(20, 4);
    term.feed(format!("{FAMILY}x").as_bytes());
    let before = term.cursor();
    let mut restored = restored(&term.export_checkpoint().unwrap());
    assert_eq!(restored.cursor(), before);
    // Overwriting the cluster's first column must clear its second too,
    // which only happens if the cell still knows it is wide.
    restored.feed(b"\x1b[1;1Hab");
    assert!(text(&restored).starts_with("abx"), "{:?}", text(&restored));
}

#[test]
fn a_v2_checkpoint_keeps_only_each_clusters_first_character() {
    let mut term = Terminal::new(20, 4);
    term.feed(STACKED.as_bytes());
    let restored = restored(&term.export_checkpoint_version(2, 0).unwrap());
    let back = text(&restored);
    // e + U+0301 folded to é on input; the circumflex was the cluster.
    assert!(back.starts_with('\u{00E9}') && !back.contains('\u{0302}'), "{back:?}");
}

#[test]
fn a_cluster_that_names_no_cell_is_refused() {
    let mut term = Terminal::new(20, 4);
    term.feed(STACKED.as_bytes());
    let blob = term.export_checkpoint().unwrap();
    // The last cluster list is the alternate screen's, empty; the one
    // before it holds our single cluster. Find its line number -- the
    // first u32 after the primary list's count -- and point it past the
    // grid, then reseal.
    // é (folded on input) holds just the circumflex.
    let extra = "\u{0302}".as_bytes();
    let tail = 4 + 4 + 4 + 4 + extra.len() + 1 + 4;
    let line_at = blob.len() - tail + 4;
    let mut forged = blob.clone();
    forged[line_at..line_at + 4].copy_from_slice(&999u32.to_le_bytes());
    let crc = checkpoint::crc32(&forged[20..]);
    forged[16..20].copy_from_slice(&crc.to_le_bytes());

    let mut dest = Terminal::new(20, 4);
    dest.feed(b"DEST");
    assert!(matches!(dest.import_checkpoint(&forged), Err(CheckpointError::InvalidData(_))));
    assert!(text(&dest).starts_with("DEST"), "fail-intact");
}

#[test]
fn cluster_import_cost_matches_allocated_budget() {
    use tako_core::terminal::checkpoint::{import_cost, import_traced};

    let mut term = Terminal::new(20, 4);
    term.feed(format!("{FAMILY} {STACKED}\r\n").as_bytes());
    for i in 0..6 {
        term.feed(format!("line {i}\r\n").as_bytes());
    }
    term.feed(DEVANAGARI.as_bytes());
    term.feed(format!("\x1b[?1049h{FAMILY}\x1b[?1049l").as_bytes());

    let blob = term.export_checkpoint().unwrap();
    let predicted = import_cost(&term);
    let (restored, trace) = import_traced(&blob).expect("honest checkpoint imports");

    assert_eq!(
        trace.allocated, predicted,
        "import charged {} where export predicted {predicted}",
        trace.allocated
    );
    assert_eq!(import_cost(&restored), predicted);
}

