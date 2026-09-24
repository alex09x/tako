// Crash-regression and program-emulation tests.
//
// Each test feeds the byte stream a real console program would produce and
// asserts the terminal handles it without panicking or producing corrupt
// state. No program binaries are needed — the sequences are captured once
// and embedded here as byte literals.
//
// Programs covered: vim, htop, tmux, nano, bash/zsh prompt, git, less, bat.
// Edge cases: extreme resize, rapid alternate-screen toggle, OSC storms,
// malformed escape sequences, DCS passthrough, Kitty graphics fragments,
// mixed wide + combining chars.

use tako_core::terminal::Terminal;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn t(cols: usize, rows: usize) -> Terminal {
    Terminal::new(cols, rows)
}

fn feed(term: &mut Terminal, data: impl AsRef<[u8]>) {
    term.feed(data.as_ref());
    // drain replies so the output buffer never fills up
    let _ = term.take_output();
}

// alias for readability — same function
fn feeds(term: &mut Terminal, data: impl AsRef<[u8]>) {
    feed(term, data);
}

// ---------------------------------------------------------------------------
// vim / neovim startup
// ---------------------------------------------------------------------------

/// vim enters the alternate screen, clears it, draws its UI and status bar.
#[test]
fn vim_startup_does_not_crash() {
    let mut t = t(80, 24);
    // smcup — enter alternate screen
    feeds(&mut t, "\x1b[?1049h");
    // disable app-cursor, enable app-keypad
    feeds(&mut t, "\x1b[?1l\x1b=");
    // clear screen, go home
    feeds(&mut t, "\x1b[2J\x1b[H");
    // draw 20 empty rows
    for row in 1..=20usize {
        feeds(&mut t, format!("\x1b[{row};1H\x1b[K"));
    }
    // status bar (row 24) with reverse video
    feeds(&mut t, "\x1b[24;1H\x1b[7m");
    feeds(&mut t, "\"test.txt\"  10L, 200B written");
    feeds(&mut t, "\x1b[m");
    // mode indicator
    feeds(&mut t, "\x1b[24;70H\x1b[32m10,1\x1b[m\x1b[24;77HAll");
    // a short file body
    feeds(&mut t, "\x1b[1;1H");
    for i in 1..=10u32 {
        feeds(&mut t, format!("\x1b[{i};1H\x1b[K{i}  Hello world\r\n"));
    }
    // cursor movement simulation (user typing hjkl)
    for _ in 0..50 {
        feeds(&mut t, "\x1b[A\x1b[B\x1b[C\x1b[D");
    }
    // rmcup — restore main screen
    feeds(&mut t, "\x1b[?1049l");
}

/// neovim adds bracketed paste and focus events on top of vim's basics.
#[test]
fn neovim_mode_sequences_do_not_crash() {
    let mut t = t(120, 40);
    feeds(&mut t, "\x1b[?1049h\x1b[?2004h\x1b[?1004h");
    feeds(&mut t, "\x1b[2J\x1b[1;1H");
    // neovim draws the whole screen with SGR colors
    for row in 1u32..=40 {
        let col = (row % 8) + 30;
        feeds(&mut t, format!("\x1b[{row};1H\x1b[{col}m~ \x1b[m\x1b[K"));
    }
    // OSC title update
    feeds(&mut t, "\x1b]2;NVIM\x07");
    // sign column with Unicode
    feeds(&mut t, "\x1b[3;1H\x1b[33m▎\x1b[m");
    feeds(&mut t, "\x1b[?1049l\x1b[?2004l\x1b[?1004l");
}

// ---------------------------------------------------------------------------
// htop — heavy cursor + color grid
// ---------------------------------------------------------------------------

