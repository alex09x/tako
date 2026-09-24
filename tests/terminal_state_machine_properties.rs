//! Deterministic property and state machine tests for `Terminal`.
//!
//! Explores seeded operation sequences (arbitrary byte chunks, curated VT and
//! UTF-8 sequences, positive resizes, viewport scrolling and scroll position
//! changes, text selection, string extractions, damage/output/event draining)
//! and asserts public durable invariants.
//!
//! Uses a self-contained deterministic PRNG with no external dependencies.

use tako_core::terminal::{SelectionMode, Terminal};

// ── Deterministic PRNG ──────────────────────────────────────────────────────

#[derive(Clone, Debug)]
struct SimpleRng {
    state: u64,
}

impl SimpleRng {
    fn new(seed: u64) -> Self {
        let mut rng = Self {
            state: if seed == 0 { 0xdeadbeef_cafebabe } else { seed },
        };
        for _ in 0..4 {
            rng.next_u64();
        }
        rng
    }

    fn next_u64(&mut self) -> u64 {
        // SplitMix64
        self.state = self.state.wrapping_add(0x9e3779b97f4a7c15);
        let mut z = self.state;
        z = (z ^ (z >> 30)).wrapping_mul(0xbf58476d1ce4e5b9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94d049bb133111eb);
        z ^ (z >> 31)
    }

    fn next_u32(&mut self) -> u32 {
        (self.next_u64() >> 32) as u32
    }

    fn next_usize(&mut self) -> usize {
        self.next_u64() as usize
    }

    fn gen_range(&mut self, min: usize, max: usize) -> usize {
        if min >= max {
            return min;
        }
        let span = max - min + 1;
        min + (self.next_usize() % span)
    }

    fn gen_f64(&mut self) -> f64 {
        (self.next_u32() as f64) / ((u32::MAX as f64) + 1.0)
    }

    fn gen_bool(&mut self) -> bool {
        (self.next_u64() & 1) == 1
    }

    fn choose<'a, T>(&mut self, slice: &'a [T]) -> &'a T {
        &slice[self.next_usize() % slice.len()]
    }

    fn gen_bytes(&mut self, len: usize) -> Vec<u8> {
        (0..len).map(|_| self.next_u64() as u8).collect()
    }
}

// ── Curated Sequence Bank ───────────────────────────────────────────────────

