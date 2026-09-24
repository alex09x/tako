use arbitrary::Arbitrary;

use crate::ops::{clamp_cols, clamp_rows};
use crate::truncate_utf8;

/// High-level escape sequence token for structured stream generation.
#[derive(Arbitrary, Debug, Clone)]
pub enum EscapeToken {
    RawBytes(Vec<u8>),
    AsciiText(String),
    Utf8Text(String),
    CsiCursorMove {
        row: u8,
        col: u8,
        cmd: u8,
    },
    CsiErase {
        mode: u8,
        in_display: bool,
    },
    CsiInsertDelete {
        count: u8,
        is_line: bool,
        is_insert: bool,
    },
    CsiScroll {
        count: u8,
        up: bool,
    },
    CsiMargins {
        top: u8,
        bottom: u8,
        left: u8,
        right: u8,
    },
    CsiMode {
        mode: u16,
        set: bool,
        private: bool,
    },
    CsiSgr {
        params: Vec<u8>,
    },
    CsiCursorStyle(u8),
    CsiTab(u8),
    CsiDsr(u8),
    CsiProtection(u8),
    CsiKittyKeyboard {
        flags: u8,
        mode: u8,
    },
    OscTitle(String),
    OscColor {
        index: u8,
        r: u8,
        g: u8,
        b: u8,
    },
    OscDefaultColor {
        target: u8,
        r: u8,
        g: u8,
        b: u8,
    },
    OscPwd(String),
    OscHyperlink {
        id: String,
        uri: String,
        text: String,
    },
    OscNotification {
        title: String,
        body: String,
    },
    OscClipboard(String),
    OscPromptMarker(u8),
    OscProgress {
        state: u8,
        value: u8,
    },
    DcsDecrqss(String),
    DcsXtgettcap(String),
    DcsKittyGraphics(Vec<u8>),
    ApcStream(Vec<u8>),
    SwitchScreen(bool),
    SyncOutput(bool),
}

/// Input structure for the escape sequences and stream stress fuzz target.
#[derive(Arbitrary, Debug, Clone)]
pub struct EscapeStreamInput {
    pub cols: u8,
    pub rows: u8,
    pub tokens: Vec<EscapeToken>,
}