#[test]
fn htop_startup_does_not_crash() {
    let mut t = t(180, 48);
    feeds(&mut t, "\x1b[?1049h\x1b[?7l");
    feeds(&mut t, "\x1b[2J\x1b[H");
    // header bar
    feeds(&mut t, "\x1b[1;1H\x1b[30;42m");
    feeds(&mut t, "  CPU[");
    feeds(&mut t, "\x1b[32;42m");
    feeds(&mut t, "##########");
    feeds(&mut t, "\x1b[30;42m");
    feeds(&mut t, " 42.3%]\x1b[m");
    // mem bar
    feeds(&mut t, "\x1b[2;1H\x1b[30;42mMem[\x1b[34;42m######\x1b[30;42m      3.2G/16.0G]\x1b[m");
    // process list header
    feeds(&mut t, "\x1b[3;1H\x1b[30;42m  PID USER      PRI  NI  VIRT   RES S  CPU% MEM%  TIME+   Command\x1b[m\x1b[K");
    // 40 process rows
    for i in 0..40usize {
        let pid = 1000 + i;
        let cpu = (i * 3) % 100;
        let mem = (i * 2) % 50;
        feeds(
            &mut t,
            format!(
                "\x1b[{};1H\x1b[K {:>5} root      20   0  250M  120M S {:>4.1} {:>4.1} 0:0{i:02}.00 process-{i}\x1b[m",
                4 + i,
                pid,
                cpu as f32 / 10.0,
                mem as f32 / 10.0,
            ),
        );
    }
    // footer with function keys
    feeds(&mut t, "\x1b[48;1H\x1b[30;42m F1Help  F2Setup  F3SearchF4Filter\x1b[m");
    feeds(&mut t, "\x1b[?1049l\x1b[?7h");
}

// ---------------------------------------------------------------------------
// tmux — DCS passthrough + complex title handling
// ---------------------------------------------------------------------------

#[test]
fn tmux_startup_does_not_crash() {
    let mut t = t(220, 50);
    // tmux wraps every escape in a DCS passthrough when the outer terminal
    // supports the tmux protocol; but from the outer terminal's perspective
    // these are just DCS strings to ignore.
    let dcs_enter_alt = "\x1bP\x1b[?1049h\x1b\\";
    let dcs_clear = "\x1bP\x1b[2J\x1b\\";
    feeds(&mut t, dcs_enter_alt);
    feeds(&mut t, dcs_clear);
    // regular sequences for status bar
    feeds(&mut t, "\x1b[50;1H");
    feeds(&mut t, "\x1b[30;42m [0] 0:zsh*  \x1b[m");
    feeds(&mut t, "\x1b]2;0:zsh\x07");
    // pane content
    feeds(&mut t, "\x1b[1;1H");
    feeds(&mut t, "\x1b[32muser\x1b[m@\x1b[34mhost\x1b[m:\x1b[36m~\x1b[m$ ");
    // window split creates two panes — simulate by drawing an ASCII divider
    feeds(&mut t, "\x1b[1;110H");
    for row in 1..=49usize {
        feeds(&mut t, format!("\x1b[{row};110H│"));
    }
    // mouse mode
    feeds(&mut t, "\x1b[?1000h\x1b[?1002h\x1b[?1006h");
    feeds(&mut t, "\x1b[?1000l\x1b[?1002l\x1b[?1006l");
}

// ---------------------------------------------------------------------------
// nano — editor UI
// ---------------------------------------------------------------------------

#[test]
fn nano_startup_does_not_crash() {
    let mut t = t(80, 24);
    feeds(&mut t, "\x1b[?1049h");
    feeds(&mut t, "\x1b[1;1H\x1b[K");
    // title bar
    feeds(&mut t, "\x1b[7m  GNU nano 6.2  \x1b[m");
    // file content rows
    for row in 2..=22usize {
        feeds(&mut t, format!("\x1b[{row};1H\x1b[K"));
    }
    // menu bar
    feeds(&mut t, "\x1b[23;1H\x1b[7m^G\x1b[m Help   \x1b[7m^X\x1b[m Exit   \x1b[7m^O\x1b[m Write  \x1b[7m^R\x1b[m Read");
    feeds(&mut t, "\x1b[24;1H\x1b[7m^K\x1b[m Cut    \x1b[7m^U\x1b[m Paste  \x1b[7m^W\x1b[m Where  \x1b[7m^\\\x1b[m Replac");
    // typing simulation
    for i in 0..80u8 {
        let ch = (b'a' + (i % 26)) as char;
        feeds(&mut t, ch.to_string());
    }
    // save dialog
    feeds(&mut t, "\x1b[24;1H\x1b[7mFile Name to Write: \x1b[mtest.txt\x07");
    feeds(&mut t, "\x1b[?1049l");
}

