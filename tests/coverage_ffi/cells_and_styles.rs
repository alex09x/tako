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

// -----------------------------------------------------------------------
// Color resolution / cell packing (src/ffi/mod.rs:30-140, 1687-1721)
// -----------------------------------------------------------------------

/// `Color::Rgb`/`Color::Indexed` must resolve through the live palette, and
/// wide-spacer tails must report `ch == 0` so a renderer doesn't double
/// advance past a CJK glyph. Exercised through `get_cell`, which calls
/// `resolve_color` and `cell_to_ffi` directly.
#[test]
fn get_cell_resolves_rgb_and_indexed_colors_and_wide_spacer() {
    let core = TakoCore::new(20, 4);
    // Explicit truecolor fg/bg (SGR 38/48;2).
    core.feed(b"\x1b[38;2;10;20;30m\x1b[48;2;40;50;60mX".to_vec());
    let cell = core.get_cell(0, 0).unwrap();
    assert_eq!((cell.fg_r, cell.fg_g, cell.fg_b), (10, 20, 30));
    assert_eq!((cell.bg_r, cell.bg_g, cell.bg_b), (40, 50, 60));
    assert_eq!(cell.ch, u32::from('X'));

    // Indexed color (SGR 38;5;196 is a bright red in the default 256 palette).
    core.feed(b"\x1b[0m\x1b[38;5;196mY".to_vec());
    let cell = core.get_cell(0, 1).unwrap();
    assert_eq!((cell.fg_r, cell.fg_g, cell.fg_b), (0xFF, 0, 0));

    // A wide (CJK) character: the tail cell carries `ch == 0` so a
    // renderer never double-advances past the glyph.
    core.feed(b"\x1b[0m\xe4\xb8\xad".to_vec()); // U+4E2D, double-width
    let head = core.get_cell(0, 2).unwrap();
    let tail = core.get_cell(0, 3).unwrap();
    assert_eq!(head.ch, u32::from('\u{4e2d}'));
    assert_eq!(tail.ch, 0, "the tail of a wide pair carries no character");
}

/// `FfiCell::wide` flags the column a wide glyph had to abandon when it
/// didn't fit before the right margin and wrapped to the next row --
/// upstream leaves a blank spacer-head there so a renderer never paints a
/// half-glyph in the gap.
#[test]
fn wide_glyph_wrap_leaves_spacer_head_marker() {
    let core = TakoCore::new(3, 2);
    core.feed(b"AB".to_vec()); // fills columns 0 and 1; cursor parks at col 2
    core.feed("\u{4e2d}".as_bytes().to_vec()); // doesn't fit in 1 column, wraps

    let abandoned = core.get_cell(0, 2).unwrap();
    assert!(abandoned.wide, "the abandoned column must flag `wide`");

    let head = core.get_cell(1, 0).unwrap();
    let tail = core.get_cell(1, 1).unwrap();
    assert_eq!(head.ch, u32::from('\u{4e2d}'));
    assert_eq!(tail.ch, 0, "the tail of a wide pair carries no character");
}

/// `Color::Default` falls back to the caller-visible default fg/bg, and a
/// null byte in the grid packs as a space rather than NUL -- both asserted
/// through `viewport_packed`'s byte layout (offsets documented on the
/// struct: ch=0..4, fg=4..7, bg=7..10).
#[test]
fn viewport_packed_layout_matches_documented_offsets() {
    let core = TakoCore::new(3, 1);
    core.feed(b"A".to_vec());
    let packed = core.viewport_packed();
    assert_eq!(packed.len(), 3 * PACKED_CELL_SIZE);

    // Cell 0: 'A' on default colors.
    let ch = u32::from_le_bytes(packed[0..4].try_into().unwrap());
    assert_eq!(ch, u32::from('A'));
    let cell = core.get_cell(0, 0).unwrap();
    assert_eq!(packed[4], cell.fg_r);
    assert_eq!(packed[5], cell.fg_g);
    assert_eq!(packed[6], cell.fg_b);
    assert_eq!(packed[7], cell.bg_r);
    assert_eq!(packed[8], cell.bg_g);
    assert_eq!(packed[9], cell.bg_b);

    // Cell 1: untouched grid cell (internal NUL) packs as a space, not 0.
    let ch1 = u32::from_le_bytes(
        packed[PACKED_CELL_SIZE..PACKED_CELL_SIZE + 4]
            .try_into()
            .unwrap(),
    );
    assert_eq!(ch1, u32::from(' '));
}

