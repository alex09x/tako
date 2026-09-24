//! Throughput benchmarks for the terminal engine: how fast `feed` chews
//! through the byte patterns real programs emit.

use criterion::{criterion_group, criterion_main, BenchmarkId, Criterion, Throughput};
use tako_core::grid::{Cell, Grid, DEFAULT_SCROLLBACK_CAPACITY};
use tako_core::parser::{Parser, Perform};
use tako_core::terminal::Terminal;

#[derive(Default)]
struct NoopPerformer;

impl Perform for NoopPerformer {
    fn print(&mut self, _c: char) {}
    fn print_slice(&mut self, _bytes: &[u8]) {}
    fn execute(&mut self, _byte: u8) {}
    fn hook(
        &mut self,
        _params: &[u16],
        _params_sep: u32,
        _intermediates: &[u8],
        _ignore: bool,
        _action: char,
    ) {
    }
    fn put(&mut self, _byte: u8) {}
    fn unhook(&mut self) {}
    fn osc_dispatch(&mut self, _params: &[&[u8]], _bell_terminated: bool) {}
    fn csi_dispatch(
        &mut self,
        _params: &[u16],
        _params_sep: u32,
        _intermediates: &[u8],
        _ignore: bool,
        _action: char,
    ) {
    }
    fn esc_dispatch(&mut self, _intermediates: &[u8], _ignore: bool, _byte: u8) {}
}

/// Plain ASCII text, the most common case by volume (cat of a big file).
fn plain_text(bytes: usize) -> Vec<u8> {
    let line = b"the quick brown fox jumps over the lazy dog 0123456789\r\n";
    line.iter().copied().cycle().take(bytes).collect()
}

/// The exact shape of vtebench's scrolling workload: one glyph and LF.
fn short_lines(bytes: usize) -> Vec<u8> {
    b"y\n".iter().copied().cycle().take(bytes).collect()
}

/// Heavily colored output, e.g. `ls --color` or a build log.
fn sgr_heavy(bytes: usize) -> Vec<u8> {
    let chunk = b"\x1b[1;38;2;255;128;0mword\x1b[0m \x1b[42;30mmore\x1b[0m ";
    chunk.iter().copied().cycle().take(bytes).collect()
}

/// Cursor-motion heavy output, e.g. a full-screen TUI repainting.
fn cursor_heavy(bytes: usize) -> Vec<u8> {
    let chunk = b"\x1b[10;20HX\x1b[K\x1b[2;3r\x1b[H\x1b[J";
    chunk.iter().copied().cycle().take(bytes).collect()
}

/// Wide characters and emoji, which exercise the pair bookkeeping.
fn wide_chars(bytes: usize) -> Vec<u8> {
    let chunk = "中文字符 emoji \u{1F600}\u{1F680} ".as_bytes();
    chunk.iter().copied().cycle().take(bytes).collect()
}

fn bench_feed(c: &mut Criterion) {
    const SIZE: usize = 256 * 1024;
    let mut group = c.benchmark_group("feed");
    group.throughput(Throughput::Bytes(SIZE as u64));
    for (name, data) in [
        ("plain_text", plain_text(SIZE)),
        ("sgr_heavy", sgr_heavy(SIZE)),
        ("cursor_heavy", cursor_heavy(SIZE)),
        ("wide_chars", wide_chars(SIZE)),
    ] {
        group.bench_with_input(BenchmarkId::from_parameter(name), &data, |b, data| {
            b.iter(|| {
                let mut term = Terminal::new(80, 24);
                term.feed(data);
                std::hint::black_box(term.cursor());
            });
        });
    }
    group.finish();
}

fn parser_scan_input(bytes: usize, pattern: &[u8], seed: u8) -> Vec<u8> {
    let mut out = Vec::with_capacity(bytes);
    for i in 0..bytes {
        out.push(pattern[(i + seed as usize) % pattern.len()]);
    }
    out
}

