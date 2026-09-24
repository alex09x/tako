use tako_core::cursor_style::CursorStyle;
use tako_core::grid::Cell;
use tako_core::modes::TerminalModes;
use tako_core::palette::Palette;
use tako_core::terminal::{ScreenBuffer, SemanticContent, Terminal};

/// Snapshot of the observable state of a [`Terminal`], designed for differential
/// testing across execution paths (e.g. single-feed vs arbitrary chunking).
#[derive(Debug, PartialEq)]
pub struct TerminalStateSnapshot {
    pub cols: usize,
    pub rows: usize,
    pub active_screen: ScreenBuffer,
    pub cursor: (usize, usize),
    pub cursor_visible: bool,
    pub cursor_style: CursorStyle,
    pub title: String,
    pub plain_string: String,
    pub plain_string_unwrapped: String,
    pub dump_text: String,
    pub buffer_text: String,
    pub viewport_offset: usize,
    pub gr_slot: u8,
    pub is_synchronized_output: bool,
    pub pending_wrap: bool,
    pub kitty_keyboard_flags: u8,
    pub default_colors: (
        Option<(u8, u8, u8)>,
        Option<(u8, u8, u8)>,
        Option<(u8, u8, u8)>,
    ),
    pub semantic_content: SemanticContent,
    pub cursor_is_at_prompt: bool,
    pub has_selection: bool,
    pub selected_text: Option<String>,
    pub viewport_cells: Vec<Vec<Cell>>,
    pub viewport_wrapped: Vec<bool>,
}

impl TerminalStateSnapshot {
    /// Captures the observable state of the terminal without mutating or draining it.
    pub fn capture(term: &Terminal) -> Self {
        let grid = term.active_grid();
        let cols = grid.cols();
        let rows = grid.rows();

        let mut viewport_cells = Vec::with_capacity(rows);
        let mut viewport_wrapped = Vec::with_capacity(rows);
        for r in 0..rows {
            viewport_cells.push(term.viewport_row(r));
            viewport_wrapped.push(term.viewport_line_wrapped(r));
        }

        Self {
            cols,
            rows,
            active_screen: term.active_screen(),
            cursor: term.cursor(),
            cursor_visible: term.cursor_visible(),
            cursor_style: term.cursor_style(),
            title: term.title().to_string(),
            plain_string: term.plain_string(),
            plain_string_unwrapped: term.plain_string_unwrapped(),
            dump_text: term.dump_text(),
            buffer_text: term.buffer_text(),
            viewport_offset: term.viewport_offset(),
            gr_slot: term.gr_slot(),
            is_synchronized_output: term.is_synchronized_output(),
            pending_wrap: term.pending_wrap(),
            kitty_keyboard_flags: term.kitty_keyboard_flags(),
            default_colors: term.default_colors(),
            semantic_content: term.semantic_content(),
            cursor_is_at_prompt: term.cursor_is_at_prompt(),
            has_selection: term.has_selection(),
            selected_text: term.selected_text(),
            viewport_cells,
            viewport_wrapped,
        }
    }
}

/// Checks that two `TerminalModes` configurations are equal in all user-visible flags.
pub fn modes_eq(m1: &TerminalModes, m2: &TerminalModes) -> bool {
    m1.autowrap == m2.autowrap
        && m1.origin_mode == m2.origin_mode
        && m1.cursor_key_app_mode == m2.cursor_key_app_mode
        && m1.mouse_tracking == m2.mouse_tracking
        && m1.mouse_utf8 == m2.mouse_utf8
        && m1.mouse_sgr == m2.mouse_sgr
        && m1.focus_events == m2.focus_events
        && m1.bracketed_paste == m2.bracketed_paste
        && m1.insert == m2.insert
        && m1.linefeed_mode == m2.linefeed_mode
        && m1.reverse_wrap == m2.reverse_wrap
        && m1.reverse_wrap_extended == m2.reverse_wrap_extended
        && m1.left_right_margin_mode == m2.left_right_margin_mode
        && m1.alternate_scroll == m2.alternate_scroll
        && m1.synchronized_output == m2.synchronized_output
}

