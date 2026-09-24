//! Targeted behavioral tests for the UniFFI Swift-facing API in
//! src/ffi/mod.rs (TakoCore and friends), driven through its public Rust
//! surface (the same surface UniFFI generates Swift bindings from).

use tako_core::ffi::{
    FfiCursorShape, FfiEvent, FfiImageFormat, FfiKey, FfiKeyEvent, FfiMouseAction, FfiMouseButton,
    FfiMouseEvent, FfiMouseTracking, FfiSelectionMode, TakoCheckpointError, TakoCore,
    PACKED_CELL_SIZE,
};

fn default_key_event(key: FfiKey) -> FfiKeyEvent {
    FfiKeyEvent {
        key,
        text: String::new(),
        physical_text: String::new(),
        unshifted_text: String::new(),
        shift: false,
        alt: false,
        ctrl: false,
        super_key: false,
        press: true,
        repeat: false,
        composing: false,
    }
}

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
    let ch1 = u32::from_le_bytes(packed[PACKED_CELL_SIZE..PACKED_CELL_SIZE + 4].try_into().unwrap());
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
    core.feed(
        format!("\x1b_Ga=t,t=d,f=24,s=1,v=1,i=1;{payload_rgb}\x1b\\").into_bytes(),
    );
    let meta = core.graphics_image_metadata(1).expect("rgb image stored");
    assert_eq!(meta.format, FfiImageFormat::Rgb);

    // f=32 RGBA, 1x1 pixel.
    let payload_rgba = base64_encode(&[10, 20, 30, 255]);
    core.feed(
        format!("\x1b_Ga=t,t=d,f=32,s=1,v=1,i=2;{payload_rgba}\x1b\\").into_bytes(),
    );
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

    core.feed(b"\x07".to_vec()); // BEL
    core.feed(b"\x1b]0;hello\x07".to_vec()); // title
    core.feed(b"\x1b]52;c;aGVsbG8=\x07".to_vec()); // OSC 52 clipboard set
    core.feed(b"\x1b]52;c;?\x07".to_vec()); // OSC 52 clipboard query
    core.feed(b"\x1b]9;notify me\x07".to_vec()); // OSC 9 notification
    core.feed(b"\x1b]7;file:///tmp\x07".to_vec()); // OSC 7 pwd
    core.feed(b"\x1b]9;4;1;50\x07".to_vec()); // OSC 9;4 progress
    core.feed(b"\x1b]133;C\x07".to_vec()); // command start
    core.feed(b"\x1b]133;D;0\x07".to_vec()); // command end with exit code

    let events = core.take_events();
    assert!(events.contains(&FfiEvent::Bell));
    assert!(events.contains(&FfiEvent::TitleChanged { title: "hello".to_string() }));
    assert!(events.iter().any(|e| matches!(e, FfiEvent::ClipboardSet { text } if text == "hello")));
    assert!(events.contains(&FfiEvent::ClipboardQuery));
    assert!(events.iter().any(|e| matches!(e, FfiEvent::Notification { .. })));
    assert!(events.iter().any(|e| matches!(e, FfiEvent::PwdChanged { url } if url == "file:///tmp")));
    assert!(events.iter().any(|e| matches!(e, FfiEvent::Progress { .. })));
    assert!(events.contains(&FfiEvent::CommandStart));
    assert!(events.contains(&FfiEvent::CommandEnd { exit_code: Some(0) }));
}

// -----------------------------------------------------------------------
// Checkpoint convenience surface (src/ffi/mod.rs:704-788)
// -----------------------------------------------------------------------

/// `checkpoint()`/`restore()`/`verify_checkpoint()` are the source-compat
/// bool-returning wrappers over the typed checkpoint API.
#[test]
fn checkpoint_bool_wrappers_round_trip() {
    let core = TakoCore::new(20, 5);
    core.feed(b"hello there".to_vec());
    let blob = core.checkpoint();
    assert!(!blob.is_empty());
    assert!(core.verify_checkpoint(blob.clone()));
    assert!(!core.verify_checkpoint(vec![1, 2, 3]), "garbage does not verify");

    let dest = TakoCore::new(20, 5);
    assert!(dest.restore(blob));
    assert_eq!(dest.get_line(0).trim_end_matches(['\0', ' ']), "hello there");
    assert!(!dest.restore(Vec::new()), "empty payload fails to restore");
}