// ---------------------------------------------------------------------------
// git diff / log output
// ---------------------------------------------------------------------------

#[test]
fn git_diff_output_does_not_crash() {
    let mut t = t(120, 40);
    let diff = concat!(
        "\x1b[1mdiff --git a/src/main.rs b/src/main.rs\x1b[m\n",
        "\x1b[1mindex 1234567..abcdef0 100644\x1b[m\n",
        "\x1b[1m--- a/src/main.rs\x1b[m\n",
        "\x1b[1m+++ b/src/main.rs\x1b[m\n",
        "\x1b[36m@@ -1,10 +1,12 @@\x1b[m\n",
        "\x1b[31m-fn main() {\x1b[m\n",
        "\x1b[32m+fn main() -> anyhow::Result<()> {\x1b[m\n",
        " \x1b[m    println!(\"hello\");\n",
        "\x1b[32m+    Ok(())\x1b[m\n",
        " }\n",
    );
    feeds(&mut t, diff);
}

#[test]
fn git_log_graph_does_not_crash() {
    let mut t = t(120, 40);
    // git log --graph --oneline --decorate output
    let log = concat!(
        "\x1b[33m*\x1b[m \x1b[33mabc1234\x1b[m\x1b[1;32m (HEAD -> main)\x1b[m Add feature\n",
        "\x1b[33m|\x1b[m \x1b[33mdef5678\x1b[m\x1b[1;31m (origin/main)\x1b[m Fix bug\n",
        "\x1b[33m* \x1b[m\x1b[33m9ab0123\x1b[m Refactor core\n",
        "\x1b[33m|\\ \x1b[m\n",
        "\x1b[33m| *\x1b[m \x1b[33mfed4567\x1b[m\x1b[1;33m (feature-branch)\x1b[m WIP\n",
        "\x1b[33m|/ \x1b[m\n",
        "\x1b[33m*\x1b[m \x1b[33m1234abc\x1b[m Initial commit\n",
    );
    feeds(&mut t, log);
}

// ---------------------------------------------------------------------------
// less / bat (pager with line numbers and syntax highlight)
// ---------------------------------------------------------------------------

#[test]
fn less_startup_does_not_crash() {
    let mut t = t(120, 40);
    feeds(&mut t, "\x1b[?1049h");
    feeds(&mut t, "\x1b[?7h\x1b[?25l");
    // draw a page of syntax-highlighted Rust
    let lines = [
        "\x1b[35muse\x1b[m \x1b[36mstd::collections::HashMap\x1b[m;",
        "",
        "\x1b[35mfn\x1b[m \x1b[32mmain\x1b[m() {",
        "    \x1b[35mlet\x1b[m \x1b[35mmut\x1b[m map = HashMap::new();",
        "    map.insert(\x1b[33m\"key\"\x1b[m, \x1b[33m42\x1b[m);",
        "}",
    ];
    for (i, line) in lines.iter().enumerate() {
        feeds(&mut t, format!("\x1b[{};1H\x1b[K{line}", i + 1));
    }
    feeds(&mut t, "\x1b[40;1H\x1b[7m:q\x1b[m");
    feeds(&mut t, "\x1b[?25h\x1b[?1049l");
}

// ---------------------------------------------------------------------------
// Bash / zsh colored prompt
// ---------------------------------------------------------------------------

#[test]
fn bash_prompt_does_not_crash() {
    let mut t = t(80, 24);
    // typical PS1 with colors, bold, reset
    for _ in 0..10 {
        feeds(&mut t, "\x1b[01;32muser@host\x1b[00m:\x1b[01;34m~/projects\x1b[00m$ ");
        feeds(&mut t, "ls -la\r\n");
        feeds(&mut t, "\x1b[01;34mtotal 42\x1b[m\r\n");
        feeds(&mut t, "drwxr-xr-x  5 user group  160 Aug  7 14:00 .\r\n");
        feeds(&mut t, "drwxr-xr-x 42 user group 1344 Aug  6 09:12 ..\r\n");
    }
}