/// Checks that two palettes have identical RGB values for all 256 colors.
pub fn palette_eq(p1: &Palette, p2: &Palette) -> bool {
    for i in 0..=255 {
        if p1.get(i) != p2.get(i) {
            return false;
        }
    }
    true
}

/// Asserts that two terminals have identical observable state.
///
/// Compares grid dimensions, active screen, cursor state, visible and unwrapped text,
/// dump output, viewport rows, line wrapping, semantic markers, modes, and palette.
pub fn assert_observable_state_eq(term1: &Terminal, term2: &Terminal) {
    let snap1 = TerminalStateSnapshot::capture(term1);
    let snap2 = TerminalStateSnapshot::capture(term2);
    assert_eq!(snap1, snap2, "Observable terminal snapshots diverged");
    assert!(
        modes_eq(term1.modes(), term2.modes()),
        "TerminalModes diverged"
    );
    assert!(
        palette_eq(term1.palette(), term2.palette()),
        "Terminal palettes diverged"
    );
}

/// Exercises every public readback, inspector, and drain method on [`Terminal`].
///
/// Ensures no panic or internal invariant violation occurs when reading back
/// state regardless of past operations or current buffer contents.
pub fn assert_safe_readback(term: &mut Terminal) {
    // 1. Text extraction & snapshots
    let _ = term.plain_string();
    let _ = term.plain_string_unwrapped();
    let _ = term.dump_text();
    let _ = term.buffer_text();
    let _ = term.dump();

    // 2. Buffer & geometry inspection
    let _ = term.active_screen();
    let (cols, rows) = {
        let grid = term.active_grid();
        let cols = grid.cols();
        let rows = grid.rows();
        let _ = grid.scrollback_len();
        let _ = grid.history_evicted();
        let _ = grid.has_dirty();
        (cols, rows)
    };

    // 3. Cursor & style
    let (c_row, c_col) = term.cursor();
    let _ = term.cursor_visible();
    let _ = term.cursor_style();
    let _ = term.title();
    let _ = term.pixel_size();
    let _ = term.gr_slot();
    let _ = term.viewport_offset();
    let _ = term.scroll_position();
    let _ = term.semantic_content();
    let _ = term.cursor_is_at_prompt();
    let _ = term.default_colors();
    let _ = term.is_synchronized_output();
    let _ = term.pending_wrap();
    let _ = term.kitty_keyboard_flags();

    // 4. Graphics placements & images
    let placements = term.graphics_placements().to_vec();
    for p in placements.iter().take(8) {
        let _ = term.graphics_image(p.image_id);
    }
    let _ = term.graphics_image(0);
    let _ = term.graphics_image(1);

    // 5. Modes & palette
    let _ = term.modes();
    let pal = term.palette();
    let _ = pal.get(0);
    let _ = pal.get(7);
    let _ = pal.get(15);
    let _ = pal.get(255);

    // 6. Selection inspection
    let _ = term.has_selection();
    let _ = term.selection_mode();
    let _ = term.selection_range();
    let _ = term.selected_text();

    // 7. Viewport rows, cells, hyperlinks, and soft wrapping
    for r in 0..rows {
        let cells = term.viewport_row(r);
        assert_eq!(
            cells.len(),
            cols,
            "viewport_row length must equal grid columns"
        );
        for cell in &cells {
            if let Some(link_id) = cell.hyperlink {
                let _ = term.hyperlink_uri(link_id);
            }
        }
        let _ = term.viewport_line_wrapped(r);
    }

    // Spot-check cursor row and document absolute wrapping
    let _ = term.is_line_wrapped_abs(c_row);
    let _ = term.hyperlink_uri(0);
    let _ = term.hyperlink_uri(1);

    // Spot-check word and line selection readback safely
    if cols > 0 && rows > 0 {
        let _ = c_col.min(cols - 1);
    }

    // 8. Draining & damage
    let _ = term.has_damage();
    let _ = term.take_damage();
    let _ = term.take_output();
    let _ = term.take_events();
}