/// The SGR underline-color override (58;2;r;g;b) resolves through the
/// palette too, and falls back to the foreground when unset.
#[test]
fn get_cell_underline_color_falls_back_to_foreground() {
    let core = TakoCore::new(10, 1);
    core.feed(b"\x1b[38;2;9;9;9mplain".to_vec());
    let plain = core.get_cell(0, 0).unwrap();
    assert_eq!((plain.ul_r, plain.ul_g, plain.ul_b), (9, 9, 9));

    core.feed(b"\x1b[0m\x1b[58;2;1;2;3mU".to_vec());
    let styled = core.get_cell(0, 5).unwrap();
    assert_eq!((styled.ul_r, styled.ul_g, styled.ul_b), (1, 2, 3));
}

// -----------------------------------------------------------------------
// Enum conversions (src/ffi/mod.rs:152-336)
// -----------------------------------------------------------------------

/// Round-trips every `FfiSelectionMode` variant through `start_selection`/
/// `selection_range` -- covers both directions of the `From` impls,
/// including `Rectangular`.
#[test]
fn selection_mode_round_trips_linear_and_rectangular() {
    let core = TakoCore::new(20, 5);
    core.feed(b"hello\r\nworld\r\nfoo\r\nbar\r\nbaz".to_vec());

    core.start_selection(0, 0, FfiSelectionMode::Linear);
    core.extend_selection(1, 2);
    let range = core.selection_range().unwrap();
    assert_eq!(range.mode, FfiSelectionMode::Linear);

    core.clear_selection();
    core.start_selection(0, 0, FfiSelectionMode::Rectangular);
    core.extend_selection(2, 3);
    let range = core.selection_range().unwrap();
    assert_eq!(range.mode, FfiSelectionMode::Rectangular);
}

/// Every `FfiMouseTracking` variant, reached by feeding the corresponding
/// DEC private mode and reading it back through `modes()`.
#[test]
fn mouse_tracking_modes_report_every_variant() {
    let core = TakoCore::new(20, 5);
    assert_eq!(core.modes().mouse_tracking, FfiMouseTracking::Off);

    core.feed(b"\x1b[?1000h".to_vec());
    assert_eq!(core.modes().mouse_tracking, FfiMouseTracking::Normal);

    core.feed(b"\x1b[?1002h".to_vec());
    assert_eq!(core.modes().mouse_tracking, FfiMouseTracking::ButtonEvent);

    core.feed(b"\x1b[?1003h".to_vec());
    assert_eq!(core.modes().mouse_tracking, FfiMouseTracking::AnyEvent);

    core.feed(b"\x1b[?1003l".to_vec());
    assert_eq!(core.modes().mouse_tracking, FfiMouseTracking::Off);
}

/// Every `FfiImageFormat` variant, via `graphics_image_metadata` after a
/// Kitty Graphics image transmission (`a=t`) in each format.
#[test]
fn graphics_image_metadata_reports_every_format() {
    let core = TakoCore::new(20, 10);

    // f=24 RGB, 1x1 pixel, t=d (data inline in the APC, not a file).
    let payload_rgb = base64_encode(&[10, 20, 30]);
    core.feed(format!("\x1b_Ga=t,t=d,f=24,s=1,v=1,i=1;{payload_rgb}\x1b\\").into_bytes());
    let meta = core.graphics_image_metadata(1).expect("rgb image stored");
    assert_eq!(meta.format, FfiImageFormat::Rgb);

    // f=32 RGBA, 1x1 pixel.
    let payload_rgba = base64_encode(&[10, 20, 30, 255]);
    core.feed(format!("\x1b_Ga=t,t=d,f=32,s=1,v=1,i=2;{payload_rgba}\x1b\\").into_bytes());
    let meta = core.graphics_image_metadata(2).expect("rgba image stored");
    assert_eq!(meta.format, FfiImageFormat::Rgba);

    // f=100 PNG: a minimal valid 1x1 PNG.
    let png_bytes = minimal_png();
    let payload_png = base64_encode(&png_bytes);
    core.feed(format!("\x1b_Ga=t,t=d,f=100,i=3;{payload_png}\x1b\\").into_bytes());
    let meta = core.graphics_image_metadata(3).expect("png image stored");
    assert_eq!(meta.format, FfiImageFormat::Png);
}

