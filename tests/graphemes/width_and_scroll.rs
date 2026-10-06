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
fn a_cluster_takes_one_cell_and_its_presentation_width() {
    for_each_kind(|k| {
        let mut t = Terminal::new(20, 2);
        feed(&mut t, &format!("a{}b", k.text));
        assert_eq!(t.plain_string(), format!("a{}b", k.text), "{}", k.name);
        assert_eq!(t.cursor(), (0, 2 + k.width), "{}", k.name);
        assert_eq!(cell_text(&t, 0, 1), k.text, "{}", k.name);
        assert_eq!(
            t.active_grid().get(0, 2).unwrap().is_wide_spacer,
            k.width == 2,
            "{}",
            k.name
        );
    });
}

#[test]
fn legacy_width_sums_the_codepoints_and_keeps_the_text() {
    for_each_kind(|k| {
        let mut t = Terminal::new(20, 2);
        t.set_grapheme_width_method(GraphemeWidthMethod::Legacy);
        feed(&mut t, k.text);
        assert_eq!(t.cursor(), (0, k.legacy_width), "{}", k.name);
        assert_eq!(t.plain_string(), k.text, "{}", k.name);
    });
}

#[test]
fn clusters_scroll_into_scrollback_and_back_into_view() {
    for_each_kind(|k| {
        let mut t = Terminal::new(10, 3);
        feed(&mut t, &format!("{}\r\n1\r\n2\r\n3\r\n4", k.text));
        assert_eq!(t.active_grid().scrollback_len(), 2, "{}", k.name);
        assert!(
            t.buffer_text().starts_with(&format!("{}\n1\n", k.text)),
            "{}",
            k.name
        );
        t.scroll_viewport_up(2);
        assert_eq!(line(&t, 0), k.text, "{}", k.name);
    });
}

#[test]
fn clusters_move_with_full_width_scroll_regions() {
    for_each_kind(|k| {
        let mut t = Terminal::new(10, 5);
        feed(&mut t, &format!("\x1b[2;4r\x1b[3;1H{}", k.text));
        feed(&mut t, "\x1b[S");
        assert_eq!(line(&t, 1), k.text, "{} after SU", k.name);
        assert_eq!(line(&t, 2), "", "{} after SU", k.name);
        feed(&mut t, "\x1b[2T");
        assert_eq!(line(&t, 3), k.text, "{} after SD", k.name);
        // Reverse index at the region's top scrolls it down once more,
        // pushing the cluster out through the bottom margin.
        feed(&mut t, "\x1b[2;1H\x1bM");
        assert!(!t.plain_string().contains(k.text), "{} after RI", k.name);
    });
}

#[test]
fn clusters_move_with_scroll_regions_inside_side_margins() {
    for_each_kind(|k| {
        let mut t = Terminal::new(10, 5);
        feed(
            &mut t,
            &format!("\x1b[?69h\x1b[1;8s\x1b[2;4r\x1b[3;1H{}", k.text),
        );
        feed(&mut t, "\x1b[S");
        assert_eq!(line(&t, 1), k.text, "{} after SU", k.name);
        feed(&mut t, "\x1b[T");
        assert_eq!(line(&t, 2), k.text, "{} after SD", k.name);
        assert_eq!(cell_text(&t, 2, 0), k.text, "{}", k.name);
    });
}

#[test]
fn erases_remove_the_whole_cluster() {
    for_each_kind(|k| {
        let w = k.width;
        let fresh = |s: &str| {
            let mut t = Terminal::new(20, 3);
            feed(&mut t, &format!("{}xyz", k.text));
            feed(&mut t, s);
            t
        };
        // EL 0 from the cluster, EL 1 through the column after it, EL 2.
        assert_eq!(
            fresh("\x1b[1;1H\x1b[K").plain_string(),
            "",
            "{} EL0",
            k.name
        );
        let el1 = fresh(&format!("\x1b[1;{}H\x1b[1K", w + 1)).plain_string();
        assert_eq!(el1, format!("{}yz", " ".repeat(w + 1)), "{} EL1", k.name);
        assert_eq!(fresh("\x1b[2K").plain_string(), "", "{} EL2", k.name);
        // ED 2 and ED 1.
        assert_eq!(fresh("\x1b[2J").plain_string(), "", "{} ED2", k.name);
        assert_eq!(
            fresh("\x1b[2;1H\x1b[1J").plain_string(),
            "",
            "{} ED1",
            k.name
        );
        // ECH over the cluster's columns, and ECH of one column on its spacer.
        let ech = fresh(&format!("\x1b[1;1H\x1b[{w}X")).plain_string();
        assert_eq!(ech, format!("{}xyz", " ".repeat(w)), "{} ECH", k.name);
        if w == 2 {
            let tail = fresh("\x1b[1;2H\x1b[X").plain_string();
            assert_eq!(tail, "  xyz", "{} ECH on the spacer", k.name);
        }
    });
}

#[test]
fn selective_erase_keeps_a_protected_cluster() {
    for_each_kind(|k| {
        for (erase, what) in [("\x1b[?2J", "DECSED"), ("\x1b[1;1H\x1b[?2K", "DECSEL")] {
            let mut t = Terminal::new(20, 2);
            feed(&mut t, &format!("\x1b[1\"q{}\x1b[0\"qab", k.text));
            feed(&mut t, erase);
            assert_eq!(t.plain_string(), k.text, "{} {what}", k.name);
            assert_eq!(cell_text(&t, 0, 0), k.text, "{} {what}", k.name);
        }
        // An unprotected cluster goes.
        let mut t = Terminal::new(20, 2);
        feed(&mut t, &format!("{}ab\x1b[?2J", k.text));
        assert_eq!(t.plain_string(), "", "{}", k.name);
    });
}
