// XTSHIFTESCAPE (CSI > Ps s): a program says whether Shift should reach it
// with mouse events or stay the terminal's, for extending a selection. The
// host's mouse-shift-capture decides whether the request counts; the engine
// only remembers it.

use tako_core::ffi::TakoCore;
use tako_core::terminal::Terminal;

#[test]
fn a_program_that_never_asks_has_no_preference() {
    let term = Terminal::new(20, 4);
    assert_eq!(term.modes().shift_capture, None);
}

#[test]
fn ps_1_asks_for_shift_and_ps_0_gives_it_back() {
    let mut term = Terminal::new(20, 4);
    term.feed(b"\x1b[>1s");
    assert_eq!(term.modes().shift_capture, Some(true));
    term.feed(b"\x1b[>0s");
    assert_eq!(term.modes().shift_capture, Some(false));
    term.feed(b"\x1b[>1s\x1b[>s");
    assert_eq!(term.modes().shift_capture, Some(false), "no parameter is 0");
}

#[test]
fn it_is_not_the_save_cursor_it_resembles() {
    // CSI s without the > saves the cursor (SCOSC); with it, nothing is
    // saved, so a restore goes back to what was saved before it.
    let mut term = Terminal::new(20, 4);
    term.feed(b"a\x1b7b\x1b[>1scd\x1b8");
    assert_eq!(term.cursor(), (0, 1));
}

#[test]
fn ris_forgets_the_request() {
    let mut term = Terminal::new(20, 4);
    term.feed(b"\x1b[>1s\x1bc");
    assert_eq!(term.modes().shift_capture, None);
}

#[test]
fn a_checkpoint_carries_the_request() {
    for (sequence, expected) in [(&b""[..], None), (b"\x1b[>0s", Some(false)), (b"\x1b[>1s", Some(true))] {
        let mut term = Terminal::new(20, 4);
        term.feed(sequence);
        let mut restored = Terminal::new(20, 4);
        restored.import_checkpoint(&term.export_checkpoint().unwrap()).unwrap();
        assert_eq!(restored.modes().shift_capture, expected);
    }
}

#[test]
fn the_host_can_read_it() {
    let core = TakoCore::new(20, 4);
    assert_eq!(core.mouse_shift_capture(), None);
    core.feed(b"\x1b[>1s".to_vec());
    assert_eq!(core.mouse_shift_capture(), Some(true));
}
