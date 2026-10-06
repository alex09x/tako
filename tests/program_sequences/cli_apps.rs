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
    feeds(
        &mut t,
        "\x1b[2;1H\x1b[30;42mMem[\x1b[34;42m######\x1b[30;42m      3.2G/16.0G]\x1b[m",
    );
    // process list header
    feeds(
        &mut t,
        "\x1b[3;1H\x1b[30;42m  PID USER      PRI  NI  VIRT   RES S  CPU% MEM%  TIME+   Command\x1b[m\x1b[K",
    );
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
    feeds(
        &mut t,
        "\x1b[48;1H\x1b[30;42m F1Help  F2Setup  F3SearchF4Filter\x1b[m",
    );
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
    feeds(
        &mut t,
        "\x1b[32muser\x1b[m@\x1b[34mhost\x1b[m:\x1b[36m~\x1b[m$ ",
    );
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
    feeds(
        &mut t,
        "\x1b[23;1H\x1b[7m^G\x1b[m Help   \x1b[7m^X\x1b[m Exit   \x1b[7m^O\x1b[m Write  \x1b[7m^R\x1b[m Read",
    );
    feeds(
        &mut t,
        "\x1b[24;1H\x1b[7m^K\x1b[m Cut    \x1b[7m^U\x1b[m Paste  \x1b[7m^W\x1b[m Where  \x1b[7m^\\\x1b[m Replac",
    );
    // typing simulation
    for i in 0..80u8 {
        let ch = (b'a' + (i % 26)) as char;
        feeds(&mut t, ch.to_string());
    }
    // save dialog
    feeds(
        &mut t,
        "\x1b[24;1H\x1b[7mFile Name to Write: \x1b[mtest.txt\x07",
    );
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