#[test]
fn zsh_prompt_with_unicode_does_not_crash() {
    let mut t = t(80, 24);
    // zsh with Powerline-style prompt using Unicode glyphs
    for _ in 0..5 {
        feeds(&mut t, "\x1b[34;42m ~/proj \x1b[42;33m\u{e0b0}\x1b[30;43m main \x1b[43;0m\u{e0b0}\x1b[m ");
        feeds(&mut t, "cargo test\r\n");
        feeds(&mut t, "\x1b[32mrunning 243 tests\x1b[m\r\n");
        feeds(&mut t, "test result: \x1b[32mok\x1b[m. 243 passed; 0 failed\r\n");
    }
}

// ---------------------------------------------------------------------------
// Crash regression: sequences from actual crash logs
// ---------------------------------------------------------------------------

/// The TabBarView SIGABRT was triggered by mouse events during normal use.
/// On the Rust side: rapid alternate-screen toggles stress the grid switch
/// code path that is the underlying state the tab bar reads.
#[test]
fn rapid_alternate_screen_toggle_does_not_crash() {
    let mut t = t(80, 24);
    for _ in 0..200 {
        feeds(&mut t, "\x1b[?1049h");
        feeds(&mut t, "content in alt screen");
        feeds(&mut t, "\x1b[?1049l");
        feeds(&mut t, "content in main screen");
    }
}

/// Resize while the alternate screen is active (GlyphAtlas was called right
/// after resize with stale metrics).
#[test]
fn resize_during_alternate_screen_does_not_crash() {
    let mut t = t(80, 24);
    feeds(&mut t, "\x1b[?1049h\x1b[2J");
    for _ in 0..20 {
        t.resize(160, 48);
        feeds(&mut t, "\x1b[1;1H\x1b[32mHello\x1b[m");
        t.resize(40, 12);
        feeds(&mut t, "\x1b[1;1H\x1b[K");
        t.resize(80, 24);
    }
    feeds(&mut t, "\x1b[?1049l");
}

// ---------------------------------------------------------------------------
// Edge cases: malformed / truncated / adversarial sequences
// ---------------------------------------------------------------------------

/// Unterminated OSC strings should not hang or panic.
#[test]
fn unterminated_osc_does_not_crash() {
    let mut t = t(80, 24);
    // OSC without BEL or ST terminator — parser should absorb until limit
    feeds(&mut t, "\x1b]0;title that never ends");
    feeds(&mut t, "more data after unterminated osc\r\n");
    // then a proper sequence
    feeds(&mut t, "\x1b]0;properly terminated\x07");
    feeds(&mut t, "normal text\r\n");
}

/// DCS (Device Control String) passthrough fragments.
#[test]
fn dcs_passthrough_does_not_crash() {
    let mut t = t(80, 24);
    // Sixel-style DCS
    feeds(&mut t, "\x1bPq#0;2;0;0;0#1;2;100;0;0#2;2;0;0;100");
    feeds(&mut t, "AAAAAAAAAA\x1b\\");
    // tmux DCS wrapping
    feeds(&mut t, "\x1bP\x1b[?1049h\x1b\\");
    feeds(&mut t, "\x1bP\x1b[2J\x1b[H\x1b\\");
}

/// APC sequences (used by Kitty graphics protocol and iTerm2 inline images).
#[test]
fn apc_sequences_do_not_crash() {
    let mut t = t(80, 24);
    // Kitty graphics: transmit a tiny 1×1 red pixel (RGB, base64)
    feeds(&mut t, "\x1b_Ga=T,f=24,s=1,v=1,m=0;/9j/\x1b\\");
    // malformed APC (no ST terminator before more data)
    feeds(&mut t, "\x1b_garbage");
    feeds(&mut t, "normal text after\r\n");
}