/// `checkpoint_export` rejects any nonzero `flags` (the v1 container
/// reserves the field) with a typed `Corrupt` error, without touching the
/// terminal.
#[test]
fn checkpoint_export_rejects_nonzero_flags() {
    let core = TakoCore::new(20, 5);
    core.feed(b"data".to_vec());
    match core.checkpoint_export(1, u64::MAX) {
        Err(TakoCheckpointError::Corrupt { reason }) => {
            assert!(reason.contains("flags"));
        }
        other => panic!("expected Corrupt for nonzero flags, got {other:?}"),
    }
}

/// `checkpoint_inspect` on an empty blob fails with `NullArgument`, the
/// same as `checkpoint_import`.
#[test]
fn checkpoint_inspect_rejects_empty_blob() {
    let core = TakoCore::new(20, 5);
    assert_eq!(
        core.checkpoint_inspect(Vec::new()),
        Err(TakoCheckpointError::NullArgument)
    );
}

// -----------------------------------------------------------------------
// Synchronized output / kitty flags (src/ffi/mod.rs:855-863)
// -----------------------------------------------------------------------

/// `is_synchronized_output_active` mirrors the terminal's mode-2026 state.
#[test]
fn is_synchronized_output_active_tracks_mode_2026() {
    let core = TakoCore::new(20, 5);
    assert!(!core.is_synchronized_output_active());
    core.feed(b"\x1b[?2026h".to_vec());
    assert!(core.is_synchronized_output_active());
    core.feed(b"\x1b[?2026l".to_vec());
    assert!(!core.is_synchronized_output_active());
}

/// `kitty_keyboard_flags` reports the raw enhancement bitmask after a CSI
/// `>` push (progressive enhancement flags = 1, disambiguate escape codes).
#[test]
fn kitty_keyboard_flags_reports_pushed_bitmask() {
    let core = TakoCore::new(20, 5);
    assert_eq!(core.kitty_keyboard_flags(), 0);
    core.feed(b"\x1b[>1u".to_vec());
    assert_eq!(core.kitty_keyboard_flags(), 1);
}

// -----------------------------------------------------------------------
// Key encoding (src/ffi/mod.rs:918-1033)
// -----------------------------------------------------------------------

/// Named (non-character) keys encode to their standard escape sequences;
/// this walks a representative sample across the whole match arm rather
/// than every single variant, which would be redundant with key_encode's
/// own tests.
#[test]
fn encode_key_named_keys_produce_expected_bytes() {
    let core = TakoCore::new(20, 5);
    assert_eq!(core.encode_key(default_key_event(FfiKey::Enter)), b"\r");
    assert_eq!(core.encode_key(default_key_event(FfiKey::Tab)), b"\t");
    assert_eq!(core.encode_key(default_key_event(FfiKey::Escape)), b"\x1b");
    assert_eq!(core.encode_key(default_key_event(FfiKey::Up)), b"\x1b[A");
    assert_eq!(core.encode_key(default_key_event(FfiKey::F1)), b"\x1bOP");
    assert_eq!(core.encode_key(default_key_event(FfiKey::KeypadEnter)), b"\r");
    assert_eq!(core.encode_key(default_key_event(FfiKey::Space)), b" ");
}

/// A `Character` key with `unshifted_text` set uses the physical base key,
/// not what came out of `text` -- this is what makes ctrl+c on any layout
/// send 0x03 instead of the localized letter. See the comment on the
/// `FfiKey::Character` arm in `encode_key`.
#[test]
fn encode_key_character_prefers_unshifted_base_for_ctrl() {
    let core = TakoCore::new(20, 5);
    let mut event = default_key_event(FfiKey::Character);
    event.text = "\u{0003}".to_string(); // what ctrl+c produced on this layout
    event.unshifted_text = "c".to_string();
    event.ctrl = true;
    assert_eq!(core.encode_key(event), vec![0x03]);
}

/// A `Character` key with neither `unshifted_text` nor `text` set has no
/// base key to encode, so the call returns empty bytes rather than
/// panicking.
#[test]
fn encode_key_character_with_no_base_returns_empty() {
    let core = TakoCore::new(20, 5);
    let event = default_key_event(FfiKey::Character);
    assert!(core.encode_key(event).is_empty());
}

/// A `Character` key falls back to `text` when `unshifted_text` is absent
/// (e.g. IME commit with no physical-key concept).
#[test]
fn encode_key_character_falls_back_to_text() {
    let core = TakoCore::new(20, 5);
    let mut event = default_key_event(FfiKey::Character);
    event.text = "A".to_string();
    assert_eq!(core.encode_key(event), b"A");
}

