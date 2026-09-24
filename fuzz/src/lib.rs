pub mod chunking;
pub mod harness;
pub mod ops;
pub mod streams;

/// Returns at most `max_bytes` of `value` without splitting a UTF-8 scalar.
///
/// Arbitrary strings routinely contain multibyte text. Fuzz harness bounds
/// must never manufacture a panic before the bytes reach the code under test.
pub fn truncate_utf8(value: &str, max_bytes: usize) -> &str {
    if value.len() <= max_bytes {
        return value;
    }

    let mut end = max_bytes;
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    &value[..end]
}

pub use chunking::{test_chunking_differential, ChunkingInput};
pub use harness::{
    assert_observable_state_eq, assert_safe_readback, modes_eq, palette_eq, TerminalStateSnapshot,
};
pub use ops::{
    apply_op, apply_ops, clamp_cols, clamp_rows, clamp_scrollback, ArbitrarySelectionMode,
    TerminalOp, TerminalOpInput,
};
pub use streams::{build_escape_stream, EscapeStreamInput, EscapeToken};

#[cfg(test)]
mod tests {
    use super::*;
    use tako_core::terminal::{SelectionMode, Terminal};

    #[test]
    fn test_assert_safe_readback_fresh() {
        let mut term = Terminal::new(80, 24);
        assert_safe_readback(&mut term);
    }

    #[test]
    fn test_assert_safe_readback_populated() {
        let mut term = Terminal::with_scrollback(80, 24, 500);

        // Plain text + SGR styling + wide UTF-8 glyphs
        term.feed(
            b"Hello \x1b[1;31mRed Bold\x1b[0m World! \xF0\x9F\xA6\x80 \xE4\xB8\xAD\xE6\x96\x87\n",
        );

        // OSC 8 Hyperlink
        term.feed(b"\x1b]8;id=link1;https://example.com\x1b\\Click Here\x1b]8;;\x1b\\\n");

        // OSC 0 Title & OSC 7 Pwd & OSC 133 prompt markers
        term.feed(b"\x1b]0;Fuzz Test Title\x07");
        term.feed(b"\x1b]7;file://localhost/tmp\x07");
        term.feed(b"\x1b]133;A\x07$ \x1b]133;B\x07echo 1\x1b]133;C\x07\n1\n\x1b]133;D;0\x07");

        // Selection
        term.start_selection(0, 0, SelectionMode::Linear);
        term.extend_selection(1, 10);
        assert!(term.has_selection());

        // Readback check with active selection
        assert_safe_readback(&mut term);

        // Word and Line selection
        term.select_word(0, 2);
        assert_safe_readback(&mut term);

        term.select_line(0, 0);
        assert_safe_readback(&mut term);

        // Alternate screen buffer
        term.feed(b"\x1b[?1049hAlternate Screen Text");
        assert_safe_readback(&mut term);

        // Return to primary
        term.feed(b"\x1b[?1049l");
        assert_safe_readback(&mut term);
    }

    #[test]
    fn test_chunking_differential_ascii_and_sgr() {
        let input = ChunkingInput {
            cols: 80,
            rows: 24,
            data: b"Line 1: \x1b[32mGreen\x1b[0m\nLine 2: \x1b[44mBlue BG\x1b[0m\nLine 3: 12345"
                .to_vec(),
            split_points: vec![1, 2, 5, 8, 12, 15, 20, 25, 30, 35, 40],
        };
        test_chunking_differential(&input);
    }

    #[test]
    fn test_chunking_differential_utf8_split() {
        // Multi-byte UTF-8 sequences (2-byte, 3-byte, 4-byte) split at every byte
        let data = "Alpha β CJK: 中文 Emoji: 🦀 🎉 Text".as_bytes().to_vec();
        let split_points = (0..data.len() as u16).collect();
        let input = ChunkingInput {
            cols: 80,
            rows: 24,
            data,
            split_points,
        };
        test_chunking_differential(&input);
    }

    #[test]
    fn test_chunking_differential_escape_intermediate_split() {
        // CSI with multiple parameters, intermediates, SGR truecolor
        let data = b"\x1b[38;2;255;128;64;48;5;201;1;3;4:3mComplex \x1b[?25lHidden\x1b[?25h\x1b[0m"
            .to_vec();
        let split_points = (0..data.len() as u16).collect();
        let input = ChunkingInput {
            cols: 80,
            rows: 24,
            data,
            split_points,
        };
        test_chunking_differential(&input);
    }

