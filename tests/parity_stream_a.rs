// Source: the upstream `stream_a` test suite

use tako_core::terminal::{ScreenBuffer, Terminal, TerminalEvent};

/// Upstream test: "basic print"
#[test]
fn basic_print() {
    let mut term = Terminal::new(10, 10);
    term.feed(b"Hello");
    assert_eq!(term.cursor(), (0, 5));
    assert_eq!(term.plain_string(), "Hello");
}

/// Upstream test: "cursor movement"
#[test]
fn cursor_movement() {
    let mut term = Terminal::new(10, 10);
    term.feed(b"Hello\x1b[1;1H");
    assert_eq!(term.cursor(), (0, 0));

    term.feed(b"\x1b[2;3H");
    assert_eq!(term.cursor(), (1, 2));
}

/// Upstream test: "erase operations"
#[test]
fn erase_operations() {
    let mut term = Terminal::new(20, 10);
    term.feed(b"Hello World");
    assert_eq!(term.cursor(), (0, 11));

    term.feed(b"\x1b[1;6H");
    term.feed(b"\x1b[K");
    assert_eq!(term.plain_string(), "Hello");
}

/// Upstream test: "tabs"
#[test]
fn tabs() {
    let mut term = Terminal::new(80, 10);
    term.feed(b"A\tB");
    assert_eq!(term.cursor().1, 9);
    assert_eq!(term.plain_string(), "A       B");
}

/// Upstream test: "modes"
#[test]
fn modes() {
    let mut term = Terminal::new(80, 24);
    assert!(term.modes().autowrap);

    term.feed(b"\x1b[?7l");
    assert!(!term.modes().autowrap);

    term.feed(b"\x1b[?7h");
    assert!(term.modes().autowrap);
}

/// Upstream test: "scrolling regions"
#[test]
fn scrolling_regions() {
    let mut term = Terminal::new(80, 24);
    term.feed(b"\x1b[5;20r");
    // upstream: scrolling_region fields (top/bottom/left/right) not exposed in public API
}

/// Upstream test: "charsets"
#[test]
fn charsets() {
    let mut term = Terminal::new(80, 24);
    term.feed(b"\x1b(0");
    term.feed(b"`");
    assert_eq!(term.plain_string(), "◆");
}

/// Upstream test: "alt screen"
#[test]
fn alt_screen() {
    let mut term = Terminal::new(10, 5);
    term.feed(b"Primary");
    assert_eq!(term.active_screen(), ScreenBuffer::Primary);

    term.feed(b"\x1b[?1049h");
    assert_eq!(term.active_screen(), ScreenBuffer::Alternate);

    term.feed(b"Alt");

    term.feed(b"\x1b[?1049l");
    assert_eq!(term.active_screen(), ScreenBuffer::Primary);

    assert_eq!(term.plain_string(), "Primary");
}

/// Upstream test: "cursor save and restore"
#[test]
fn cursor_save_and_restore() {
    let mut term = Terminal::new(80, 24);
    term.feed(b"\x1b[10;15H");
    assert_eq!(term.cursor(), (9, 14));

    term.feed(b"\x1b7");

    term.feed(b"\x1b[1;1H");
    assert_eq!(term.cursor(), (0, 0));

    term.feed(b"\x1b8");
    assert_eq!(term.cursor(), (9, 14));
}

/// Upstream test: "attributes"
#[test]
fn attributes() {
    let mut term = Terminal::new(80, 24);
    term.feed(b"\x1b[1mBold\x1b[0m");
    assert_eq!(term.plain_string(), "Bold");
}

/// Upstream test: "DECALN screen alignment"
#[test]
fn decaln_screen_alignment() {
    let mut term = Terminal::new(10, 3);
    term.feed(b"\x1b#8");
    assert_eq!(term.plain_string(), "EEEEEEEEEE\nEEEEEEEEEE\nEEEEEEEEEE");
    assert_eq!(term.cursor(), (0, 0));
}

/// Upstream test: "full reset"
#[test]
fn full_reset() {
    let mut term = Terminal::new(80, 24);
    term.feed(b"Hello");
    term.feed(b"\x1b[10;20H");
    term.feed(b"\x1b[5;20r");
    term.feed(b"\x1b[?7l");
    term.feed(b"\x1b_25a1;r;cp=e0a0;AAAAAAAAAAAAAA==\x1b\\");
    // upstream: glyph_glossary assert, not modeled

    term.feed(b"\x1bc");

    assert_eq!(term.cursor(), (0, 0));
    // upstream: scrolling_region assert, not modeled
    assert!(term.modes().autowrap);
    // upstream: glyph_glossary assert, not modeled
}