const CURATED_VT_SNIPPETS: &[&[u8]] = &[
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

const CURATED_UTF8_TEXT: &[&str] = &[
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

fn assert_durable_invariants(t: &Terminal) {
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

// ── State Machine Operation Generator ───────────────────────────────────────

#[derive(Debug)]
enum Op {
    FeedCuratedVt(usize),
    FeedCuratedUtf8(usize),
    FeedRandomAscii(usize),
    FeedRandomUtf8(usize),
    FeedArbitraryBytes(usize),
    Resize(usize, usize),
    ResizePixels(usize, usize, u32, u32),
    ResizeCellSize(usize, usize, u32, u32),
    ScrollViewportUp(usize),
    ScrollViewportDown(usize),
    ScrollViewportBottom,
    SetScrollPosition(f64),
    StartSelection(usize, usize, SelectionMode),
    ExtendSelection(usize, usize),
    ClearSelection,
    SelectWord(usize, usize),
    SelectLine(usize, usize),
    DrainOutput,
    DrainDamage,
    DrainEvents,
    MarkAllDamaged,
    Inspect,
}

fn generate_random_op(rng: &mut SimpleRng) -> Op {
    match rng.gen_range(0, 21) {
        0 => Op::FeedCuratedVt(rng.next_usize() % CURATED_VT_SNIPPETS.len()),
        1 => Op::FeedCuratedUtf8(rng.next_usize() % CURATED_UTF8_TEXT.len()),
        2 => Op::FeedRandomAscii(rng.gen_range(1, 128)),
        3 => Op::FeedRandomUtf8(rng.gen_range(1, 64)),
        4 => Op::FeedArbitraryBytes(rng.gen_range(1, 64)),
        5 => Op::Resize(rng.gen_range(1, 160), rng.gen_range(1, 80)),
        6 => Op::ResizePixels(
            rng.gen_range(1, 120),
            rng.gen_range(1, 60),
            rng.gen_range(100, 2000) as u32,
            rng.gen_range(100, 2000) as u32,
        ),
        7 => Op::ResizeCellSize(
            rng.gen_range(1, 120),
            rng.gen_range(1, 60),
            rng.gen_range(6, 32) as u32,
            rng.gen_range(10, 48) as u32,
        ),
        8 => Op::ScrollViewportUp(rng.gen_range(0, 200)),
        9 => Op::ScrollViewportDown(rng.gen_range(0, 200)),
        10 => Op::ScrollViewportBottom,
        11 => {
            let positions = [-10.0, -1.0, 0.0, 0.25, 0.5, 0.75, 1.0, 2.0, 100.0];
            let pos = if rng.gen_bool() {
                *rng.choose(&positions)
            } else {
                rng.gen_f64()
            };
            Op::SetScrollPosition(pos)
        }
        12 => {
            let mode = if rng.gen_bool() {
                SelectionMode::Linear
            } else {
                SelectionMode::Rectangular
            };
            Op::StartSelection(rng.gen_range(0, 100), rng.gen_range(0, 200), mode)
        }
        13 => Op::ExtendSelection(rng.gen_range(0, 100), rng.gen_range(0, 200)),
        14 => Op::ClearSelection,
        15 => Op::SelectWord(rng.gen_range(0, 100), rng.gen_range(0, 200)),
        16 => Op::SelectLine(rng.gen_range(0, 100), rng.gen_range(0, 200)),
        17 => Op::DrainOutput,
        18 => Op::DrainDamage,
        19 => Op::DrainEvents,
        20 => Op::MarkAllDamaged,
        _ => Op::Inspect,
    }
}

fn apply_op(t: &mut Terminal, op: &Op, rng: &mut SimpleRng) {
    match op {
        Op::FeedCuratedVt(index) => {
            t.feed(CURATED_VT_SNIPPETS[*index]);
        }
        Op::FeedCuratedUtf8(index) => {
            t.feed(CURATED_UTF8_TEXT[*index].as_bytes());
        }
        Op::FeedRandomAscii(len) => {
            let mut bytes = Vec::with_capacity(*len);
            for _ in 0..*len {
                let b = match rng.gen_range(0, 5) {
                    0 => rng.gen_range(b'a' as usize, b'z' as usize) as u8,
                    1 => rng.gen_range(b'A' as usize, b'Z' as usize) as u8,
                    2 => rng.gen_range(b'0' as usize, b'9' as usize) as u8,
                    3 => *rng.choose(b" \t\r\n-_./:=?&#+"),
                    _ => rng.gen_range(0x20, 0x7e) as u8,
                };
                bytes.push(b);
            }
            t.feed(&bytes);
        }
        Op::FeedRandomUtf8(count) => {
            let mut s = String::new();
            for _ in 0..*count {
                match rng.gen_range(0, 4) {
                    0 => s.push_str(rng.choose(&["α", "β", "γ", "δ", "ε", "θ", "λ", "π"])),
                    1 => s.push_str(rng.choose(&["Привет", "мир", "строка", "терминал", "тест"])),
                    2 => s.push_str(rng.choose(&["世界", "你好", "日本語", "한국어", "漢字"])),
                    _ => s.push_str(rng.choose(&["😀", "🚀", "🦀", "✨", "🔥", "🎉"])),
                }
            }
            t.feed(s.as_bytes());
        }
        Op::FeedArbitraryBytes(len) => {
            let bytes = rng.gen_bytes(*len);
            t.feed(&bytes);
        }
        Op::Resize(cols, rows) => {
            t.resize(*cols, *rows);
        }
        Op::ResizePixels(cols, rows, w_px, h_px) => {
            t.resize_with_pixels(*cols, *rows, *w_px, *h_px);
        }
        Op::ResizeCellSize(cols, rows, cw, ch) => {
            t.resize_with_cell_size(*cols, *rows, *cw, *ch);
        }
        Op::ScrollViewportUp(n) => {
            t.scroll_viewport_up(*n);
        }
        Op::ScrollViewportDown(n) => {
            t.scroll_viewport_down(*n);
        }
        Op::ScrollViewportBottom => {
            t.scroll_viewport_bottom();
        }
        Op::SetScrollPosition(pos) => {
            t.set_scroll_position(*pos);
        }
        Op::StartSelection(row, col, mode) => {
            t.start_selection(*row, *col, *mode);
        }
        Op::ExtendSelection(row, col) => {
            t.extend_selection(*row, *col);
        }
        Op::ClearSelection => {
            t.clear_selection();
        }
        Op::SelectWord(row, col) => {
            t.select_word(*row, *col);
        }
        Op::SelectLine(row, col) => {
            t.select_line(*row, *col);
        }
        Op::DrainOutput => {
            let _ = t.take_output();
        }
        Op::DrainDamage => {
            let _ = t.take_damage();
        }
        Op::DrainEvents => {
            let _ = t.take_events();
        }
        Op::MarkAllDamaged => {
            t.mark_all_damaged();
        }
        Op::Inspect => {
            assert_durable_invariants(t);
        }
    }
}

// ── Property Tests ──────────────────────────────────────────────────────────

const FIXED_SEEDS: &[u64] = &[
    1,
    42,
    1337,
    0x12345678,
    0xcafe_d00d,
    0xdead_beef,
    99999,
    314159,
    271828,
    1000000007,
    0xfeed_face,
    0x01234567_89abcdef,
    7777777,
    8888888,
    55555,
    12345,
    67890,
    987654,
    43210,
    11223344,
];

#[test]
fn test_fuzz_state_machine_sequences_across_seeds() {
    for &seed in FIXED_SEEDS {
        let mut rng = SimpleRng::new(seed);
        let init_cols = rng.gen_range(1, 100);
        let init_rows = rng.gen_range(1, 50);
        let mut term = Terminal::new(init_cols, init_rows);

        assert_durable_invariants(&term);

        let op_count = rng.gen_range(200, 350);
        for step in 0..op_count {
            let op = generate_random_op(&mut rng);
            apply_op(&mut term, &op, &mut rng);

            // Periodically or after every step verify invariants
            if (step % 5 == 0 || step == op_count - 1)
                && std::panic::catch_unwind(|| assert_durable_invariants(&term)).is_err() {
                    panic!("seed {seed}, step {step}, after {op:?}");
                }
        }
    }
}

#[test]
fn test_property_chunking_independence() {
    for &seed in FIXED_SEEDS {
        let mut rng = SimpleRng::new(seed);
        let cols = rng.gen_range(10, 80);
        let rows = rng.gen_range(4, 30);

        // Build a deterministic byte stream
        let mut stream = Vec::new();
        let snippet_count = rng.gen_range(30, 80);
        for _ in 0..snippet_count {
            match rng.gen_range(0, 4) {
                0 => stream.extend_from_slice(rng.choose(CURATED_VT_SNIPPETS)),
                1 => stream.extend_from_slice(rng.choose(CURATED_UTF8_TEXT).as_bytes()),
                2 => {
                    let len = rng.gen_range(1, 32);
                    let ascii = (0..len)
                        .map(|_| rng.gen_range(0x20, 0x7e) as u8)
                        .collect::<Vec<_>>();
                    stream.extend_from_slice(&ascii);
                }
                _ => {
                    let len = rng.gen_range(1, 16);
                    let raw = rng.gen_bytes(len);
                    stream.extend_from_slice(&raw);
                }
            }
        }

        // Terminal A: single chunk feed
        let mut term_single = Terminal::new(cols, rows);
        term_single.feed(&stream);
        let single_output = term_single.take_output();
        let single_events = term_single.take_events();
        let single_dump = term_single.dump();
        let single_cursor = term_single.cursor();
        let single_screen = term_single.active_screen();
        let single_visible = term_single.cursor_visible();
        let single_title = term_single.title().to_string();
        let single_plain = term_single.plain_string();
        let single_unwrapped = term_single.plain_string_unwrapped();
        let single_buffer = term_single.buffer_text();

        // Terminal B: byte-by-byte feed
        let mut term_bytes = Terminal::new(cols, rows);
        for &b in &stream {
            term_bytes.feed(&[b]);
        }
        let bytes_output = term_bytes.take_output();
        let bytes_events = term_bytes.take_events();
        let bytes_dump = term_bytes.dump();
        let bytes_cursor = term_bytes.cursor();
        let bytes_screen = term_bytes.active_screen();
        let bytes_visible = term_bytes.cursor_visible();
        let bytes_title = term_bytes.title().to_string();
        let bytes_plain = term_bytes.plain_string();
        let bytes_unwrapped = term_bytes.plain_string_unwrapped();
        let bytes_buffer = term_bytes.buffer_text();

        assert_eq!(
            single_cursor, bytes_cursor,
            "seed {seed}: cursor mismatch between single-feed and byte-by-byte feed"
        );
        assert_eq!(
            single_screen, bytes_screen,
            "seed {seed}: screen buffer mismatch"
        );
        assert_eq!(
            single_visible, bytes_visible,
            "seed {seed}: cursor visibility mismatch"
        );
        assert_eq!(single_title, bytes_title, "seed {seed}: title mismatch");
        assert_eq!(
            single_dump, bytes_dump,
            "seed {seed}: dump mismatch between single-feed and byte-by-byte feed"
        );
        assert_eq!(
            single_plain, bytes_plain,
            "seed {seed}: plain_string mismatch"
        );
        assert_eq!(
            single_unwrapped, bytes_unwrapped,
            "seed {seed}: plain_string_unwrapped mismatch"
        );
        assert_eq!(
            single_buffer, bytes_buffer,
            "seed {seed}: buffer_text mismatch"
        );
        assert_eq!(
            single_output, bytes_output,
            "seed {seed}: response output mismatch"
        );
        assert_eq!(
            single_events, bytes_events,
            "seed {seed}: terminal events mismatch"
        );

        // Terminal C: randomized chunk partitions
        let mut term_random_chunks = Terminal::new(cols, rows);
        let mut offset = 0;
        while offset < stream.len() {
            let chunk_len = rng.gen_range(1, 15).min(stream.len() - offset);
            term_random_chunks.feed(&stream[offset..offset + chunk_len]);
            offset += chunk_len;
        }

        assert_eq!(
            single_dump,
            term_random_chunks.dump(),
            "seed {seed}: dump mismatch with randomized chunking"
        );
        assert_eq!(
            single_output,
            term_random_chunks.take_output(),
            "seed {seed}: output mismatch with randomized chunking"
        );
        assert_eq!(
            single_events,
            term_random_chunks.take_events(),
            "seed {seed}: events mismatch with randomized chunking"
        );

        assert_durable_invariants(&term_single);
        assert_durable_invariants(&term_bytes);
        assert_durable_invariants(&term_random_chunks);
    }
}

#[test]
fn test_property_resizing_invariants() {
    for &seed in FIXED_SEEDS {
        let mut rng = SimpleRng::new(seed);
        let mut term = Terminal::new(80, 24);

        // Feed some initial content with wrapping, styles and UTF-8
        for _ in 0..20 {
            term.feed(rng.choose(CURATED_VT_SNIPPETS));
            term.feed(rng.choose(CURATED_UTF8_TEXT).as_bytes());
        }

        for _ in 0..50 {
            let new_cols = match rng.gen_range(0, 4) {
                0 => 1,
                1 => rng.gen_range(2, 20),
                2 => rng.gen_range(21, 100),
                _ => rng.gen_range(101, 250),
            };
            let new_rows = match rng.gen_range(0, 4) {
                0 => 1,
                1 => rng.gen_range(2, 10),
                2 => rng.gen_range(11, 50),
                _ => rng.gen_range(51, 120),
            };

            term.resize(new_cols, new_rows);
            assert_durable_invariants(&term);

            // Interleaved feeds and scrolls
            if rng.gen_bool() {
                term.feed(rng.choose(CURATED_UTF8_TEXT).as_bytes());
            }
            if rng.gen_bool() {
                term.scroll_viewport_up(rng.gen_range(0, 10));
            }
            assert_durable_invariants(&term);
        }
    }
}

#[test]
fn test_property_selection_invariants() {
    for &seed in FIXED_SEEDS {
        let mut rng = SimpleRng::new(seed);
        let cols = rng.gen_range(10, 60);
        let rows = rng.gen_range(4, 20);
        let mut term = Terminal::new(cols, rows);

        // Populate with text
        for _ in 0..15 {
            term.feed(rng.choose(CURATED_UTF8_TEXT).as_bytes());
        }

        for _ in 0..40 {
            let row1 = rng.gen_range(0, rows + 50);
            let col1 = rng.gen_range(0, cols + 50);
            let row2 = rng.gen_range(0, rows + 50);
            let col2 = rng.gen_range(0, cols + 50);

            let mode = if rng.gen_bool() {
                SelectionMode::Linear
            } else {
                SelectionMode::Rectangular
            };

            // Test normal start + extend
            term.start_selection(row1, col1, mode);
            assert_durable_invariants(&term);

            term.extend_selection(row2, col2);
            assert_durable_invariants(&term);

            // Test word selection
            term.select_word(row1, col1);
            assert_durable_invariants(&term);

            // Test line selection
            term.select_line(row2, col2);
            assert_durable_invariants(&term);

            // Test clearing
            term.clear_selection();
            assert!(!term.has_selection());
            assert_eq!(term.selection_range(), None);
            assert_durable_invariants(&term);
        }
    }
}

#[test]
fn test_property_scrollback_and_viewport_invariants() {
    for &seed in FIXED_SEEDS {
        let mut rng = SimpleRng::new(seed);
        let cols = rng.gen_range(20, 80);
        let rows = rng.gen_range(4, 20);
        let mut term = Terminal::with_scrollback(cols, rows, 100);

        // Feed many lines to exceed scrollback capacity and trigger eviction
        for i in 0..300 {
            term.feed(format!("line {i} - {}\r\n", rng.choose(CURATED_UTF8_TEXT)).as_bytes());
        }
        let _ = term.take_output();

        assert_eq!(term.active_grid().scrollback_len(), 100);
        assert_durable_invariants(&term);

        // Test viewport movements
        for _ in 0..30 {
            let scroll_up = rng.gen_range(0, 150);
            term.scroll_viewport_up(scroll_up);
            assert_durable_invariants(&term);

            let scroll_down = rng.gen_range(0, 150);
            term.scroll_viewport_down(scroll_down);
            assert_durable_invariants(&term);

            let pos = match rng.gen_range(0, 5) {
                0 => -5.0,
                1 => 0.0,
                2 => rng.gen_f64(),
                3 => 1.0,
                _ => 10.0,
            };
            term.set_scroll_position(pos);
            assert_durable_invariants(&term);

            term.scroll_viewport_bottom();
            assert_eq!(term.viewport_offset(), 0);
            assert_eq!(term.scroll_position(), 1.0);
            assert_durable_invariants(&term);
        }
    }
}
