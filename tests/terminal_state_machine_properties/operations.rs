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

// ── State Machine Operation Generator ───────────────────────────────────────

#[derive(Debug)]
pub enum Op {
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

pub fn generate_random_op(rng: &mut SimpleRng) -> Op {
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

pub fn apply_op(t: &mut Terminal, op: &Op, rng: &mut SimpleRng) {
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

pub const FIXED_SEEDS: &[u64] = &[
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