/// Mixing right-to-left Unicode (Arabic/Hebrew) with LTR text.
#[test]
fn mixed_rtl_ltr_text_does_not_crash() {
    let mut t = t(80, 24);
    feeds(&mut t, "Hello \u{0645}\u{0631}\u{062d}\u{0628}\u{0627} World\r\n");
    feeds(&mut t, "\u{05E9}\u{05DC}\u{05D5}\u{05DD} mixed with ascii\r\n");
    feeds(&mut t, "Normal line\r\n");
}

/// Extremely long lines that wrap many times.
#[test]
fn very_long_line_does_not_crash() {
    let mut t = t(80, 24);
    // 10 000 chars — wraps 125 times
    let long = "X".repeat(10_000);
    feeds(&mut t, long.as_bytes());
    feeds(&mut t, b"\r\n");
    // then scrollback
    feeds(&mut t, "after long line\r\n");
}

/// Wide characters (CJK) at column boundaries.
#[test]
fn wide_chars_at_column_boundary_do_not_crash() {
    let mut t = t(10, 5);
    // 日 is 2-wide; at col 9 it should create a spacer head at col 9 and
    // place the glyph on the next row's col 0.
    feeds(&mut t, "123456789日本語テスト");
    feeds(&mut t, "\r\n");
    // back to back wide chars filling the row
    for _ in 0..10 {
        feeds(&mut t, "日");
    }
}

/// Combining characters stacked on a single cell.
#[test]
fn combining_chars_do_not_crash() {
    let mut t = t(80, 24);
    // Stack many combining marks on the same base char
    let base = 'a';
    let combining = [
        '\u{0300}', // combining grave
        '\u{0301}', // combining acute
        '\u{0302}', // combining circumflex
        '\u{0308}', // combining umlaut
        '\u{0327}', // combining cedilla
    ];
    let s: String = std::iter::once(base).chain(combining.iter().copied()).collect();
    for _ in 0..80 {
        feeds(&mut t, s.as_bytes());
    }
}

/// Zero-width joiner sequences (emoji families, flags).
#[test]
fn zwj_emoji_sequences_do_not_crash() {
    let mut t = t(80, 10);
    // family: man+woman+girl+boy ZWJ sequence
    feeds(&mut t, "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}\r\n");
    // flag (regional indicator letters): 🇺🇸
    feeds(&mut t, "\u{1F1FA}\u{1F1F8} flag\r\n");
    // skin tone modifier
    feeds(&mut t, "\u{1F44D}\u{1F3FB} thumbs up light\r\n");
    // keycap sequence: 1️⃣
    feeds(&mut t, "1\u{FE0F}\u{20E3} keycap\r\n");
}

/// Rapid OSC 10/11 color queries (terminal replies that could overflow output).
#[test]
fn osc_color_query_storm_does_not_crash() {
    let mut t = t(80, 24);
    for _ in 0..500 {
        feeds(&mut t, "\x1b]10;?\x07");
        feeds(&mut t, "\x1b]11;?\x07");
        let _ = t.take_output();
    }
}

/// Mode set/reset storm (what a buggy app might do).
#[test]
fn mode_toggle_storm_does_not_crash() {
    let mut t = t(80, 24);
    let modes = [
        "\x1b[?1h",   // app cursor
        "\x1b[?1l",
        "\x1b[?7h",   // wraparound
        "\x1b[?7l",
        "\x1b[?25h",  // cursor visible
        "\x1b[?25l",
        "\x1b[?1000h", // mouse X10
        "\x1b[?1000l",
        "\x1b[?1049h", // alt screen
        "\x1b[?1049l",
        "\x1b[?2004h", // bracketed paste
        "\x1b[?2004l",
    ];
    for _ in 0..100 {
        for m in &modes {
            feeds(&mut t, m.as_bytes());
        }
    }
}

/// Cursor save/restore around a resize — a common source of out-of-bounds.
#[test]
fn cursor_save_restore_across_resize_does_not_crash() {
    let mut t = t(80, 24);
    for _ in 0..50 {
        feeds(&mut t, "\x1b[12;40H"); // move cursor
        feeds(&mut t, "\x1b7");       // save (DEC)
        t.resize(40, 12);
        feeds(&mut t, "\x1b8");       // restore — must clamp to new size
        feeds(&mut t, "X");
        t.resize(80, 24);
        feeds(&mut t, "\x1b[s\x1b[u"); // ANSI save/restore
    }
}