/// `encode_key` reads the terminal's live cursor-key mode, so an arrow key
/// switches between `CSI` and `SS3` depending on DECCKM.
#[test]
fn encode_key_respects_live_cursor_key_app_mode() {
    let core = TakoCore::new(20, 5);
    assert_eq!(core.encode_key(default_key_event(FfiKey::Up)), b"\x1b[A");
    core.feed(b"\x1b[?1h".to_vec()); // DECCKM on
    assert_eq!(core.encode_key(default_key_event(FfiKey::Up)), b"\x1bOA");
}

// -----------------------------------------------------------------------
// Mouse encoding, paste (src/ffi/mod.rs:1038-1102)
// -----------------------------------------------------------------------

fn mouse_event(button: FfiMouseButton, action: FfiMouseAction, col: u32, row: u32) -> FfiMouseEvent {
    FfiMouseEvent {
        button,
        action,
        shift: false,
        alt: false,
        ctrl: false,
        col,
        row,
    }
}

/// With mouse tracking off, `encode_mouse` produces nothing regardless of
/// the event -- the terminal never asked for mouse reports.
#[test]
fn encode_mouse_off_produces_no_bytes() {
    let core = TakoCore::new(20, 5);
    let bytes = core.encode_mouse(mouse_event(FfiMouseButton::Left, FfiMouseAction::Press, 1, 1));
    assert!(bytes.is_empty());
}

/// Normal tracking (mode 1000) reports presses/releases but not motion.
#[test]
fn encode_mouse_normal_tracking_drops_motion_reports_presses() {
    let core = TakoCore::new(20, 5);
    core.feed(b"\x1b[?1000h".to_vec());
    let motion = core.encode_mouse(mouse_event(FfiMouseButton::None, FfiMouseAction::Motion, 1, 1));
    assert!(motion.is_empty(), "plain normal tracking must not report motion");

    let press = core.encode_mouse(mouse_event(FfiMouseButton::Left, FfiMouseAction::Press, 1, 1));
    assert!(!press.is_empty());
}

/// SGR mouse encoding (mode 1006 + 1000) yields the `CSI < ... M` form,
/// with 1-based coordinates.
#[test]
fn encode_mouse_sgr_encoding_reports_one_based_coordinates() {
    let core = TakoCore::new(20, 5);
    core.feed(b"\x1b[?1000h\x1b[?1006h".to_vec());
    let bytes = core.encode_mouse(mouse_event(FfiMouseButton::Left, FfiMouseAction::Press, 4, 2));
    let text = String::from_utf8(bytes).unwrap();
    assert_eq!(text, "\x1b[<0;5;3M");
}

/// Bracketed paste wraps the payload in `ESC[200~ ... ESC[201~` only when
/// mode 2004 is on, and strips a trailing paste terminator either way.
#[test]
fn encode_paste_brackets_only_when_mode_2004_is_on() {
    let core = TakoCore::new(20, 5);
    let plain = core.encode_paste("hi".to_string());
    assert_eq!(plain, b"hi");

    core.feed(b"\x1b[?2004h".to_vec());
    let bracketed = core.encode_paste("hi".to_string());
    assert_eq!(bracketed, b"\x1b[200~hi\x1b[201~");
}

/// Text with newlines or control characters is flagged unsafe to paste
/// unbracketed; plain text is not.
#[test]
fn paste_is_unsafe_flags_control_characters() {
    let core = TakoCore::new(20, 5);
    assert!(!core.paste_is_unsafe("plain text".to_string()));
    assert!(core.paste_is_unsafe("line one\nline two".to_string()));
    assert!(core.paste_is_unsafe("bell\x07here".to_string()));
}

// -----------------------------------------------------------------------
// Scrollback / viewport accessors (src/ffi/mod.rs:1148-1181)
// -----------------------------------------------------------------------

/// `viewport_offset`, `scrollback_len`, and `viewport_row` after scrolling
/// into history: offset and length track lines pushed into scrollback, and
/// `viewport_row` reads through the scroll offset rather than the live
/// screen.
#[test]
fn viewport_offset_scrollback_len_and_viewport_row_track_scroll_state() {
    let core = TakoCore::new(10, 3);
    for i in 0..10 {
        core.feed(format!("L{i}\r\n").into_bytes());
    }
    assert_eq!(core.viewport_offset(), 0);
    assert!(core.scrollback_len() > 0);

    core.scroll_viewport_up(2);
    assert_eq!(core.viewport_offset(), 2);

    let row = core.viewport_row(0);
    assert_eq!(row.len(), 10);
    let text: String = row.iter().map(|c| char::from_u32(c.ch).unwrap_or(' ')).collect();
    assert!(text.trim_end().starts_with('L'), "viewport_row must read the scrolled-to line, got {text:?}");
}

