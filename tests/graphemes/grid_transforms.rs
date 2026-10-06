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

#[test]
fn inserted_and_deleted_characters_shift_the_cluster() {
    for_each_kind(|k| {
        let mut t = Terminal::new(20, 2);
        feed(&mut t, &format!("x{}y\x1b[1;1H\x1b[2@", k.text));
        assert_eq!(
            t.plain_string(),
            format!("  x{}y", k.text),
            "{} ICH",
            k.name
        );
        assert_eq!(cell_text(&t, 0, 3), k.text, "{} ICH", k.name);
        feed(&mut t, "\x1b[2P");
        assert_eq!(t.plain_string(), format!("x{}y", k.text), "{} DCH", k.name);
        feed(&mut t, &format!("\x1b[1;2H\x1b[{}P", k.width));
        assert_eq!(t.plain_string(), "xy", "{} DCH of the cluster", k.name);
        // Insert mode shifts it like ICH.
        let mut t = Terminal::new(20, 2);
        feed(&mut t, &format!("y{}\x1b[1;1H\x1b[4hab", k.text));
        assert_eq!(t.plain_string(), format!("aby{}", k.text), "{} IRM", k.name);
    });
}

#[test]
fn inserted_and_deleted_lines_move_the_cluster() {
    for_each_kind(|k| {
        let mut t = Terminal::new(20, 4);
        feed(&mut t, &format!("\x1b[2;1H{}\x1b[1;1H\x1b[L", k.text));
        assert_eq!(line(&t, 2), k.text, "{} IL", k.name);
        feed(&mut t, "\x1b[M");
        assert_eq!(line(&t, 1), k.text, "{} DL", k.name);
        feed(&mut t, "\x1b[2;1H\x1b[M");
        assert!(
            !t.plain_string().contains(k.text),
            "{} DL of its row",
            k.name
        );
        // With side margins IL/DL copy cells one by one.
        let mut t = Terminal::new(20, 4);
        feed(
            &mut t,
            &format!("\x1b[2;1H{}\x1b[?69h\x1b[1;10s\x1b[1;1H\x1b[L", k.text),
        );
        assert_eq!(line(&t, 2), k.text, "{} IL in margins", k.name);
        feed(&mut t, "\x1b[M");
        assert_eq!(line(&t, 1), k.text, "{} DL in margins", k.name);
    });
}

#[test]
fn column_insertion_and_deletion_shift_the_cluster() {
    for_each_kind(|k| {
        let mut t = Terminal::new(20, 2);
        feed(&mut t, &format!("x{}\x1b[1;1H\x1b['}}", k.text));
        assert_eq!(
            t.plain_string(),
            format!(" x{}", k.text),
            "{} DECIC",
            k.name
        );
        feed(&mut t, "\x1b['~");
        assert_eq!(t.plain_string(), format!("x{}", k.text), "{} DECDC", k.name);
    });
}

#[test]
fn reflow_carries_the_cluster_across_widths() {
    for_each_kind(|k| {
        let mut t = Terminal::new(7, 3);
        feed(&mut t, &format!("abcd{}ef", k.text));
        t.resize(20, 3);
        assert_eq!(
            t.plain_string(),
            format!("abcd{}ef", k.text),
            "{} widened",
            k.name
        );
        assert_eq!(cell_text(&t, 0, 4), k.text, "{} widened", k.name);
        t.resize(6, 3);
        assert!(
            t.buffer_text().starts_with(&format!("abcd{}ef\n", k.text)),
            "{} narrowed",
            k.name
        );
        t.resize(7, 3);
        assert_eq!(cell_text(&t, 0, 4), k.text, "{} restored", k.name);
    });
}

#[test]
fn row_resizes_move_the_cluster_through_scrollback() {
    for_each_kind(|k| {
        let mut t = Terminal::new(10, 4);
        feed(&mut t, &format!("{}\r\n1\r\n2\r\n3", k.text));
        t.resize(10, 2);
        assert_eq!(t.plain_string(), "2\n3", "{} shrunk", k.name);
        assert!(
            t.buffer_text().starts_with(&format!("{}\n", k.text)),
            "{} shrunk",
            k.name
        );
        t.resize(10, 4);
        assert_eq!(line(&t, 0), k.text, "{} grown back", k.name);
        // Without wraparound, a resize truncates rather than reflows.
        let mut t = Terminal::new(10, 2);
        feed(&mut t, &format!("\x1b[?7l{}x", k.text));
        t.resize(3, 2);
        assert_eq!(
            t.plain_string(),
            format!("{}x", k.text),
            "{} no reflow",
            k.name
        );
    });
}

#[test]
fn the_alternate_screen_keeps_its_own_clusters() {
    for_each_kind(|k| {
        let mut t = Terminal::new(10, 3);
        feed(&mut t, &format!("{}\x1b[?1049h", k.text));
        assert_eq!(t.plain_string(), "", "{}", k.name);
        feed(&mut t, &format!("\x1b[H{}!", k.text));
        assert_eq!(
            t.plain_string(),
            format!("{}!", k.text),
            "{} alternate",
            k.name
        );
        feed(&mut t, "\x1b[?1049l");
        assert_eq!(t.plain_string(), k.text, "{} primary", k.name);
        feed(&mut t, "\x1b[?1049h");
        assert_eq!(t.plain_string(), "", "{} alternate cleared", k.name);
    });
}

#[test]
fn overwriting_either_half_replaces_the_cluster() {
    for_each_kind(|k| {
        let mut t = Terminal::new(10, 2);
        feed(&mut t, &format!("{}y\x1b[1;1Hx", k.text));
        let expected = if k.width == 2 { "x y" } else { "xy" };
        assert_eq!(t.plain_string(), expected, "{} head", k.name);
        assert_eq!(
            t.active_grid().get(0, 0).unwrap().grapheme,
            0,
            "{} head",
            k.name
        );
        if k.width == 2 {
            let mut t = Terminal::new(10, 2);
            feed(&mut t, &format!("{}y\x1b[1;2Hx", k.text));
            assert_eq!(t.plain_string(), " xy", "{} spacer", k.name);
            // Inserting inside the pair splits it: nothing half-drawn stays.
            let mut t = Terminal::new(10, 2);
            feed(&mut t, &format!("{}y\x1b[1;2H\x1b[@", k.text));
            assert_eq!(t.plain_string(), "   y", "{} ICH on the spacer", k.name);
        }
    });
}

#[test]
fn a_wide_cluster_that_does_not_fit_wraps_whole() {
    for_each_kind(|k| {
        if k.width != 2 {
            return;
        }
        let mut t = Terminal::new(5, 3);
        feed(&mut t, &format!("abcd{}z", k.text));
        assert_eq!(line(&t, 0), "abcd", "{}", k.name);
        assert_eq!(line(&t, 1), format!("{}z", k.text), "{}", k.name);
        assert!(
            t.active_grid().get(0, 4).unwrap().is_wide_spacer_head,
            "{}",
            k.name
        );
        assert_eq!(t.cursor(), (1, 3), "{}", k.name);
        assert!(
            t.buffer_text().starts_with(&format!("abcd{}z\n", k.text)),
            "{}",
            k.name
        );
    });
}

#[test]
fn a_mark_after_a_wide_cluster_joins_its_head() {
    for_each_kind(|k| {
        let mut t = Terminal::new(10, 2);
        feed(&mut t, &format!("{}\u{0301}x", k.text));
        assert_eq!(
            t.plain_string(),
            format!("{}\u{0301}x", k.text),
            "{}",
            k.name
        );
        assert_eq!(t.cursor(), (0, k.width + 1), "{}", k.name);
    });
}