/// Every `FfiCursorShape` variant, via DECSCUSR params 1..6 mapped by
/// `cursor_style()`. Upstream/xterm DECSCUSR: 0/1 block blink, 2
/// block steady, 3/4 underline, 5/6 bar.
#[test]
fn cursor_style_reports_every_shape() {
    let core = TakoCore::new(20, 5);

    core.feed(b"\x1b[1 q".to_vec());
    assert_eq!(core.cursor_style().shape, FfiCursorShape::Block);
    assert!(core.cursor_style().blinking);

    core.feed(b"\x1b[3 q".to_vec());
    assert_eq!(core.cursor_style().shape, FfiCursorShape::Underline);

    core.feed(b"\x1b[6 q".to_vec());
    assert_eq!(core.cursor_style().shape, FfiCursorShape::Bar);
    assert!(!core.cursor_style().blinking);
}

/// Every `FfiEvent` variant, drained via `take_events` after triggering the
/// terminal-level event that produces it.
#[test]
fn take_events_reports_every_variant() {
    let core = TakoCore::new(40, 10);
    assert!(!core.is_clipboard_read_allowed());
    core.set_clipboard_read_allowed(true);
    assert!(core.is_clipboard_read_allowed());

    core.feed(b"\x07".to_vec()); // BEL
    core.feed(b"\x1b]0;hello\x07".to_vec()); // title
    core.feed(b"\x1b]52;c;aGVsbG8=\x07".to_vec()); // OSC 52 clipboard set
    core.feed(b"\x1b]52;c;?\x07".to_vec()); // OSC 52 clipboard query
    core.feed(b"\x1b]9;notify me\x07".to_vec()); // OSC 9 notification
    core.feed(b"\x1b]7;file:///tmp\x07".to_vec()); // OSC 7 pwd
    core.feed(b"\x1b]9;4;1;50\x07".to_vec()); // OSC 9;4 progress
    core.feed(b"\x1b]133;C\x07".to_vec()); // command start
    core.feed(b"\x1b]133;D;0\x07".to_vec()); // command end with exit code
    core.feed(b"\x1b]99;;Hello OSC 99\x1b\\".to_vec()); // OSC 99 notification
    core.feed(b"\x1b]99;i=c1:p=close:c=1;\x1b\\".to_vec()); // OSC 99 close

    let events = core.take_events();
    assert!(events.contains(&FfiEvent::Bell));
    assert!(events.contains(&FfiEvent::TitleChanged {
        title: "hello".to_string()
    }));
    assert!(
        events
            .iter()
            .any(|e| matches!(e, FfiEvent::ClipboardSet { text } if text == "hello"))
    );
    assert!(events.contains(&FfiEvent::ClipboardQuery));
    assert!(
        events
            .iter()
            .any(|e| matches!(e, FfiEvent::Notification { .. }))
    );
    assert!(
        events
            .iter()
            .any(|e| matches!(e, FfiEvent::PwdChanged { url } if url == "file:///tmp"))
    );
    assert!(
        events
            .iter()
            .any(|e| matches!(e, FfiEvent::Progress { .. }))
    );
    assert!(events.contains(&FfiEvent::CommandStart { id: Some(1) }));
    assert!(events.contains(&FfiEvent::CommandEnd { exit_code: Some(0) }));
    assert!(events.iter().any(
        |e| matches!(e, FfiEvent::StructuredNotification { title, .. } if title == "Hello OSC 99")
    ));
    assert!(events.contains(&FfiEvent::NotificationClose {
        id: "c1".to_string(),
        report_close: true
    }));
}
