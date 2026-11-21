/*
 * tako — Terminal emulator core library
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

//! OSC 1337 as a program uses it. An inline image is stored at the size it
//! is encoded at; the size asked for becomes the placement's cell box, which
//! the renderers fit the whole image into, and the cursor moves below what
//! they draw. The clipboard and status keys reach the host as events.

use crate::terminal::checkpoint::{export, import};
use crate::terminal::perform::kitty_geometry::placement_spans;
use crate::terminal::{ClipboardPolicy, Terminal, TerminalEvent};
use base64::Engine as _;

fn png(width: u32, height: u32) -> String {
    let mut png = b"\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR".to_vec();
    png.extend_from_slice(&width.to_be_bytes());
    png.extend_from_slice(&height.to_be_bytes());
    png.extend_from_slice(b"\x08\x06\x00\x00\x00\x00\x00\x00\x00");
    base64::engine::general_purpose::STANDARD.encode(&png)
}

/// An 80x24 grid of 10x20 px cells, cursor at the top left.
fn terminal() -> Terminal {
    let mut term = Terminal::new(80, 24);
    term.set_pixel_size(800, 480);
    term.feed(b"\x1b[H");
    term
}

/// What a placed image gives a renderer: its stored size, the placement's
/// (columns, rows) box, and the row the cursor went to.
struct Placed {
    stored: (u32, u32),
    cells: (u32, u32),
    row: usize,
}

fn place(term: &mut Terminal, args: &str, data: &str) -> Placed {
    term.feed(format!("\x1b]1337;File={args}:{data}\x07").as_bytes());
    let p = *term
        .graphics_placements()
        .last()
        .expect("the image is placed");
    let image = term
        .graphics_image(p.image_id)
        .expect("the image is stored");
    // Whatever the box, what the renderers draw ends at or above the cursor,
    // so following output is never drawn over -- after any scrolling too.
    if image.width > 0 && image.height > 0 {
        let (cols, rows) = (
            term.active_grid().cols() as u32,
            term.active_grid().rows() as u32,
        );
        // The cell the engine assumes: from the pixel size, else 10x20.
        let side = |px: u32, n: u32, fallback| if px > 0 { (px / n).max(1) } else { fallback };
        let cell = (
            side(term.width_px, cols, 10),
            side(term.height_px, rows, 20),
        );
        let span = placement_spans(p.options, (image.width, image.height), cell).1 as i64;
        let cursor_line = term.graphics_live_top() + term.cursor.row as i64;
        assert!(
            p.line + span <= cursor_line,
            "{args}: drawn {span} rows from line {}, cursor on line {cursor_line}",
            p.line
        );
    }
    Placed {
        stored: (image.width, image.height),
        cells: (p.options.columns, p.options.rows),
        row: term.cursor.row,
    }
}

fn check(args: &str, image: (u32, u32), cells: (u32, u32), row: usize) {
    let got = place(&mut terminal(), args, &png(image.0, image.1));
    assert_eq!(got.stored, image, "{args}: stored at its encoded size");
    assert_eq!(
        (got.cells, got.row),
        (cells, row),
        "{args}: box and cursor row"
    );
}

// A 100x50 image on 10x20 px cells unless said otherwise. The cursor row is
// the height the renderers draw: 20 columns of 10 px make it 200x100, 5 rows.

#[test]
fn a_box_that_would_draw_past_the_row_cap_is_held_to_it() {
    // 20 columns make a 10x2000 image 200x40000 px, 2000 rows: the box takes
    // the 1024-row cap as its height, and the image is fitted inside it.
    let mut term = terminal();
    let got = place(&mut term, "inline=1;width=20", &png(10, 2000));
    assert_eq!(
        (got.stored, got.cells, got.row),
        ((10, 2000), (20, 1024), 23)
    );
}

#[test]
fn a_natural_size_taller_than_the_row_cap_is_held_to_it() {
    // On 10 px high cells a 10x12000 image is 1200 rows at its own size.
    let mut term = Terminal::new(80, 24);
    term.set_pixel_size(800, 240);
    term.feed(b"\x1b[H");
    let got = place(&mut term, "inline=1", &png(10, 12000));
    assert_eq!(
        (got.stored, got.cells, got.row),
        ((10, 12000), (0, 1024), 23)
    );
}

#[test]
fn a_width_in_cells_is_the_box_and_the_height_follows_the_ratio() {
    check("inline=1;width=20", (100, 50), (20, 0), 5);
}

#[test]
fn a_height_in_cells_is_the_box_and_the_width_follows_the_ratio() {
    check("inline=1;height=3", (100, 50), (0, 3), 3);
}

#[test]
fn pixels_are_taken_to_the_nearest_whole_cell() {
    // 300 px is 30 cells; drawn 300x150, 8 rows.
    check("inline=1;width=300px", (100, 50), (30, 0), 8);
    // 305 px is 30.5 cells: 31, so the image is drawn 310 px wide, 155 high.
    check("inline=1;width=305px", (100, 50), (31, 0), 8);
    // 65 px is 3.25 rows: 3. 70 px is 3.5: 4. 4 px is less than a cell: 1.
    check("inline=1;height=65px", (100, 50), (0, 3), 3);
    check("inline=1;height=70px", (100, 50), (0, 4), 4);
    check("inline=1;height=4px", (100, 50), (0, 1), 1);
}

#[test]
fn two_sides_are_a_box_and_the_cursor_goes_below_all_of_it() {
    // The image is fitted inside 40x5 cells; the box's 5 rows are taken.
    check("inline=1;width=40;height=5", (100, 50), (40, 5), 5);
}

#[test]
fn preserve_aspect_ratio_0_is_not_supported_and_the_image_is_fitted() {
    // No stretch: the same box as without it, which the renderers fit into.
    check(
        "inline=1;width=40;height=5;preserveAspectRatio=0",
        (100, 50),
        (40, 5),
        5,
    );
}

#[test]
fn no_size_auto_or_an_unknown_unit_draws_the_image_at_its_own_size() {
    for args in [
        "inline=1",
        "inline=1;width=auto;height=auto",
        "inline=1;width=50%",
        "inline=1;width=0",
        "inline=1;height=-3px",
        "inline=1;width=3em",
    ] {
        // 50 px high is 3 rows of 20.
        check(args, (100, 50), (0, 0), 3);
    }
}

#[test]
fn an_image_of_no_known_size_moves_the_cursor_by_the_rows_asked_or_one() {
    let data = base64::engine::general_purpose::STANDARD.encode(b"not an image header");
    let got = place(&mut terminal(), "inline=1;height=2", &data);
    assert_eq!((got.stored, got.cells, got.row), ((0, 0), (0, 2), 2));
    let got = place(&mut terminal(), "inline=1;width=4", &data);
    assert_eq!((got.stored, got.cells, got.row), ((0, 0), (4, 0), 1));
}

#[test]
fn a_huge_request_is_capped_in_cells_and_allocates_nothing_for_it() {
    // A huge width on a 10x10 image: 1024 cells, a 10240 px square, 512 rows.
    let got = place(&mut terminal(), "inline=1;width=4000000000", &png(10, 10));
    assert_eq!((got.stored, got.cells), ((10, 10), (1024, 0)));
    let mut term = terminal();
    let got = place(&mut term, "inline=1;height=1000000000px", &png(10, 10));
    assert_eq!((got.stored, got.cells), ((10, 10), (0, 1024)));
    // Only the encoded image is held, never the drawn size.
    assert!(term.graphics.retained_capacity_bytes() < 1024 * 1024);
}

#[test]
fn an_image_over_the_memory_cap_is_refused_however_small_it_is_drawn() {
    let mut term = terminal();
    // A 100x50 image decodes to 20000 bytes; the pane allows one byte less.
    term.set_max_image_memory_bytes(100 * 50 * 4 - 1);
    term.feed(format!("\x1b]1337;File=inline=1;width=1:{}\x07", png(100, 50)).as_bytes());
    assert!(
        term.graphics_placements().is_empty(),
        "a 1-cell box does not make it smaller"
    );
    assert_eq!(term.cursor.row, 0, "nothing placed, nothing to move past");
}

#[test]
fn without_a_pixel_size_cells_are_taken_as_ten_by_twenty() {
    let mut term = Terminal::new(80, 24);
    term.feed(b"\x1b[H");
    // 4 cells of 10 px: 40 px wide, so a 2:1 image is 20 px high, 1 row.
    let got = place(&mut term, "inline=1;width=4", &png(100, 50));
    assert_eq!((got.stored, got.cells, got.row), ((100, 50), (4, 0), 1));
}

#[test]
fn the_box_survives_a_checkpoint_and_an_old_record_imports_as_it_was() {
    let mut term = terminal();
    place(&mut term, "inline=1;width=20;height=3", &png(100, 50));
    place(&mut term, "inline=1", &png(30, 20));
    let back = import(&export(&term).expect("export")).expect("import");
    let boxes: Vec<_> = back
        .graphics_placements()
        .iter()
        .map(|p| (p.options.columns, p.options.rows))
        .collect();
    assert_eq!(
        boxes,
        [(20, 3), (0, 0)],
        "a box and a natural-size placement"
    );
    let image = back
        .graphics_image(back.graphics_placements()[0].image_id)
        .unwrap();
    assert_eq!((image.width, image.height), (100, 50));

    // Before the box, a width was written into the stored size: 200x50 beside
    // a 100x50 image. Such a record imports unchanged -- the renderers'
    // own checks refuse to draw it -- and the session carries on.
    let mut old = terminal();
    place(&mut old, "inline=1", &png(100, 50));
    let id = old.graphics_placements()[0].image_id;
    old.graphics.images.get_mut(&id).unwrap().width = 200;
    let mut back = import(&export(&old).expect("export")).expect("an old record imports");
    let image = back.graphics_image(id).unwrap();
    assert_eq!(
        (image.width, image.height),
        (200, 50),
        "not rewritten on import"
    );
    back.feed(b"\r\nstill here");
    assert!(back.plain_string().contains("still here"));
}

#[test]
fn a_non_inline_file_is_not_placed() {
    let mut term = terminal();
    term.feed(format!("\x1b]1337;File=inline=0;width=4:{}\x07", png(10, 10)).as_bytes());
    assert!(term.graphics_placements().is_empty());
}

#[test]
fn copy_keys_set_the_clipboard_unless_it_is_disabled() {
    let mut term = terminal();
    let hello = base64::engine::general_purpose::STANDARD.encode("hello");
    term.feed(format!("\x1b]1337;CopyToClipboard={hello}\x07").as_bytes());
    term.feed(format!("\x1b]1337;Copy=:{hello}\x07").as_bytes());
    term.feed(format!("\x1b]1337;Copy={hello}\x07").as_bytes());
    let sets: Vec<_> = term
        .take_events()
        .into_iter()
        .filter(|e| matches!(e, TerminalEvent::ClipboardSet(t) if t == "hello"))
        .collect();
    assert_eq!(sets.len(), 3, "each copy form sets the clipboard");

    term.set_clipboard_policy(ClipboardPolicy::Disabled);
    term.feed(format!("\x1b]1337;CopyToClipboard={hello}\x07").as_bytes());
    assert!(
        !term
            .take_events()
            .iter()
            .any(|e| matches!(e, TerminalEvent::ClipboardSet(_)))
    );
}

#[test]
fn status_keys_set_and_clear_the_status() {
    let mut term = terminal();
    term.feed(b"\x1b]1337;SetStatus=Thinking;text=Reading the repo\x07");
    term.feed(b"\x1b]1337;SetStatus=done\x07");
    term.feed(b"\x1b]1337;SetStatus=clear\x07");
    term.feed(b"\x1b]1337;ClearStatus\x07");
    term.feed(b"\x1b]1337;SetStatus=dancing\x07");
    assert_eq!(
        term.take_events(),
        [
            TerminalEvent::StatusSet {
                status: "working".into(),
                text: Some("Reading the repo".into())
            },
            TerminalEvent::StatusSet {
                status: "done".into(),
                text: None
            },
            TerminalEvent::StatusClear,
            TerminalEvent::StatusClear,
        ],
        "an unknown status says nothing"
    );
}