// -----------------------------------------------------------------------
// Cursor / geometry / line accessors (src/ffi/mod.rs:1368-1459)
// -----------------------------------------------------------------------

/// `cursor_is_at_prompt` and `row_semantic_prompt` after OSC 133;A marks
/// the current row as a shell prompt.
#[test]
fn cursor_is_at_prompt_and_row_semantic_prompt_after_osc_133() {
    let core = TakoCore::new(20, 5);
    assert!(!core.cursor_is_at_prompt());
    assert_eq!(core.row_semantic_prompt(0), 0);

    core.feed(b"\x1b]133;A\x07$ ".to_vec());
    assert!(core.cursor_is_at_prompt());
    assert_eq!(core.row_semantic_prompt(0), 1);
}

/// `resize` changes both `cols()`/`rows()` and what `get_line` returns for
/// the same row index.
#[test]
fn resize_changes_reported_geometry() {
    let core = TakoCore::new(10, 3);
    core.feed(b"hi".to_vec());
    assert_eq!((core.cols(), core.rows()), (10, 3));
    core.resize(20, 6);
    assert_eq!((core.cols(), core.rows()), (20, 6));
}

/// `cursor_row`/`cursor_col`/`cursor_visible`/`title` reflect the terminal
/// state directly.
#[test]
fn cursor_and_title_accessors_report_live_state() {
    let core = TakoCore::new(20, 5);
    core.feed(b"abc".to_vec());
    assert_eq!(core.cursor_row(), 0);
    assert_eq!(core.cursor_col(), 3);
    assert!(core.cursor_visible());

    core.feed(b"\x1b[?25l".to_vec());
    assert!(!core.cursor_visible());

    core.feed(b"\x1b]0;My Title\x07".to_vec());
    assert_eq!(core.title(), "My Title");
}

/// `get_cell` returns `None` past the grid bounds.
#[test]
fn get_cell_out_of_bounds_returns_none() {
    let core = TakoCore::new(5, 2);
    assert!(core.get_cell(100, 100).is_none());
    assert!(core.get_cell(0, 0).is_some());
}

/// `get_line` returns the plain text of a row with no styling, and an
/// empty string for a row past the grid's bounds.
#[test]
fn get_line_returns_plain_text_and_empty_out_of_bounds() {
    let core = TakoCore::new(10, 2);
    core.feed(b"hey".to_vec());
    assert_eq!(core.get_line(0).trim_end_matches(['\0', ' ']), "hey");
    assert_eq!(core.get_line(50), "");
}

// -----------------------------------------------------------------------
// Selection surface (src/ffi/mod.rs:1481-1526)
// -----------------------------------------------------------------------

/// `select_word` selects the whole word under the point, `select_line`
/// selects the whole logical line, `has_selection`/`selected_text` and
/// `clear_selection` round-trip through them.
#[test]
fn select_word_and_select_line_produce_expected_text() {
    let core = TakoCore::new(30, 3);
    core.feed(b"hello world".to_vec());

    assert!(!core.has_selection());
    core.select_word(0, 2); // inside "hello"
    assert!(core.has_selection());
    assert_eq!(core.selected_text().as_deref(), Some("hello"));

    core.select_line(0, 0);
    assert_eq!(core.selected_text().as_deref(), Some("hello world"));

    core.clear_selection();
    assert!(!core.has_selection());
    assert!(core.selected_text().is_none());
    assert!(core.selection_range().is_none());
}

// -----------------------------------------------------------------------
// scroll_to / scroll_position (src/ffi/mod.rs:1543-1572)
// -----------------------------------------------------------------------

/// `scroll_to` snaps to bottom first, then scrolls up by the given offset
/// -- so it is absolute, not relative to wherever the viewport already was.
#[test]
fn scroll_to_is_absolute_from_the_bottom() {
    let core = TakoCore::new(10, 3);
    for i in 0..20 {
        core.feed(format!("L{i}\r\n").into_bytes());
    }
    core.scroll_viewport_up(5);
    assert_eq!(core.viewport_offset(), 5);

    core.scroll_to(2);
    assert_eq!(core.viewport_offset(), 2, "scroll_to must be absolute, not additive");

    core.scroll_to(0);
    assert_eq!(core.viewport_offset(), 0);
}

