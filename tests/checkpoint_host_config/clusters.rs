/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::common::*;

const FAMILY: &str = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}";
const STACKED: &str = "e\u{0301}\u{0302}";
const DEVANAGARI: &str = "\u{0938}\u{094D}\u{0924}\u{0947}";

fn text(term: &Terminal) -> String {
    term.buffer_text()
}

fn restored_from(term: &Terminal) -> Terminal {
    restored(&term.export_checkpoint().unwrap())
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
    assert_eq!(
        text(&restored),
        before,
        "the clusters did not come back whole"
    );

    let mut alt = Terminal::new(20, 4);
    alt.feed(format!("\x1b[?1049h{FAMILY}").as_bytes());
    let alt_before = text(&alt);
    assert_eq!(
        text(&restored_from(&alt)),
        alt_before,
        "the alternate screen's cluster was lost"
    );
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
    assert!(
        back.starts_with('\u{00E9}') && !back.contains('\u{0302}'),
        "{back:?}"
    );
}

#[test]
fn a_cluster_that_names_no_cell_is_refused() {
    let mut term = Terminal::new(20, 4);
    term.feed(STACKED.as_bytes());
    // v3, where the cluster lists end the payload.
    let blob = term.export_checkpoint_version(3, 0).unwrap();
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
    assert!(matches!(
        dest.import_checkpoint(&forged),
        Err(CheckpointError::InvalidData(_))
    ));
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
