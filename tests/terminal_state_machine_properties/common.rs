/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

pub use tako_core::terminal::{SelectionMode, Terminal};

// ── Deterministic PRNG ──────────────────────────────────────────────────────

#[derive(Clone, Debug)]
pub struct SimpleRng {
    state: u64,
}

impl SimpleRng {
    pub fn new(seed: u64) -> Self {
        let mut rng = Self {
            state: if seed == 0 { 0xdeadbeef_cafebabe } else { seed },
        };
        for _ in 0..4 {
            rng.next_u64();
        }
        rng
    }

    pub fn next_u64(&mut self) -> u64 {
        // SplitMix64
        self.state = self.state.wrapping_add(0x9e3779b97f4a7c15);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58476d1ce4e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d049bb133111eb);
        z ^ (z >> 31)
    }

    pub fn next_u32(&mut self) -> u32 {
        (self.next_u64() >> 32) as u32
    }

    pub fn next_usize(&mut self) -> usize {
        self.next_u64() as usize
    }

    pub fn gen_range(&mut self, min: usize, max: usize) -> usize {
        if min >= max {
            return min;
        }
        let span = max - min + 1;
        min + (self.next_usize() % span)
    }

    pub fn gen_f64(&mut self) -> f64 {
        (self.next_u32() as f64) / ((u32::MAX as f64) + 1.0)
    }

    pub fn gen_bool(&mut self) -> bool {
        (self.next_u64() & 1) == 1
    }

    pub fn choose<'a, T>(&mut self, slice: &'a [T]) -> &'a T {
        &slice[self.next_usize() % slice.len()]
    }

    pub fn gen_bytes(&mut self, len: usize) -> Vec<u8> {
        (0..len).map(|_| self.next_u64() as u8).collect()
    }
}

// ── Curated Sequence Bank ───────────────────────────────────────────────────

pub const CURATED_VT_SNIPPETS: &[&[u8]] = &[
    // Cursor movements
    b"\x1b[A",
    b"\x1b[3B",
    b"\x1b[5C",
    b"\x1b[2D",
    b"\x1b[1;1H",
    b"\x1b[10;20H",
    b"\x1b[5;5f",
    b"\x1b[H",
    b"\x1b[s",
    b"\x1b[u",
    b"\x1b7",
    b"\x1b8",
    // Erases & Clears
    b"\x1b[J",
    b"\x1b[0J",
    b"\x1b[1J",
    b"\x1b[2J",
    b"\x1b[3J",
    b"\x1b[K",
    b"\x1b[0K",
    b"\x1b[1K",
    b"\x1b[2K",
    b"\x1b[X",
    b"\x1b[5X",
    // Insert & Delete
    b"\x1b[@",
    b"\x1b[4@",
    b"\x1b[P",
    b"\x1b[3P",
    b"\x1b[L",
    b"\x1b[2L",
    b"\x1b[M",
    b"\x1b[2M",
    // Margins & Scrolling regions
    b"\x1b[1;10r",
    b"\x1b[2;5r",
    b"\x1b[r",
    b"\x1b[?69h",
    b"\x1b[?69l",
    b"\x1b[2;15s",
    // SGR Styling
    b"\x1b[0m",
    b"\x1b[1m",
    b"\x1b[2m",
    b"\x1b[3m",
    b"\x1b[4m",
    b"\x1b[4:1m",
    b"\x1b[4:2m",
    b"\x1b[4:3m",
    b"\x1b[4:4m",
    b"\x1b[4:5m",
    b"\x1b[5m",
    b"\x1b[7m",
    b"\x1b[8m",
    b"\x1b[9m",
    b"\x1b[53m",
    b"\x1b[31m",
    b"\x1b[32;44m",
    b"\x1b[91;103m",
    b"\x1b[38;5;123m",
    b"\x1b[48;5;200m",
    b"\x1b[38;2;100;150;200m",
    b"\x1b[48;2;10;20;30m",
    b"\x1b[58;2;255;0;128m",
    b"\x1b[59m",
    b"\x1b[39;49m",
    // Modes
    b"\x1b[?1049h",
    b"\x1b[?1049l",
    b"\x1b[?47h",
    b"\x1b[?47l",
    b"\x1b[?25h",
    b"\x1b[?25l",
    b"\x1b[?7h",
    b"\x1b[?7l",
    b"\x1b[?6h",
    b"\x1b[?6l",
    b"\x1b[4h",
    b"\x1b[4l",
    b"\x1b[?2004h",
    b"\x1b[?2004l",
    b"\x1b[?2026h",
    b"\x1b[?2026l",
    // Charsets & shifts
    b"\x0f",
    b"\x0e",
    b"\x1b(0",
    b"\x1b(B",
    b"\x1b)0",
    b"\x1b)B",
    b"\x1b*0",
    b"\x1b+0",
    b"\x1bN",
    b"\x1bO",
    // Repetition
    b"\x1b[3b",
    b"\x1b[10b",
    // Character protection
    b"\x1b[0\"q",
    b"\x1b[1\"q",
    b"\x1b[2\"q",
    b"\x1b[?0K",
    b"\x1b[?1K",
    b"\x1b[?2K",
    b"\x1b[?0J",
    b"\x1b[?1J",
    b"\x1b[?2J",
    // Tab stops
    b"\x1bH",
    b"\x1b[g",
    b"\x1b[3g",
    b"\t",
    b"\x1b[Z",
    // Queries
    b"\x1b[c",
    b"\x1b[>c",
    b"\x1b[5n",
    b"\x1b[6n",
    b"\x1b[?6n",
    b"\x1b[?996n",
    b"\x1b[>q",
    b"\x05",
    // OSC Sequences
    b"\x1b]0;upstream Terminal Title\x07",
    b"\x1b]2;Tako Core Window\x1b\\",
    b"\x1b]7;file:///home/user/workspace/tako\x07",
    b"\x1b]8;id=link1;https://example.com/test\x07hyperlink text\x1b]8;;\x07",
    b"\x1b]52;c;aGVsbG8gd29ybGQ=\x07",
    b"\x1b]52;c;?\x07",
    b"\x1b]9;Notification popup\x07",
    b"\x1b]777;notify;Header;Body content\x07",
    b"\x1b]9;4;1;75\x07",
    b"\x1b]9;4;0\x07",
    b"\x1b]10;rgb:ff/00/aa\x07",
    b"\x1b]11;#123456\x07",
    b"\x1b]12;rgb:00/ff/00\x07",
    b"\x1b]133;A\x07",
    b"\x1b]133;B\x07",
    b"\x1b]133;C\x07",
    b"\x1b]133;D;0\x07",
    // DCS Sequences
    b"\x1bP$q\"q\x1b\\",
    b"\x1bP$qm\x1b\\",
    b"\x1bP$qr\x1b\\",
    b"\x1bP$qs\x1b\\",
    b"\x1bP+q544e\x1b\\",
    // Kitty Keyboard & Graphics
    b"\x1b[?u",
    b"\x1b[>1u",
    b"\x1b[<u",
    b"\x1b[=2;1u",
    b"\x1b_Ga=d,d=A\x1b\\",
];