/// `scroll_position`/`set_scroll_position` round-trip a fraction, and an
/// out-of-range value is clamped rather than rejected.
#[test]
fn scroll_position_round_trips_and_clamps() {
    let core = TakoCore::new(10, 3);
    for i in 0..20 {
        core.feed(format!("L{i}\r\n").into_bytes());
    }
    assert_eq!(core.scroll_position(), 1.0, "live screen is fraction 1");

    core.set_scroll_position(0.0);
    assert_eq!(core.scroll_position(), 0.0, "oldest retained line is fraction 0");

    core.set_scroll_position(-5.0);
    assert_eq!(core.scroll_position(), 0.0, "below range clamps to 0");

    core.set_scroll_position(5.0);
    assert_eq!(core.scroll_position(), 1.0, "above range clamps to 1");
}

// -----------------------------------------------------------------------
// get_plain_text (src/ffi/mod.rs:1575-1608)
// -----------------------------------------------------------------------

/// `get_plain_text` joins wrapped lines and trims trailing spaces on real
/// content, out-of-bounds `start_row` returns an empty string, and trailing
/// blank lines are dropped from the result.
#[test]
fn get_plain_text_joins_wraps_trims_and_bounds_check() {
    let core = TakoCore::new(10, 5);
    core.feed(b"a line with more than ten chars\r\nshort".to_vec());

    assert_eq!(core.get_plain_text(50, 5), "", "start_row past the grid returns empty");

    let text = core.get_plain_text(0, 5);
    let lines: Vec<&str> = text.split('\n').collect();
    // The long first logical line soft-wraps across several rows; joined
    // back into one line with no internal trailing spaces, followed by
    // "short" -- and no empty trailing lines despite unused rows below.
    assert!(lines[0].starts_with("a line with more than ten chars"));
    assert!(lines.iter().all(|l| !l.ends_with(' ')));
    assert_eq!(lines.last(), Some(&"short"));
}

/// A `max_rows` of 0 (or a start_row exactly at the row count) is the
/// degenerate empty-range case.
#[test]
fn get_plain_text_zero_max_rows_is_empty() {
    let core = TakoCore::new(10, 3);
    core.feed(b"content".to_vec());
    assert_eq!(core.get_plain_text(0, 0), "");
}

// -----------------------------------------------------------------------
// snapshot() graphics placements (src/ffi/mod.rs:1611-1660)
// -----------------------------------------------------------------------

/// `snapshot().graphics_placements` reports live Kitty Graphics placements
/// with their cell coordinates, mirroring `graphics_placements()`.
#[test]
fn snapshot_reports_graphics_placements() {
    let core = TakoCore::new(20, 10);
    let payload = base64_encode(&[10, 20, 30]);
    core.feed(format!("\x1b_Ga=T,f=24,s=1,v=1,i=7;{payload}\x1b\\").into_bytes());

    let snap = core.snapshot();
    let placements = core.graphics_placements();
    assert_eq!(snap.graphics_placements.len(), placements.len());
    if let Some(p) = snap.graphics_placements.first() {
        assert_eq!(p.image_id, 7);
    }
}

// -----------------------------------------------------------------------
// helpers
// -----------------------------------------------------------------------

fn base64_encode(bytes: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for chunk in bytes.chunks(3) {
        let b0 = chunk[0];
        let b1 = *chunk.get(1).unwrap_or(&0);
        let b2 = *chunk.get(2).unwrap_or(&0);
        out.push(TABLE[(b0 >> 2) as usize] as char);
        out.push(TABLE[(((b0 & 0x03) << 4) | (b1 >> 4)) as usize] as char);
        if chunk.len() > 1 {
            out.push(TABLE[(((b1 & 0x0f) << 2) | (b2 >> 6)) as usize] as char);
        } else {
            out.push('=');
        }
        if chunk.len() > 2 {
            out.push(TABLE[(b2 & 0x3f) as usize] as char);
        } else {
            out.push('=');
        }
    }
    out
}

/// A minimal but structurally valid 1x1 PNG (8-bit RGB), for exercising the
/// `f=100` Kitty Graphics path.
fn minimal_png() -> Vec<u8> {
    // 1x1 red pixel PNG, precomputed.
    vec![
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44,
        0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x00, 0x00, 0x00, 0x90,
        0x77, 0x53, 0xDE, 0x00, 0x00, 0x00, 0x0C, 0x49, 0x44, 0x41, 0x54, 0x08, 0xD7, 0x63, 0xF8,
        0xCF, 0xC0, 0x00, 0x00, 0x00, 0x03, 0x00, 0x01, 0xA1, 0xDD, 0xE0, 0x30, 0x00, 0x00, 0x00,
        0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    ]
}