/// Converts a slice of [`EscapeToken`]s into a valid, bounded byte stream.
pub fn build_escape_stream(input: &EscapeStreamInput) -> (usize, usize, Vec<u8>) {
    let cols = clamp_cols(input.cols);
    let rows = clamp_rows(input.rows);
    let mut out = Vec::new();

    for token in input.tokens.iter().take(64) {
        if out.len() >= 8192 {
            break;
        }
        match token {
            EscapeToken::RawBytes(bytes) => {
                let take_len = bytes.len().min(512);
                out.extend_from_slice(&bytes[..take_len]);
            }
            EscapeToken::AsciiText(s) => {
                out.extend_from_slice(truncate_utf8(s, 256).as_bytes());
            }
            EscapeToken::Utf8Text(s) => {
                out.extend_from_slice(truncate_utf8(s, 256).as_bytes());
            }
            EscapeToken::CsiCursorMove { row, col, cmd } => {
                let r = (*row as usize % 100) + 1;
                let c = (*col as usize % 200) + 1;
                match cmd % 8 {
                    0 => out.extend_from_slice(format!("\x1b[{r};{c}H").as_bytes()), // CUP
                    1 => out.extend_from_slice(format!("\x1b[{r};{c}f").as_bytes()), // HVP
                    2 => out.extend_from_slice(format!("\x1b[{r}A").as_bytes()),     // CUU
                    3 => out.extend_from_slice(format!("\x1b[{r}B").as_bytes()),     // CUD
                    4 => out.extend_from_slice(format!("\x1b[{c}C").as_bytes()),     // CUF
                    5 => out.extend_from_slice(format!("\x1b[{c}D").as_bytes()),     // CUB
                    6 => out.extend_from_slice(format!("\x1b[{c}G").as_bytes()),     // CHA
                    _ => out.extend_from_slice(format!("\x1b[{r}d").as_bytes()),     // VPA
                }
            }
            EscapeToken::CsiErase { mode, in_display } => {
                let m = mode % 4;
                if *in_display {
                    out.extend_from_slice(format!("\x1b[{m}J").as_bytes());
                } else {
                    out.extend_from_slice(format!("\x1b[{m}K").as_bytes());
                }
            }
            EscapeToken::CsiInsertDelete {
                count,
                is_line,
                is_insert,
            } => {
                let n = (*count as usize % 50) + 1;
                match (is_line, is_insert) {
                    (true, true) => out.extend_from_slice(format!("\x1b[{n}L").as_bytes()), // IL
                    (true, false) => out.extend_from_slice(format!("\x1b[{n}M").as_bytes()), // DL
                    (false, true) => out.extend_from_slice(format!("\x1b[{n}@").as_bytes()), // ICH
                    (false, false) => out.extend_from_slice(format!("\x1b[{n}P").as_bytes()), // DCH
                }
            }
            EscapeToken::CsiScroll { count, up } => {
                let n = (*count as usize % 50) + 1;
                if *up {
                    out.extend_from_slice(format!("\x1b[{n}S").as_bytes());
                } else {
                    out.extend_from_slice(format!("\x1b[{n}T").as_bytes());
                }
            }
            EscapeToken::CsiMargins {
                top,
                bottom,
                left,
                right,
            } => {
                let t = (*top as usize % 50) + 1;
                let b = t + (*bottom as usize % 50) + 1;
                out.extend_from_slice(format!("\x1b[{t};{b}r").as_bytes()); // DECSTBM

                let l = (*left as usize % 100) + 1;
                let r = l + (*right as usize % 100) + 1;
                out.extend_from_slice(format!("\x1b[?69h\x1b[{l};{r}s").as_bytes());
                // DECSLRM
            }
            EscapeToken::CsiMode { mode, set, private } => {
                let term_char = if *set { 'h' } else { 'l' };
                if *private {
                    out.extend_from_slice(format!("\x1b[?{mode}{term_char}").as_bytes());
                } else {
                    out.extend_from_slice(format!("\x1b[{mode}{term_char}").as_bytes());
                }
            }
            EscapeToken::CsiSgr { params } => {
                if params.is_empty() {
                    out.extend_from_slice(b"\x1b[0m");
                } else {
                    let formatted = params
                        .iter()
                        .take(16)
                        .map(|p| p.to_string())
                        .collect::<Vec<_>>()
                        .join(";");
                    out.extend_from_slice(format!("\x1b[{formatted}m").as_bytes());
                }
            }
            EscapeToken::CsiCursorStyle(style) => {
                let s = style % 7;
                out.extend_from_slice(format!("\x1b[{s} q").as_bytes());
            }
            EscapeToken::CsiTab(action) => match action % 4 {
                0 => out.extend_from_slice(b"\x1bH"),   // HTS
                1 => out.extend_from_slice(b"\x1b[0g"), // TBC clear at cursor
                2 => out.extend_from_slice(b"\x1b[3g"), // TBC clear all
                _ => out.extend_from_slice(b"\x1b[Z"),  // CBT backtab
            },
            EscapeToken::CsiDsr(kind) => match kind % 6 {
                0 => out.extend_from_slice(b"\x1b[5n"),
                1 => out.extend_from_slice(b"\x1b[6n"),
                2 => out.extend_from_slice(b"\x1b[?6n"),
                3 => out.extend_from_slice(b"\x1b[?15n"),
                4 => out.extend_from_slice(b"\x1b[?62n"),
                _ => out.extend_from_slice(b"\x1b[?63n"),
            },
            EscapeToken::CsiProtection(action) => match action % 5 {
                0 => out.extend_from_slice(b"\x1b[0\"q"), // DECSCA 0
                1 => out.extend_from_slice(b"\x1b[1\"q"), // DECSCA 1
                2 => out.extend_from_slice(b"\x1bV"),     // SPA
                3 => out.extend_from_slice(b"\x1bW"),     // EPA
                _ => out.extend_from_slice(b"\x1b[?2J"),  // DECSED
            },
            EscapeToken::CsiKittyKeyboard { flags, mode } => match mode % 4 {
                0 => out.extend_from_slice(format!("\x1b[={flags}u").as_bytes()),
                1 => out.extend_from_slice(format!("\x1b[>{flags}u").as_bytes()),
                2 => out.extend_from_slice(format!("\x1b[<{flags}u").as_bytes()),
                _ => out.extend_from_slice(b"\x1b[?u"),
            },
            EscapeToken::OscTitle(title) => {
                let t = truncate_utf8(title, 64);
                out.extend_from_slice(format!("\x1b]0;{t}\x07").as_bytes());
            }
            EscapeToken::OscColor { index, r, g, b } => {
                out.extend_from_slice(
                    format!("\x1b]4;{index};rgb:{r:02x}/{g:02x}/{b:02x}\x07").as_bytes(),
                );
            }
            EscapeToken::OscDefaultColor { target, r, g, b } => {
                let code = match target % 3 {
                    0 => 10,
                    1 => 11,
                    _ => 12,
                };
                out.extend_from_slice(
                    format!("\x1b]{code};rgb:{r:02x}/{g:02x}/{b:02x}\x07").as_bytes(),
                );
            }
            EscapeToken::OscPwd(pwd) => {
                let p = truncate_utf8(pwd, 64);
                out.extend_from_slice(format!("\x1b]7;file://localhost{p}\x07").as_bytes());
            }
            EscapeToken::OscHyperlink { id, uri, text } => {
                let id_sub = truncate_utf8(id, 16);
                let uri_sub = truncate_utf8(uri, 64);
                let text_sub = truncate_utf8(text, 32);
                out.extend_from_slice(
                    format!("\x1b]8;id={id_sub};{uri_sub}\x1b\\{text_sub}\x1b]8;;\x1b\\")
                        .as_bytes(),
                );
            }
            EscapeToken::OscNotification { title, body } => {
                let t = truncate_utf8(title, 32);
                let b = truncate_utf8(body, 64);
                out.extend_from_slice(format!("\x1b]777;notify;{t};{b}\x07").as_bytes());
            }
            EscapeToken::OscClipboard(data) => {
                let d = truncate_utf8(data, 64);
                out.extend_from_slice(format!("\x1b]52;c;{d}\x07").as_bytes());
            }
            EscapeToken::OscPromptMarker(marker) => match marker % 4 {
                0 => out.extend_from_slice(b"\x1b]133;A\x07"),
                1 => out.extend_from_slice(b"\x1b]133;B\x07"),
                2 => out.extend_from_slice(b"\x1b]133;C\x07"),
                _ => out.extend_from_slice(b"\x1b]133;D;0\x07"),
            },
            EscapeToken::OscProgress { state, value } => {
                let s = state % 5;
                let v = value % 101;
                out.extend_from_slice(format!("\x1b]9;4;{s};{v}\x07").as_bytes());
            }
            EscapeToken::DcsDecrqss(param) => {
                let p = truncate_utf8(param, 16);
                out.extend_from_slice(format!("\x1bP$q{p}\x1b\\").as_bytes());
            }
            EscapeToken::DcsXtgettcap(param) => {
                let p = truncate_utf8(param, 16);
                out.extend_from_slice(format!("\x1bP+q{p}\x1b\\").as_bytes());
            }
            EscapeToken::DcsKittyGraphics(bytes) => {
                let take_len = bytes.len().min(128);
                out.extend_from_slice(b"\x1b_G");
                out.extend_from_slice(&bytes[..take_len]);
                out.extend_from_slice(b"\x1b\\");
            }
            EscapeToken::ApcStream(bytes) => {
                let take_len = bytes.len().min(128);
                out.extend_from_slice(b"\x1b_");
                out.extend_from_slice(&bytes[..take_len]);
                out.extend_from_slice(b"\x1b\\");
            }
            EscapeToken::SwitchScreen(alt) => {
                if *alt {
                    out.extend_from_slice(b"\x1b[?1049h");
                } else {
                    out.extend_from_slice(b"\x1b[?1049l");
                }
            }
            EscapeToken::SyncOutput(sync) => {
                if *sync {
                    out.extend_from_slice(b"\x1b[?2026h");
                } else {
                    out.extend_from_slice(b"\x1b[?2026l");
                }
            }
        }
    }

    (cols, rows, out)
}