    #[test]
    fn test_chunking_differential_osc_split() {
        // OSC title and hyperlinks split across chunks
        let data =
            b"\x1b]0;Window Title\x07\x1b]8;id=x;http://test\x1b\\Link Text\x1b]8;;\x1b\\".to_vec();
        let split_points = (0..data.len() as u16).collect();
        let input = ChunkingInput {
            cols: 80,
            rows: 24,
            data,
            split_points,
        };
        test_chunking_differential(&input);
    }

    #[test]
    fn test_chunking_differential_dcs_and_modes() {
        let data = b"\x1bP$q\"p\x1b\\\x1b[?1049h\x1b[?2026hAlt+Sync\x1b[?2026l\x1b[?1049l".to_vec();
        let split_points = (0..data.len() as u16).collect();
        let input = ChunkingInput {
            cols: 80,
            rows: 24,
            data,
            split_points,
        };
        test_chunking_differential(&input);
    }

    #[test]
    fn test_chunking_differential_random_bytes() {
        let mut data = Vec::with_capacity(512);
        for i in 0..512 {
            let b = ((i * 37 + 13) % 256) as u8;
            data.push(b);
        }
        let split_points = vec![0, 1, 3, 7, 15, 31, 63, 127, 255, 300, 450, 511];
        let input = ChunkingInput {
            cols: 40,
            rows: 15,
            data,
            split_points,
        };
        test_chunking_differential(&input);
    }

    #[test]
    fn test_selection_modes_and_text() {
        let mut term = Terminal::new(20, 5);
        term.feed(b"ABCDEFGHIJ0123456789\nKLMNOPQRST0123456789\n");

        // Linear forward selection
        term.start_selection(0, 0, SelectionMode::Linear);
        term.extend_selection(0, 5);
        assert_eq!(term.selected_text().as_deref(), Some("ABCDEF"));
        assert_safe_readback(&mut term);

        // Rectangular selection
        term.start_selection(0, 2, SelectionMode::Rectangular);
        term.extend_selection(1, 4);
        assert_safe_readback(&mut term);

        // Backward selection
        term.start_selection(1, 5, SelectionMode::Linear);
        term.extend_selection(0, 2);
        assert_safe_readback(&mut term);

        term.clear_selection();
        assert!(!term.has_selection());
        assert_eq!(term.selected_text(), None);
    }

    #[test]
    fn test_scrollback_eviction_and_reflow() {
        let mut term = Terminal::with_scrollback(20, 5, 10);
        for i in 0..30 {
            term.feed(format!("Line #{i:03} with some extra filler text\n").as_bytes());
            assert_safe_readback(&mut term);
        }

        // Trigger reflow by resizing width
        term.resize(10, 5);
        assert_safe_readback(&mut term);

        term.resize(40, 10);
        assert_safe_readback(&mut term);
    }

    #[test]
    fn test_terminal_ops_interleaved() {
        let ops = vec![
            TerminalOp::Feed(
                b"First line of text that is fairly long to test soft wrapping across columns"
                    .to_vec(),
            ),
            TerminalOp::Resize { cols: 40, rows: 20 },
            TerminalOp::StartSelection {
                row: 0,
                col: 0,
                mode: ArbitrarySelectionMode::Linear,
            },
            TerminalOp::ExtendSelection { row: 1, col: 15 },
            TerminalOp::SelectWord { row: 0, col: 5 },
            TerminalOp::SelectLine { row: 0, col: 0 },
            TerminalOp::ClearSelection,
            TerminalOp::ScrollUp(5),
            TerminalOp::ScrollDown(2),
            TerminalOp::ScrollBottom,
            TerminalOp::SetScrollPosition(128),
            TerminalOp::SetDarkScheme(true),
            TerminalOp::SetAnswerback("answerback test".to_string()),
            TerminalOp::SetXtversion("tako 1.0".to_string()),
            TerminalOp::MarkAllDamaged,
            TerminalOp::ResizeWithPixels {
                cols: 80,
                rows: 24,
                width_px: 800,
                height_px: 600,
            },
            TerminalOp::ResizeWithCellSize {
                cols: 80,
                rows: 24,
                cell_w: 10,
                cell_h: 20,
            },
        ];

        let input = TerminalOpInput {
            initial_cols: 80,
            initial_rows: 24,
            initial_scrollback: 1000,
            ops,
        };

        apply_ops(&input);
    }