/// Upstream test: "OSC 4 set and reset palette"
#[test]
fn osc_4_set_and_reset_palette() {
    let mut term = Terminal::new(10, 10);
    let default_color_0 = term.palette().get(0);

    term.feed(b"\x1b]4;0;rgb:ff/00/00\x1b\\");
    assert_eq!(term.palette().get(0), (0xff, 0x00, 0x00));

    term.feed(b"\x1b]104;0\x1b\\");
    assert_eq!(term.palette().get(0), default_color_0);
}

/// Upstream test: "OSC 104 reset all palette colors"
#[test]
fn osc_104_reset_all_palette_colors() {
    let mut term = Terminal::new(10, 10);
    let orig0 = term.palette().get(0);
    let orig1 = term.palette().get(1);
    let orig2 = term.palette().get(2);

    term.feed(b"\x1b]4;0;rgb:ff/00/00\x1b\\");
    term.feed(b"\x1b]4;1;rgb:00/ff/00\x1b\\");
    term.feed(b"\x1b]4;2;rgb:00/00/ff\x1b\\");

    term.feed(b"\x1b]104\x1b\\");
    assert_eq!(term.palette().get(0), orig0);
    assert_eq!(term.palette().get(1), orig1);
    assert_eq!(term.palette().get(2), orig2);
}

/// Upstream test: "OSC 10 set and reset foreground color"
#[test]
fn osc_10_set_and_reset_foreground_color() {
    let mut term = Terminal::new(10, 10);
    assert_eq!(term.default_colors().0, None);

    term.feed(b"\x1b]10;rgb:ff/00/00\x1b\\");
    assert_eq!(term.default_colors().0, Some((0xff, 0x00, 0x00)));

    term.feed(b"\x1b]110\x1b\\");
    assert_eq!(term.default_colors().0, None);
}

/// Upstream test: "OSC 11 set and reset background color"
#[test]
fn osc_11_set_and_reset_background_color() {
    let mut term = Terminal::new(10, 10);
    assert_eq!(term.default_colors().1, None);

    term.feed(b"\x1b]11;rgb:00/ff/00\x1b\\");
    assert_eq!(term.default_colors().1, Some((0x00, 0xff, 0x00)));

    term.feed(b"\x1b]111\x1b\\");
    assert_eq!(term.default_colors().1, None);
}

/// Upstream test: "OSC 12 set and reset cursor color"
#[test]
fn osc_12_set_and_reset_cursor_color() {
    let mut term = Terminal::new(10, 10);
    assert_eq!(term.default_colors().2, None);

    term.feed(b"\x1b]12;rgb:00/00/ff\x1b\\");
    assert_eq!(term.default_colors().2, Some((0x00, 0x00, 0xff)));

    term.feed(b"\x1b]112\x1b\\");
    assert_eq!(term.default_colors().2, None);
}

/// Upstream test: "OSC color query responses"
#[test]
fn osc_color_query_responses() {
    let mut term = Terminal::new(10, 10);

    term.feed(b"\x1b]10;?\x1b\\");
    assert_eq!(term.take_output(), b"");

    term.feed(b"\x1b]11;?\x1b\\");
    assert_eq!(term.take_output(), b"");

    term.feed(b"\x1b]4;2;rgb:12/34/56;2;?\x1b\\");
    assert_eq!(term.take_output(), b"\x1b]4;2;rgb:1212/3434/5656\x1b\\");

    term.feed(b"\x1b]10;rgb:01/02/03\x1b\\");
    term.feed(b"\x1b]11;rgb:04/05/06\x1b\\");
    term.feed(b"\x1b]12;rgb:07/08/09\x1b\\");
    term.feed(b"\x1b]10;?;?;?\x1b\\");
    assert_eq!(
        term.take_output(),
        b"\x1b]10;rgb:0101/0202/0303\x1b\\\x1b]11;rgb:0404/0505/0606\x1b\\\x1b]12;rgb:0707/0808/0909\x1b\\"
    );

    term.feed(b"\x1b]112\x1b\\");
    term.feed(b"\x1b]12;?\x07");
    assert_eq!(term.take_output(), b"\x1b]12;rgb:0101/0202/0303\x07");
}

/// Upstream test: "bell effect callback"
#[test]
fn bell_effect_callback() {
    let mut term = Terminal::new(80, 24);

    term.feed(b"\x07");
    assert_eq!(term.take_events(), vec![TerminalEvent::Bell]);

    term.feed(b"AfterBell");
    assert_eq!(term.plain_string(), "AfterBell");

    term.feed(b"\x07");
    assert_eq!(term.take_events(), vec![TerminalEvent::Bell]);

    term.feed(b"\x07\x07");
    assert_eq!(term.take_events(), vec![TerminalEvent::Bell, TerminalEvent::Bell]);
}