pub const CURATED_UTF8_TEXT: &[&str] = &[
    "hello world\r\n",
    "quick brown fox jumps over the lazy dog\r\n",
    "https://example.com/tako/issues/123\r\n",
    "/usr/local/bin/tako-terminal:42:15\r\n",
    "version@1.2.3-beta.4+build.2026\r\n",
    "Привет, мир! Тестирование терминала UTF-8.\r\n",
    "世界你好，这是一个宽字符测试。\r\n",
    "こんにちは世界！\r\n",
    "🚀 🦀 ✨ 💻 📦 🔍 🧪\r\n",
    "e\u{0301} a\u{0300} o\u{0302} u\u{0308} c\u{0327}\r\n",
    "zero\u{200b}width\u{200c}space\u{200d}test\r\n",
    "line with trailing spaces     \r\n",
    "wrapped_line_without_any_whitespace_exceeding_screen_width_regularly_and_consistently\r\n",
    "a\tb\tc\td\te\r\n",
    "\r\n\r\n\r\n",
    "\x08\x08\x08backspaces\r\n",
];

// ── Invariant Assertions ────────────────────────────────────────────────────

pub fn assert_durable_invariants(t: &Terminal) {
    let grid = t.active_grid();
    let cols = grid.cols();
    let rows = grid.rows();

    // Invariant 1: Positive grid dimensions
    assert!(cols > 0, "cols must be positive, got {cols}");
    assert!(rows > 0, "rows must be positive, got {rows}");

    // Invariant 2: Cursor bounds stay within current positive grid dimensions
    let (cursor_row, cursor_col) = t.cursor();
    assert!(
        cursor_row < rows,
        "cursor row {cursor_row} out of bounds (rows = {rows})"
    );
    assert!(
        cursor_col < cols,
        "cursor col {cursor_col} out of bounds (cols = {cols})"
    );

    // Invariant 3: Viewport row widths equal cols for all rows in viewport
    for r in 0..rows {
        let v_row = t.viewport_row(r);
        assert_eq!(
            v_row.len(),
            cols,
            "viewport_row({r}) length {} != cols {cols}",
            v_row.len()
        );
        let _ = t.viewport_line_wrapped(r);
    }

    // Invariant 4: Scroll position stays finite and normalized [0.0, 1.0]
    let pos = t.scroll_position();
    assert!(pos.is_finite(), "scroll_position {pos} is not finite");
    assert!(
        (0.0..=1.0).contains(&pos),
        "scroll_position {pos} outside [0.0, 1.0]"
    );

    let offset = t.viewport_offset();
    let scrollback_len = grid.scrollback_len();
    assert!(
        offset <= scrollback_len,
        "viewport_offset {offset} exceeds scrollback_len {scrollback_len}"
    );

    // Invariant 5: Selection bounds stay within current positive grid dimensions
    if let Some(((start_row, start_col), (end_row, end_col))) = t.selection_range() {
        assert!(
            start_row < rows,
            "selection start_row {start_row} >= rows {rows}"
        );
        assert!(end_row < rows, "selection end_row {end_row} >= rows {rows}");
        assert!(
            start_col < cols,
            "selection start_col {start_col} >= cols {cols}"
        );
        assert!(end_col < cols, "selection end_col {end_col} >= cols {cols}");
    }

    // Invariant 6: Repeated reads and query methods do not panic
    let _ = t.has_selection();
    let _ = t.selection_mode();
    let _ = t.selected_text();
    let _ = t.plain_string();
    let _ = t.plain_string_unwrapped();
    let _ = t.buffer_text();
    let _ = t.dump();
    let _ = t.title();
    let _ = t.cursor_visible();
    let _ = t.active_screen();
    let _ = t.cursor_style();
    let _ = t.pixel_size();
    let _ = t.gr_slot();
    let _ = t.has_damage();
    let _ = t.semantic_content();
    let _ = t.cursor_is_at_prompt();
    let _ = t.default_colors();
    let _ = t.graphics_placements();
    let _ = t.modes();
    let _ = t.is_synchronized_output();
    let _ = t.pending_wrap();
    let _ = t.kitty_keyboard_flags();
    let _ = t.palette();
}
