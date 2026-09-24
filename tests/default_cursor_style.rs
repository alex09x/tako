// The host's cursor style (its config's cursor-style): what a program's
// DECSCUSR 0 and a reset return to, without overriding a style the program
// chose itself.

use tako_core::cursor_style::{CursorShape, CursorStyle};
use tako_core::ffi::{FfiCursorShape, TakoCore};
use tako_core::terminal::Terminal;

const BAR: CursorStyle = CursorStyle { shape: CursorShape::Bar, blinking: false };
const UNDERLINE_BLINK: CursorStyle = CursorStyle { shape: CursorShape::Underline, blinking: true };

#[test]
fn the_host_default_applies_at_once_while_no_program_chose_a_style() {
    let mut t = Terminal::new(10, 2);
    t.set_default_cursor_style(BAR);
    assert_eq!(t.cursor_style(), BAR);
}

#[test]
fn a_programs_style_wins_until_it_asks_for_the_default() {
    let mut t = Terminal::new(10, 2);
    t.feed(b"\x1b[3 q"); // blinking underline
    t.set_default_cursor_style(BAR);
    assert_eq!(t.cursor_style(), UNDERLINE_BLINK);

    t.feed(b"\x1b[0 q");
    assert_eq!(t.cursor_style(), BAR);
}

#[test]
fn a_reset_returns_to_the_host_default() {
    let mut t = Terminal::new(10, 2);
    t.set_default_cursor_style(BAR);
    t.feed(b"\x1b[3 q");
    t.feed(b"\x1bc");
    assert_eq!(t.cursor_style(), BAR);
}

#[test]
fn the_host_default_survives_the_hosts_own_reset() {
    let core = TakoCore::new(10, 2);
    core.set_default_cursor_style(FfiCursorShape::Bar, false);
    core.feed(b"\x1b[3 q".to_vec());
    core.reset();
    let style = core.cursor_style();
    assert_eq!(style.shape, FfiCursorShape::Bar);
    assert!(!style.blinking);
}

#[test]
fn a_restored_program_style_is_not_replaced_by_the_host_default() {
    let mut t = Terminal::new(10, 2);
    t.feed(b"\x1b[3 q");
    let checkpoint = t.export_checkpoint().unwrap();

    let mut restored = Terminal::new(10, 2);
    restored.import_checkpoint(&checkpoint).unwrap();
    restored.set_default_cursor_style(BAR);

    assert_eq!(restored.cursor_style(), UNDERLINE_BLINK);
}