    #[test]
    fn test_escape_stream_builder_and_feed() {
        let tokens = vec![
            EscapeToken::AsciiText("Welcome\n".to_string()),
            EscapeToken::Utf8Text("Unicode: 🦀\n".to_string()),
            EscapeToken::CsiCursorMove {
                row: 5,
                col: 10,
                cmd: 0,
            },
            EscapeToken::CsiSgr {
                params: vec![1, 31, 42],
            },
            EscapeToken::CsiErase {
                mode: 2,
                in_display: true,
            },
            EscapeToken::CsiInsertDelete {
                count: 2,
                is_line: true,
                is_insert: true,
            },
            EscapeToken::CsiScroll { count: 3, up: true },
            EscapeToken::CsiMargins {
                top: 1,
                bottom: 20,
                left: 1,
                right: 70,
            },
            EscapeToken::CsiMode {
                mode: 1049,
                set: true,
                private: true,
            },
            EscapeToken::AsciiText("Alternate\n".to_string()),
            EscapeToken::CsiMode {
                mode: 1049,
                set: false,
                private: true,
            },
            EscapeToken::CsiCursorStyle(2),
            EscapeToken::CsiTab(0),
            EscapeToken::CsiDsr(1),
            EscapeToken::CsiProtection(1),
            EscapeToken::CsiKittyKeyboard { flags: 3, mode: 0 },
            EscapeToken::OscTitle("Test Title".to_string()),
            EscapeToken::OscColor {
                index: 1,
                r: 255,
                g: 0,
                b: 0,
            },
            EscapeToken::OscDefaultColor {
                target: 0,
                r: 200,
                g: 200,
                b: 200,
            },
            EscapeToken::OscPwd("/home/user".to_string()),
            EscapeToken::OscHyperlink {
                id: "1".to_string(),
                uri: "https://example.com".to_string(),
                text: "click".to_string(),
            },
            EscapeToken::OscNotification {
                title: "Alert".to_string(),
                body: "Message".to_string(),
            },
            EscapeToken::OscClipboard("clip data".to_string()),
            EscapeToken::OscPromptMarker(0),
            EscapeToken::OscProgress {
                state: 1,
                value: 50,
            },
            EscapeToken::DcsDecrqss("m".to_string()),
            EscapeToken::DcsXtgettcap("4b6579".to_string()),
            EscapeToken::DcsKittyGraphics(b"a=T,f=32,s=1,v=1;AAAA".to_vec()),
            EscapeToken::ApcStream(b"apc data".to_vec()),
            EscapeToken::SyncOutput(true),
            EscapeToken::AsciiText("Sync Frame\n".to_string()),
            EscapeToken::SyncOutput(false),
        ];

        let input = EscapeStreamInput {
            cols: 80,
            rows: 24,
            tokens,
        };

        let (cols, rows, bytes) = build_escape_stream(&input);
        let mut term = Terminal::new(cols, rows);
        term.feed(&bytes);
        assert_safe_readback(&mut term);
    }

    #[test]
    fn test_extreme_dimensions_safe_readback() {
        let dims = [(1, 1), (1, 100), (200, 1), (200, 100)];
        for (c, r) in dims {
            let mut term = Terminal::new(c, r);
            term.feed(b"Test short text\nLine 2\x1b[31mRed\x1b[0m\n");
            assert_safe_readback(&mut term);
        }
    }

    #[test]
    fn test_bounds_enforcement() {
        assert_eq!(clamp_cols(0), 1);
        assert_eq!(clamp_rows(0), 1);
        assert_eq!(clamp_scrollback(0), 1);
        assert!(clamp_cols(u8::MAX) <= 200);
        assert!(clamp_rows(u8::MAX) <= 100);
        assert!(clamp_scrollback(u16::MAX) <= 2000);
    }

    #[test]
    fn test_utf8_truncation_never_splits_a_scalar() {
        assert_eq!(truncate_utf8("abc", 64), "abc");
        assert_eq!(truncate_utf8("abc🦀def", 6), "abc");
        assert_eq!(truncate_utf8("世界", 4), "世");
        assert_eq!(truncate_utf8("🦀", 0), "");
    }
}