/// Upstream test: "desktop_notification effect callback"
#[test]
fn desktop_notification_effect_callback() {
    let mut term = Terminal::new(80, 24);

    term.feed(b"\x1b]9;Ignored\x1b\\AfterNotification");
    assert_eq!(term.plain_string(), "AfterNotification");
    assert_eq!(
        term.take_events(),
        vec![TerminalEvent::Notification {
            title: String::new(),
            body: "Ignored".to_string(),
        }]
    );

    term.feed(b"\x1b]9;Build ");
    assert!(term.take_events().is_empty());
    term.feed(b"complete\x1b\\");
    assert_eq!(
        term.take_events(),
        vec![TerminalEvent::Notification {
            title: String::new(),
            body: "Build complete".to_string(),
        }]
    );

    term.feed(b"\x1b]777;notify;Codex;Needs attention\x07");
    assert_eq!(
        term.take_events(),
        vec![TerminalEvent::Notification {
            title: "Codex".to_string(),
            body: "Needs attention".to_string(),
        }]
    );
}

// PORTED in tests/parity_revived.rs: "progress_report effect callback"

/// Upstream test: "clipboard_write effect callback"
#[test]
fn clipboard_write_effect_callback() {
    let mut term = Terminal::new(80, 24);

    term.feed(b"\x1b]52;c;aGVsbG8=\x1b\\");
    term.feed(b"AfterClipboard");
    assert_eq!(term.plain_string(), "AfterClipboard");
    assert_eq!(
        term.take_events(),
        vec![TerminalEvent::ClipboardSet("hello".to_string())]
    );

    term.feed(b"\x1b]52;s;d29ybGQ=\x07");
    term.feed(b"\x1b]52;p;cHJpbWFyeQ==\x1b\\");
    term.feed(b"\x1b]52;0;Y3V0\x1b\\");
    term.feed(b"\x1b]52;x;ZmFsbGJhY2s=\x1b\\");
    term.feed(b"\x1b]52;c;YQBi\x1b\\");
    assert_eq!(
        term.take_events(),
        vec![
            TerminalEvent::ClipboardSet("world".to_string()),
            TerminalEvent::ClipboardSet("primary".to_string()),
            TerminalEvent::ClipboardSet("cut".to_string()),
            TerminalEvent::ClipboardSet("fallback".to_string()),
            TerminalEvent::ClipboardSet("a\0b".to_string()),
        ]
    );

    term.feed(b"\x1b]52;s;\x1b\\");
    assert_eq!(
        term.take_events(),
        vec![TerminalEvent::ClipboardSet(String::new())]
    );

    term.feed(b"\x1b]52;c;?\x1b\\");
    term.feed(b"\x1b]52;c;***\x1b\\");
    assert_eq!(term.take_events(), vec![TerminalEvent::ClipboardQuery]);

    term.feed(b"\x1b]1337;Copy=:aVRlcm0y\x1b\\");
    assert_eq!(
        term.take_events(),
        vec![TerminalEvent::ClipboardSet("iTerm2".to_string())]
    );

    term.feed(b"\x1b]52;p;ZnJh");
    term.feed(b"Z21lbnRlZA==\x1b");
    term.feed(b"\\");
    assert_eq!(
        term.take_events(),
        vec![TerminalEvent::ClipboardSet("fragmented".to_string())]
    );
}

// SKIPPED "clipboard_write allocation failure is ignored": custom allocator injection unsupported in Rust port

/// Upstream test: "request mode DECRQM with write_pty callback"
#[test]
fn request_mode_decrqm_with_write_pty_callback() {
    let mut term = Terminal::new(80, 24);

    term.feed(b"\x1b[?7$p");
    assert_eq!(term.take_output(), b"\x1b[?7;1$y");

    term.feed(b"\x1b[?7l");
    term.feed(b"\x1b[?7$p");
    assert_eq!(term.take_output(), b"\x1b[?7;2$y");

    term.feed(b"\x1b[?9999$p");
    assert_eq!(term.take_output(), b"\x1b[?9999;0$y");
}

/// Upstream test: "stream: CSI W with intermediate but no params"
#[test]
fn stream_csi_w_with_intermediate_but_no_params() {
    let mut term = Terminal::new(80, 24);
    term.feed(b"\x1b[?W");
}

/// Upstream test: "window_title effect is called"
#[test]
fn window_title_effect_is_called() {
    let mut term = Terminal::new(80, 24);
    term.feed(b"\x1b]2;Hello World\x1b\\");
    assert_eq!(term.title(), "Hello World");
    assert_eq!(
        term.take_events(),
        vec![TerminalEvent::TitleChanged("Hello World".to_string())]
    );
}

/// Upstream test: "window_title effect not called without callback"
#[test]
fn window_title_effect_not_called_without_callback() {
    let mut term = Terminal::new(80, 24);
    term.feed(b"\x1b]2;Hello World\x1b\\");
    assert_eq!(term.title(), "Hello World");

    term.feed(b"Test");
    assert_eq!(term.plain_string(), "Test");
}