fn bench_parser_scan(c: &mut Criterion) {
    const SIZE: usize = 256 * 1024;
    let mut group = c.benchmark_group("parser_scan");
    group.throughput(Throughput::Bytes(SIZE as u64));

    let ascii = b"the quick brown fox jumps over the lazy dog 0123456789\r\n".to_vec();
    let controls = b"\x1b[31mbold\x1B[0m ".to_vec();
    let utf8 = "🙂 emoji 🌟 ".as_bytes().to_vec();

    for (name, data) in [
        ("ascii", parser_scan_input(SIZE, &ascii, 0)),
        ("controls", parser_scan_input(SIZE, &controls, 7)),
        ("utf8", parser_scan_input(SIZE, &utf8, 13)),
    ] {
        group.bench_with_input(BenchmarkId::from_parameter(name), &data, |b, data| {
            b.iter_batched(
                Parser::new,
                |mut parser| {
                    let mut performer = NoopPerformer;
                    parser.advance_bytes(&mut performer, data);
                    std::hint::black_box(parser.state);
                },
                criterion::BatchSize::SmallInput,
            );
        });
    }

    group.finish();
}

/// Scrollback pressure: a long stream through a small screen.
fn bench_scrollback(c: &mut Criterion) {
    let data = plain_text(512 * 1024);
    c.bench_function("feed/scrollback_10k_lines", |b| {
        b.iter(|| {
            let mut term = Terminal::new(80, 24);
            term.feed(&data);
            std::hint::black_box(term.active_grid().scrollback_len());
        });
    });

    let data = short_lines(512 * 1024);
    c.bench_function("feed/scrollback_short_lines", |b| {
        b.iter(|| {
            let mut term = Terminal::new(80, 24);
            term.feed(&data);
            std::hint::black_box(term.active_grid().scrollback_len());
        });
    });
}

/// Reflow cost: resizing a screen full of soft-wrapped content.
fn bench_resize_reflow(c: &mut Criterion) {
    c.bench_function("resize/reflow_80_to_40", |b| {
        b.iter_batched(
            || {
                let mut term = Terminal::new(80, 24);
                term.feed(&plain_text(64 * 1024));
                term
            },
            |mut term| {
                term.resize(40, 24);
                std::hint::black_box(term.cursor());
            },
            criterion::BatchSize::SmallInput,
        );
    });
}

/// Full-screen line scrolling: what a 97x30 screen does on every newline
/// once the cursor has reached the bottom row. This is the hot path the
/// row-circular grid exists for -- the cost should track the number of
/// *scrolled* lines, not `rows * cols`.
fn bench_grid_scroll(c: &mut Criterion) {
    const COLS: usize = 97;
    const ROWS: usize = 30;
    const SCROLLS: u64 = 1_000;

    let full_grid = |capacity: usize| {
        let mut grid = Grid::with_scrollback_capacity(COLS, ROWS, capacity);
        for row in 0..ROWS {
            for col in 0..COLS {
                grid.set(row, col, Cell { char: 'x', ..Cell::default() });
            }
        }
        grid
    };

    let mut group = c.benchmark_group("grid/scroll_up_1_line_97x30");
    group.throughput(Throughput::Elements(SCROLLS));
    for (name, capacity) in [
        ("with_scrollback", DEFAULT_SCROLLBACK_CAPACITY),
        // capacity 0 skips the per-line scrollback allocation, isolating
        // the cost of moving/blanking rows.
        ("no_scrollback", 0),
    ] {
        group.bench_with_input(
            BenchmarkId::from_parameter(name),
            &capacity,
            |b, &capacity| {
                b.iter_batched(
                    || full_grid(capacity),
                    |mut grid| {
                        for _ in 0..SCROLLS {
                            grid.scroll_up(1);
                        }
                        std::hint::black_box(grid.scrollback_len());
                    },
                    criterion::BatchSize::SmallInput,
                );
            },
        );
    }
    group.finish();
}

criterion_group!(
    benches,
    bench_feed,
    bench_scrollback,
    bench_resize_reflow,
    bench_grid_scroll,
    bench_parser_scan
);
criterion_main!(benches);
