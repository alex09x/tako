/*
 * tako — Terminal emulator core library
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use crate::terminal::Terminal;

#[test]
fn kitty_interop_image_moves_with_scrolling_text() {
    let mut term = Terminal::new(10, 4);
    term.feed(b"\x1b[2;1H\x1b_Ga=T,q=2,f=32,s=1,v=1,C=1;AQIDBA==\x1b\\");
    assert_eq!(term.graphics_placements()[0].row, 1);
    term.feed(b"\x1b[4;1H\n");
    assert_eq!(
        term.graphics_placements()[0].row,
        0,
        "image should scroll with the line it belongs to"
    );
}

#[test]
fn kitty_interop_image_placed_at_bottom_moves_up_as_cursor_scrolls() {
    let core = crate::ffi::TakoCore::new(10, 4);
    core.set_pixel_size(100, 80);
    core.feed(b"\x1b[4;1H\x1b_Ga=T,q=2,f=32,s=1,v=1,c=1,r=2;AQIDBA==\x1b\\".to_vec());
    let placement = core.snapshot().graphics_placements[0];
    assert_eq!(
        placement.row, 1,
        "the image must move up when its own cursor advance scrolls the screen"
    );
}

#[test]
fn kitty_interop_image_follows_its_line_into_scrollback() {
    let core = crate::ffi::TakoCore::new(10, 4);
    core.feed(b"\x1b[1;1H\x1b_Ga=T,q=2,f=32,s=1,v=1,C=1;AQIDBA==\x1b\\\x1b[4;1H\n".to_vec());
    assert!(
        core.snapshot().graphics_placements.is_empty(),
        "the image scrolled out of the live screen"
    );
    core.scroll_viewport_up(1);
    let placements = core.snapshot().graphics_placements;
    assert_eq!(placements.len(), 1, "the image must remain in scrollback");
    assert_eq!(placements[0].row, 0);
}

#[test]
fn kitty_interop_partially_scrolled_image_keeps_its_offset() {
    let core = crate::ffi::TakoCore::new(10, 4);
    core.set_pixel_size(100, 80);
    core.feed(
        b"\x1b[1;1H\x1b_Ga=T,q=2,f=32,s=1,v=1,c=1,r=2,C=1;AQIDBA==\x1b\\\x1b[4;1H\n".to_vec(),
    );
    let visible = core.snapshot().graphics_placements;
    assert_eq!(visible.len(), 1);
    assert_eq!((visible[0].row, visible[0].row_offset), (0, -1));
    core.scroll_viewport_up(1);
    let history = core.snapshot().graphics_placements;
    assert_eq!((history[0].row, history[0].row_offset), (0, 0));
}

#[test]
fn kitty_interop_clear_screen_preserves_an_image_in_history() {
    let core = crate::ffi::TakoCore::new(10, 4);
    core.feed(b"\x1b[1;1H\x1b_Ga=T,i=1,q=2,f=32,s=1,v=1,C=1;AQIDBA==\x1b\\\x1b[4;1H\n\x1b[2;1H\x1b_Ga=T,i=2,q=2,f=32,s=1,v=1,C=1;BQYHCA==\x1b\\\x1b[2J".to_vec());
    assert!(core.snapshot().graphics_placements.is_empty());
    core.scroll_viewport_up(1);
    let history = core.snapshot().graphics_placements;
    assert_eq!(history.len(), 1);
    assert_eq!(history[0].image_id, 1);
}

#[test]
fn kitty_interop_checkpoint_preserves_scrollback_image_anchors() {
    let mut term = Terminal::new(10, 4);
    term.feed(b"\x1b[1;1H\x1b_Ga=T,i=1,q=2,f=32,s=1,v=1,C=1;AQIDBA==\x1b\\\x1b[4;1H\n");
    let checkpoint = term.export_checkpoint().unwrap();
    let restored = crate::ffi::TakoCore::new(10, 4);
    restored.checkpoint_import(checkpoint).unwrap();
    assert!(restored.snapshot().graphics_placements.is_empty());
    restored.scroll_viewport_up(1);
    let history = restored.snapshot().graphics_placements;
    assert_eq!(history.len(), 1);
    assert_eq!(
        (history[0].image_id, history[0].row, history[0].row_offset),
        (1, 0, 0)
    );
}

#[test]
fn kitty_interop_discards_a_placement_when_its_history_is_evicted() {
    let mut term = Terminal::new(10, 4);
    term.set_scrollback_capacity(1);
    term.feed(b"\x1b[1;1H\x1b_Ga=T,i=1,q=2,f=32,s=1,v=1,C=1;AQIDBA==\x1b\\\x1b[4;1H\n\n");
    assert!(term.graphics_placements().is_empty());
}

#[test]
fn kitty_interop_images_follow_scrolling_inside_a_region() {
    let core = crate::ffi::TakoCore::new(10, 6);
    core.feed(
        b"\x1b[3;1H\x1b_Ga=T,i=1,q=2,f=32,s=1,v=1,C=1;AQIDBA==\x1b\\\x1b[2;5r\x1b[5;1H\n".to_vec(),
    );
    assert_eq!(
        core.snapshot().graphics_placements[0].row,
        1,
        "scroll up inside margins"
    );
    core.feed(b"\x1b[2;1H\x1bM".to_vec());
    assert_eq!(
        core.snapshot().graphics_placements[0].row,
        2,
        "scroll down inside margins"
    );
}

#[test]
fn kitty_interop_region_scroll_clips_at_both_edges_without_restoring_discarded_rows() {
    let core = crate::ffi::TakoCore::new(10, 6);
    core.set_pixel_size(100, 120);
    core.feed(
        b"\x1b[2;1H\x1b_Ga=T,i=1,q=2,f=32,s=1,v=1,c=1,r=3,C=1;AQIDBA==\x1b\\\x1b[2;5r\x1b[5;1H\n"
            .to_vec(),
    );
    let first = core.snapshot().graphics_placements[0];
    assert_eq!(
        (first.row, first.clip_top_rows, first.clip_bottom_rows),
        (0, 1, 0)
    );
    core.feed(b"\x1b[2;1H\x1bM".to_vec());
    let after = core.snapshot().graphics_placements[0];
    assert_eq!(
        (after.row, after.clip_top_rows, after.clip_bottom_rows),
        (1, 1, 0)
    );

    core.feed(
        b"\x1b[4;3H\x1b_Ga=T,i=2,q=2,f=32,s=1,v=1,c=1,r=2,C=1;BQYHCA==\x1b\\\x1b[2;1H\x1bM"
            .to_vec(),
    );
    let placements = core.snapshot().graphics_placements;
    let lower = placements.iter().find(|p| p.image_id == 2).unwrap();
    assert_eq!(
        (lower.row, lower.clip_top_rows, lower.clip_bottom_rows),
        (4, 0, 1)
    );
}

#[test]
fn kitty_interop_region_scroll_leaves_images_outside_the_region_in_place() {
    let core = crate::ffi::TakoCore::new(10, 6);
    core.feed(
        b"\x1b[6;1H\x1b_Ga=T,i=1,q=2,f=32,s=1,v=1,C=1;AQIDBA==\x1b\\\x1b[2;5r\x1b[5;1H\n".to_vec(),
    );
    assert_eq!(core.snapshot().graphics_placements[0].row, 5);
}

#[test]
fn kitty_interop_top_region_scroll_keeps_images_below_the_region_fixed() {
    let core = crate::ffi::TakoCore::new(10, 6);
    core.feed(b"\x1b[6;1H\x1b_Ga=T,i=1,q=2,f=32,s=1,v=1,C=1;AQIDBA==\x1b\\\x1b[2;2H\x1b_Ga=T,i=2,q=2,f=32,s=1,v=1,C=1;BQYHCA==\x1b\\\x1b[1;4r\x1b[4;1H\n".to_vec());
    let placements = core.snapshot().graphics_placements;
    assert_eq!(placements.iter().find(|p| p.image_id == 1).unwrap().row, 5);
    assert_eq!(placements.iter().find(|p| p.image_id == 2).unwrap().row, 0);
}

#[test]
fn kitty_interop_horizontal_margins_move_only_images_inside_the_page() {
    let core = crate::ffi::TakoCore::new(10, 6);
    core.feed(b"\x1b[3;1H\x1b_Ga=T,i=1,q=2,f=32,s=1,v=1,C=1;AQIDBA==\x1b\\\x1b[3;3H\x1b_Ga=T,i=2,q=2,f=32,s=1,v=1,C=1;BQYHCA==\x1b\\\x1b[?69h\x1b[2;4s\x1b[2;5r\x1b[1S".to_vec());
    let placements = core.snapshot().graphics_placements;
    assert_eq!(placements.iter().find(|p| p.image_id == 1).unwrap().row, 2);
    assert_eq!(placements.iter().find(|p| p.image_id == 2).unwrap().row, 1);
}

#[test]
fn kitty_interop_region_clipping_survives_checkpoint_with_negative_origin() {
    let mut term = Terminal::new(10, 6);
    term.resize_with_cell_size(10, 6, 10, 20);
    term.feed(
        b"\x1b[2;1H\x1b_Ga=T,i=1,q=2,f=32,s=1,v=1,c=1,r=4,C=1;AQIDBA==\x1b\\\x1b[2;5r\x1b[3S",
    );
    let checkpoint = term.export_checkpoint().unwrap();
    let restored = crate::ffi::TakoCore::new(10, 6);
    restored.checkpoint_import(checkpoint).unwrap();
    let placement = restored.snapshot().graphics_placements[0];
    assert_eq!(
        (placement.row, placement.row_offset, placement.clip_top_rows),
        (0, -2, 3)
    );
}

#[test]
fn kitty_interop_image_follows_its_text_when_width_reflows() {
    let core = crate::ffi::TakoCore::new(10, 8);
    core.feed(
        b"abcdefghijk\x1b[3;1H\x1b_Ga=T,i=1,q=2,f=32,s=1,v=1,C=1;AQIDBA==\x1b\\TARGET".to_vec(),
    );
    core.resize(5, 8);
    let row = (0..8)
        .find(|&row| core.get_line(row).contains("TARGE"))
        .expect("reflowed text missing");
    let placement = core.snapshot().graphics_placements[0];
    assert_eq!(
        placement.row, row,
        "the image must follow its original text line through reflow"
    );
}

#[test]
fn kitty_interop_reflow_preserves_image_column_across_wide_characters() {
    let core = crate::ffi::TakoCore::new(6, 8);
    core.feed(
        "a界bc\u{1b}[1;5H\u{1b}_Ga=T,i=1,q=2,f=32,s=1,v=1,C=1;AQIDBA==\u{1b}\\"
            .as_bytes()
            .to_vec(),
    );
    core.resize(3, 8);
    let placement = core.snapshot().graphics_placements[0];
    assert_eq!((placement.row, placement.col), (1, 1));
    assert!(core.get_line(1).contains("bc"));
}

#[test]
fn kitty_interop_reflow_preserves_images_on_blank_lines() {
    let core = crate::ffi::TakoCore::new(10, 8);
    core.feed(b"\x1b[4;5H\x1b_Ga=T,i=1,q=2,f=32,s=1,v=1,C=1;AQIDBA==\x1b\\".to_vec());
    core.resize(5, 8);
    let placement = core.snapshot().graphics_placements[0];
    assert_eq!((placement.row, placement.col), (3, 4));
}

#[test]
fn kitty_interop_reflow_keeps_a_region_clipped_image_with_its_visible_line() {
    let core = crate::ffi::TakoCore::new(10, 8);
    core.set_pixel_size(100, 160);
    core.feed(b"\x1b[3;1H\x1b_Ga=T,i=1,q=2,f=32,s=1,v=1,c=1,r=4,C=1;AQIDBA==\x1b\\\x1b[3;6r\x1b[3S\x1b[3;1HTARGET\x1b[1;1Habcdefghijk".to_vec());
    core.resize(5, 8);
    let row = (0..8)
        .find(|&row| core.get_line(row).contains("TARGE"))
        .expect("reflowed text missing");
    let placement = core.snapshot().graphics_placements[0];
    let visible_row = i64::from(placement.row)
        + i64::from(placement.row_offset)
        + i64::from(placement.clip_top_rows);
    assert_eq!(visible_row, i64::from(row));
}

#[test]
fn kitty_interop_resize_does_not_evict_a_partially_retained_image_using_stale_pixels() {
    use base64::Engine as _;
    let mut term = Terminal::new(10, 4);
    term.resize_with_cell_size(10, 4, 10, 20);
    term.set_scrollback_capacity(1);
    let pixels = base64::engine::general_purpose::STANDARD.encode(vec![255u8; 160]);
    term.feed(
        format!(
            "\x1b[1;1H\x1b_Ga=T,i=1,q=2,f=32,s=1,v=40,C=1;{pixels}\x1b\\\x1b[4;1H\n\n\x1b[1;1H"
        )
        .as_bytes(),
    );
    term.resize(10, 1);
    term.set_pixel_size(100, 20);
    term.scroll_viewport_up(1);
    let visible = term.viewport_graphics_placements();
    assert_eq!(
        visible.len(),
        1,
        "the retained lower half must survive resize"
    );
    assert_eq!(visible[0].1, -1);
}

#[test]
fn kitty_interop_clear_screen_and_alternate_screen_respect_image_lifetime() {
    let core = crate::ffi::TakoCore::new(10, 4);
    core.feed(b"\x1b_Ga=T,q=2,f=32,s=1,v=1,C=1;AQIDBA==\x1b\\".to_vec());
    assert_eq!(core.snapshot().graphics_placements.len(), 1);
    core.feed(b"\x1b[?1049h".to_vec());
    assert!(
        core.snapshot().graphics_placements.is_empty(),
        "primary images must not leak into the alternate screen"
    );
    core.feed(b"\x1b[?1049l".to_vec());
    assert_eq!(
        core.snapshot().graphics_placements.len(),
        1,
        "the primary screen's image should return"
    );
    core.feed(b"\x1b[2J".to_vec());
    assert!(
        core.snapshot().graphics_placements.is_empty(),
        "clearing the screen must clear its images"
    );
}

#[test]
fn kitty_interop_checkpoint_keeps_each_screen_images_separate() {
    let mut term = Terminal::new(10, 4);
    term.feed(b"\x1b_Ga=T,i=1,q=2,f=32,s=1,v=1,C=1;AQIDBA==\x1b\\\x1b[?1049h\x1b_Ga=T,i=2,q=2,f=32,s=1,v=1,C=1;BQYHCA==\x1b\\");
    assert!(
        term.export_checkpoint_version(6, 0).is_err(),
        "older checkpoints cannot identify both screens"
    );
    let checkpoint = term.export_checkpoint().unwrap();
    let restored = crate::ffi::TakoCore::new(10, 4);
    restored.checkpoint_import(checkpoint).unwrap();
    assert_eq!(restored.snapshot().graphics_placements[0].image_id, 2);
    restored.feed(b"\x1b[?1049l".to_vec());
    assert_eq!(restored.snapshot().graphics_placements[0].image_id, 1);
    restored.feed(b"\x1b[?1049h".to_vec());
    assert!(
        restored.snapshot().graphics_placements.is_empty(),
        "a fresh alternate screen starts without old images"
    );
}