/// Origin mode + margins: DECSTBM + cursor addressing.
#[test]
fn scroll_region_with_origin_mode_does_not_crash() {
    let mut t = t(80, 24);
    feeds(&mut t, "\x1b[5;20r"); // set scroll region rows 5-20
    feeds(&mut t, "\x1b[?6h");   // origin mode on
    for i in 1..=16u32 {
        feeds(&mut t, format!("\x1b[{i};1H\x1b[K  line {i}"));
    }
    feeds(&mut t, "\x1b[?6l");   // origin mode off
    feeds(&mut t, "\x1b[r");     // reset scroll region
}

/// Protected cells (DECSCA) should survive erase operations.
#[test]
fn protected_cells_do_not_crash() {
    let mut t = t(80, 24);
    feeds(&mut t, "\x1b[1\"q");  // DECSCA protect
    feeds(&mut t, "PROTECTED");
    feeds(&mut t, "\x1b[0\"q");  // DECSCA unprotect
    feeds(&mut t, "\x1b[?2K");   // selective erase
    feeds(&mut t, "\x1b[?1J");   // selective erase above
    feeds(&mut t, "\x1b[?2J");   // selective erase display
}

/// Kitty keyboard protocol: push / pop stack depth.
#[test]
fn kitty_keyboard_stack_does_not_crash() {
    let mut t = t(80, 24);
    // push 9 frames (max is 8; 9th drops the oldest)
    for flags in 0..9u8 {
        feeds(&mut t, format!("\x1b[={flags}u"));
    }
    // pop more than stack depth — should clamp gracefully
    feeds(&mut t, "\x1b[20;1u");
    // query
    feeds(&mut t, "\x1b[?u");
    let _ = t.take_output();
}

/// Hyperlinks (OSC 8) with nested and empty parameters.
#[test]
fn osc8_hyperlinks_do_not_crash() {
    let mut t = t(80, 24);
    // open a hyperlink
    feeds(&mut t, "\x1b]8;id=1;https://example.com\x07");
    feeds(&mut t, "click here");
    // close
    feeds(&mut t, "\x1b]8;;\x07");
    // empty URI
    feeds(&mut t, "\x1b]8;;\x07\x1b]8;;\x07");
    // very long URI (> 256 chars)
    let long_url = format!("\x1b]8;;https://example.com/{}\x07", "a".repeat(300));
    feeds(&mut t, long_url.as_bytes());
    feeds(&mut t, "text\x1b]8;;\x07\r\n");
}

/// Scrollback accumulation: fill scrollback past capacity without crashing.
#[test]
fn scrollback_overflow_does_not_crash() {
    let mut t = t(80, 24);
    // 12 000 lines > DEFAULT_SCROLLBACK_CAPACITY (10 000); oldest lines evict.
    for i in 0..12_000u32 {
        feeds(&mut t, format!("line {i:05}\r\n"));
    }
    // only verify the visible grid height, not that we panicked
    let visible = t.plain_string();
    assert!(visible.lines().count() <= 24);
}

/// Simultaneous resize + scrollback stress.
#[test]
fn resize_with_full_scrollback_does_not_crash() {
    let mut t = t(80, 24);
    for i in 0..500u32 {
        feeds(&mut t, format!("content line {i:03}\r\n"));
    }
    // reflow across a range of widths
    for cols in [40usize, 60, 80, 100, 120, 60, 40, 80] {
        t.resize(cols, 24);
    }
}

/// Extreme terminal sizes should not panic.
#[test]
fn extreme_sizes_do_not_crash() {
    for (cols, rows) in [(1, 1), (1, 200), (200, 1), (500, 200), (1, 1)] {
        let mut term = Terminal::new(cols, rows);
        feeds(&mut term, b"hello\r\nworld\r\n");
        feeds(&mut term, b"\x1b[2J\x1b[H");
        for _ in 0..10 {
            feeds(&mut term, b"\x1b[1;1H\x1b[K");
        }
    }
}
