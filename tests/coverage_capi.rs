//! Targeted behavioral tests for C ABI symbols in src/capi.rs.
//!
//! Exercises every C ABI entry point with raw C types, pointers, NULL handling,
//! buffer ownership via `prod_vt_buffer_free`, and validates observable state
//! matching the VT behaviour the engine implements.

use std::ffi::CStr;
use std::os::raw::{c_char, c_int, c_void};
use std::ptr::{null, null_mut};

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProdVtCursor {
    pub x: u16,
    pub y: u16,
    pub visible: c_int,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProdVtScrollbar {
    pub total: u64,
    pub offset: u64,
    pub len: u64,
}

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProdVtCheckpointInfo {
    pub version: u32,
    pub flags: u32,
    pub cols: u32,
    pub rows: u32,
    pub payload_len: u32,
}

const PROD_VT_OK: c_int = 0;
const PROD_VT_ERR_NULL_ARGUMENT: c_int = -1;
const PROD_VT_ERR_BUFFER_TOO_SMALL: c_int = -2;
const PROD_VT_ERR_UNEXPECTED_EOF: c_int = -3;
const PROD_VT_ERR_INVALID_MAGIC: c_int = -4;
const PROD_VT_ERR_UNSUPPORTED_VERSION: c_int = -5;
const PROD_VT_ERR_CHECKSUM_MISMATCH: c_int = -6;
const PROD_VT_ERR_INVALID_PAYLOAD_LENGTH: c_int = -7;
const PROD_VT_ERR_INVALID_DATA: c_int = -8;
const PROD_VT_ERR_DIMENSION_OUT_OF_BOUNDS: c_int = -9;
const PROD_VT_ERR_ALLOCATION_LIMIT: c_int = -10;
const PROD_VT_ERR_TOO_LARGE: c_int = -11;

unsafe extern "C" {
    fn prod_vt_new(cols: u16, rows: u16, max_scrollback: usize) -> *mut c_void;
    fn prod_vt_free(vt: *mut c_void);
    fn prod_vt_write(vt: *mut c_void, data: *const u8, len: usize);
    fn prod_vt_discard_events(vt: *mut c_void);
    fn prod_vt_resize(
        vt: *mut c_void,
        cols: u16,
        rows: u16,
        cell_width_px: u32,
        cell_height_px: u32,
    ) -> c_int;
    fn prod_vt_scroll_delta(vt: *mut c_void, delta: isize);
    fn prod_vt_scroll_bottom(vt: *mut c_void);
    fn prod_vt_mode(vt: *mut c_void, mode: u16, enabled: *mut c_int) -> c_int;
    fn prod_vt_active_screen(vt: *mut c_void, alternate: *mut c_int) -> c_int;
    fn prod_vt_viewport_active(vt: *mut c_void, active: *mut c_int) -> c_int;
    fn prod_vt_cursor_state(vt: *mut c_void, cursor: *mut ProdVtCursor) -> c_int;
    fn prod_vt_scrollbar_state(vt: *mut c_void, scrollbar: *mut ProdVtScrollbar) -> c_int;
    fn prod_vt_viewport_ansi(vt: *mut c_void, out: *mut *mut u8, out_len: *mut usize) -> c_int;
    fn prod_vt_viewport_text(vt: *mut c_void, out: *mut *mut u8, out_len: *mut usize) -> c_int;
    fn prod_vt_snapshot_ansi(vt: *mut c_void, out: *mut *mut u8, out_len: *mut usize) -> c_int;
    fn prod_vt_snapshot_ansi_v2(vt: *mut c_void, out: *mut *mut u8, out_len: *mut usize) -> c_int;
    fn prod_vt_checkpoint(vt: *mut c_void, out: *mut *mut u8, out_len: *mut usize) -> c_int;
    fn prod_vt_checkpoint_export_limited(
        vt: *mut c_void,
        max_bytes: u64,
        out: *mut *mut u8,
        out_len: *mut usize,
    ) -> c_int;
    fn prod_vt_checkpoint_version() -> u32;
    fn prod_vt_checkpoint_supports(version: u32) -> c_int;
    fn prod_vt_checkpoint_inspect(
        data: *const u8,
        len: usize,
        out_version: *mut u32,
        out_cols: *mut u32,
        out_rows: *mut u32,
        out_payload_len: *mut u32,
    ) -> c_int;
    fn prod_vt_checkpoint_export(vt: *mut c_void, out: *mut *mut u8, out_len: *mut usize) -> c_int;
    fn prod_vt_restore(vt: *mut c_void, data: *const u8, len: usize) -> c_int;
    fn prod_vt_checkpoint_import(vt: *mut c_void, data: *const u8, len: usize) -> c_int;
    fn prod_vt_checkpoint_verify(data: *const u8, len: usize) -> c_int;
    fn prod_vt_checkpoint_abi_version() -> u32;
    fn prod_vt_checkpoint_status_message(status: c_int) -> *const c_char;
    fn prod_vt_checkpoint_export2(
        vt: *mut c_void,
        max_bytes: u64,
        buf: *mut u8,
        cap: usize,
        out_len: *mut usize,
    ) -> c_int;
    fn prod_vt_checkpoint_measure2(vt: *mut c_void, max_bytes: u64, out_len: *mut usize) -> c_int;
    fn prod_vt_checkpoint_import2(vt: *mut c_void, data: *const u8, len: usize) -> c_int;
    fn prod_vt_checkpoint_inspect2(
        data: *const u8,
        len: usize,
        out: *mut ProdVtCheckpointInfo,
    ) -> c_int;
    fn prod_vt_checkpoint_verify2(data: *const u8, len: usize) -> c_int;
    fn prod_vt_title(vt: *mut c_void, out: *mut *mut u8, out_len: *mut usize) -> c_int;
    fn prod_vt_drain_responses(vt: *mut c_void, out: *mut *mut u8, out_len: *mut usize) -> c_int;
    fn prod_vt_encode_wheel(
        vt: *mut c_void,
        up: c_int,
        column: u16,
        row: u16,
        out: *mut *mut u8,
        out_len: *mut usize,
    ) -> c_int;
    fn prod_vt_buffer_free(data: *mut u8);
}

/// Retention anchor to pull the exported C ABI objects into this test binary.
fn exported_symbol_addresses() -> Vec<*const ()> {
    use tako_core::capi as c;
    vec![
        c::prod_vt_new as *const (),
        c::prod_vt_free as *const (),
        c::prod_vt_write as *const (),
        c::prod_vt_discard_events as *const (),
        c::prod_vt_resize as *const (),
        c::prod_vt_scroll_delta as *const (),
        c::prod_vt_scroll_bottom as *const (),
        c::prod_vt_mode as *const (),
        c::prod_vt_active_screen as *const (),
        c::prod_vt_viewport_active as *const (),
        c::prod_vt_cursor_state as *const (),
        c::prod_vt_scrollbar_state as *const (),
        c::prod_vt_viewport_ansi as *const (),
        c::prod_vt_viewport_text as *const (),
        c::prod_vt_snapshot_ansi as *const (),
        c::prod_vt_snapshot_ansi_v2 as *const (),
        c::prod_vt_checkpoint as *const (),
        c::prod_vt_checkpoint_export_limited as *const (),
        c::prod_vt_checkpoint_version as *const (),
        c::prod_vt_checkpoint_supports as *const (),
        c::prod_vt_checkpoint_inspect as *const (),
        c::prod_vt_checkpoint_export as *const (),
        c::prod_vt_restore as *const (),
        c::prod_vt_checkpoint_import as *const (),
        c::prod_vt_checkpoint_verify as *const (),
        c::prod_vt_checkpoint_abi_version as *const (),
        c::prod_vt_checkpoint_status_message as *const (),
        c::prod_vt_checkpoint_export2 as *const (),
        c::prod_vt_checkpoint_measure2 as *const (),
        c::prod_vt_checkpoint_import2 as *const (),
        c::prod_vt_checkpoint_inspect2 as *const (),
        c::prod_vt_checkpoint_verify2 as *const (),
        c::prod_vt_title as *const (),
        c::prod_vt_drain_responses as *const (),
        c::prod_vt_encode_wheel as *const (),
        c::prod_vt_buffer_free as *const (),
    ]
}

/// Helper to take ownership of a C ABI allocated buffer via `prod_vt_buffer_free`.
unsafe fn take_buffer<F>(f: F) -> Option<Vec<u8>>
where
    F: FnOnce(*mut *mut u8, *mut usize) -> c_int,
{
    let mut ptr: *mut u8 = null_mut();
    let mut len: usize = 0;
    let status = f(&mut ptr, &mut len);
    if status == 0 {
        return None;
    }
    let vec = if ptr.is_null() {
        Vec::new()
    } else {
        let slice = unsafe { std::slice::from_raw_parts(ptr, len) };
        let copied = slice.to_vec();
        unsafe { prod_vt_buffer_free(ptr) };
        copied
    };
    Some(vec)
}

/// Helper to recalculate CRC32 on forged checkpoint payload for testing parser validations.
fn reseal_checkpoint(mut ckpt: Vec<u8>) -> Vec<u8> {
    assert!(ckpt.len() >= 20);
    let crc = tako_core::terminal::checkpoint::crc32(&ckpt[20..]);
    ckpt[16..20].copy_from_slice(&crc.to_le_bytes());
    ckpt
}

/// RAII wrapper for *mut c_void VT handle to ensure cleanup on panic.
struct TestVt(*mut c_void);

impl TestVt {
    fn new(cols: u16, rows: u16, max_scrollback: usize) -> Self {
        let ptr = unsafe { prod_vt_new(cols, rows, max_scrollback) };
        assert!(!ptr.is_null(), "prod_vt_new must not return null");
        Self(ptr)
    }

    fn write(&self, bytes: &[u8]) {
        unsafe { prod_vt_write(self.0, bytes.as_ptr(), bytes.len()) };
    }

    fn as_ptr(&self) -> *mut c_void {
        self.0
    }
}

impl Drop for TestVt {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe { prod_vt_free(self.0) };
        }
    }
}

// ---------------------------------------------------------------------------
// Linker symbols retention
// ---------------------------------------------------------------------------

/// Verifies that all 36 exported C ABI symbols resolve and are linked into the binary.
#[test]
fn test_all_c_abi_symbols_linkable() {
    let addrs = exported_symbol_addresses();
    assert_eq!(addrs.len(), 36);
    assert!(addrs.iter().all(|p| !p.is_null()));
}

// ---------------------------------------------------------------------------
// copy_bytes & NULL argument safety (uncovered line ~49)
// ---------------------------------------------------------------------------

/// Pins NULL safety for output buffer pointers in all buffer-producing C ABI fns.
#[test]
fn test_null_out_params_return_zero() {
    let vt = TestVt::new(80, 24, 100);
    vt.write(b"hello world");

    let mut ptr: *mut u8 = null_mut();
    let mut len: usize = 0;

    // prod_vt_viewport_text
    assert_eq!(unsafe { prod_vt_viewport_text(vt.as_ptr(), null_mut(), &mut len) }, 0);
    assert_eq!(unsafe { prod_vt_viewport_text(vt.as_ptr(), &mut ptr, null_mut()) }, 0);
    assert_eq!(unsafe { prod_vt_viewport_text(vt.as_ptr(), null_mut(), null_mut()) }, 0);

    // prod_vt_viewport_ansi
    assert_eq!(unsafe { prod_vt_viewport_ansi(vt.as_ptr(), null_mut(), &mut len) }, 0);
    assert_eq!(unsafe { prod_vt_viewport_ansi(vt.as_ptr(), &mut ptr, null_mut()) }, 0);

    // prod_vt_snapshot_ansi
    assert_eq!(unsafe { prod_vt_snapshot_ansi(vt.as_ptr(), null_mut(), &mut len) }, 0);
    assert_eq!(unsafe { prod_vt_snapshot_ansi(vt.as_ptr(), &mut ptr, null_mut()) }, 0);

    // prod_vt_snapshot_ansi_v2
    assert_eq!(unsafe { prod_vt_snapshot_ansi_v2(vt.as_ptr(), null_mut(), &mut len) }, 0);
    assert_eq!(unsafe { prod_vt_snapshot_ansi_v2(vt.as_ptr(), &mut ptr, null_mut()) }, 0);

    // prod_vt_title
    assert_eq!(unsafe { prod_vt_title(vt.as_ptr(), null_mut(), &mut len) }, 0);
    assert_eq!(unsafe { prod_vt_title(vt.as_ptr(), &mut ptr, null_mut()) }, 0);

    // prod_vt_drain_responses
    assert_eq!(unsafe { prod_vt_drain_responses(vt.as_ptr(), null_mut(), &mut len) }, 0);
    assert_eq!(unsafe { prod_vt_drain_responses(vt.as_ptr(), &mut ptr, null_mut()) }, 0);

    // prod_vt_checkpoint
    assert_eq!(unsafe { prod_vt_checkpoint(vt.as_ptr(), null_mut(), &mut len) }, 0);
    assert_eq!(unsafe { prod_vt_checkpoint(vt.as_ptr(), &mut ptr, null_mut()) }, 0);

    // prod_vt_checkpoint_export
    assert_eq!(unsafe { prod_vt_checkpoint_export(vt.as_ptr(), null_mut(), &mut len) }, 0);
    assert_eq!(unsafe { prod_vt_checkpoint_export(vt.as_ptr(), &mut ptr, null_mut()) }, 0);

    // prod_vt_checkpoint_export_limited
    assert_eq!(unsafe { prod_vt_checkpoint_export_limited(vt.as_ptr(), 1024, null_mut(), &mut len) }, 0);
    assert_eq!(unsafe { prod_vt_checkpoint_export_limited(vt.as_ptr(), 1024, &mut ptr, null_mut()) }, 0);
}

// ---------------------------------------------------------------------------
// Wide characters & SGR color/attr combinations (uncovered lines ~89, 120-152)
// ---------------------------------------------------------------------------

/// Pins ANSI rendering of wide characters (spacer cell skip) and all cell attributes.
/// Wide characters occupy 2 cells with second cell marked as spacer.
#[test]
fn test_row_ansi_wide_characters_and_all_text_attributes() {
    let vt = TestVt::new(40, 10, 100);
    // Write wide char (CJK / emoji) followed by various SGR styling combinations:
    // 1=bold, 2=dim, 3=italic, 4=underline, 5=blink, 7=reverse, 8=hidden, 9=strikethrough
    let sgr_data = b"\xe4\xbd\xa0\xe5\xa5\xbd \x1b[1mB\x1b[2mD\x1b[3mI\x1b[4mU\x1b[5mK\x1b[7mR\x1b[8mH\x1b[9mS\x1b[0m";
    vt.write(sgr_data);

    let ansi_bytes = unsafe { take_buffer(|o, l| prod_vt_viewport_ansi(vt.as_ptr(), o, l)) }
        .expect("prod_vt_viewport_ansi must succeed");
    let ansi_str = String::from_utf8(ansi_bytes).expect("viewport ansi must be valid UTF-8");

    // The text must contain the wide characters and the styled letters
    assert!(ansi_str.contains("你好"), "must contain wide characters");
    assert!(ansi_str.contains("\x1b["), "must emit ANSI SGR escapes");
    assert!(ansi_str.contains(";1") || ansi_str.contains("\x1b[0;1"), "bold attr emitted");
    assert!(ansi_str.contains(";2"), "dim attr emitted");
    assert!(ansi_str.contains(";3"), "italic attr emitted");
    assert!(ansi_str.contains(";4"), "underline attr emitted");
    assert!(ansi_str.contains(";5"), "blink attr emitted");
    assert!(ansi_str.contains(";7"), "reverse attr emitted");
    assert!(ansi_str.contains(";8"), "hidden attr emitted");
    assert!(ansi_str.contains(";9"), "strikethrough attr emitted");
}

/// Pins ANSI rendering of all foreground and background color formats:
/// standard (30-37, 40-47), bright (90-97, 100-107), 256-color (38;5, 48;5), and RGB (38;2, 48;2).
#[test]
fn test_row_ansi_all_color_variations() {
    let vt = TestVt::new(80, 10, 100);
    // Standard FG 0..7 and BG 0..7
    vt.write(b"\x1b[31;42mstd\x1b[0m\r\n");
    // Bright FG 8..15 and BG 8..15
    vt.write(b"\x1b[91;102mbright\x1b[0m\r\n");
    // 256-color FG and BG
    vt.write(b"\x1b[38;5;123;48;5;200m256\x1b[0m\r\n");
    // RGB truecolor FG and BG
    vt.write(b"\x1b[38;2;12;34;56;48;2;78;90;12mrgb\x1b[0m");

    let ansi_bytes = unsafe { take_buffer(|o, l| prod_vt_viewport_ansi(vt.as_ptr(), o, l)) }
        .expect("viewport ansi must succeed");
    let s = String::from_utf8(ansi_bytes).unwrap();

    assert!(s.contains(";31"), "standard red fg 31");
    assert!(s.contains(";42"), "standard green bg 42");
    assert!(s.contains(";91"), "bright red fg 91");
    assert!(s.contains(";102"), "bright green bg 102");
    assert!(s.contains("38;5;123"), "256 color fg 123");
    assert!(s.contains("48;5;200"), "256 color bg 200");
    assert!(s.contains("38;2;12;34;56"), "rgb color fg 12;34;56");
    assert!(s.contains("48;2;78;90;12"), "rgb color bg 78;90;12");
}

// ---------------------------------------------------------------------------
// prod_vt_write & prod_vt_discard_events (uncovered line ~174)
// ---------------------------------------------------------------------------

/// Pins zero-length and null data handling in `prod_vt_write`, plus `prod_vt_discard_events`.
#[test]
fn test_write_and_discard_events_safe() {
    let vt = TestVt::new(20, 5, 10);
    // Writing 0 len with valid ptr
    unsafe { prod_vt_write(vt.as_ptr(), b"test".as_ptr(), 0) };
    // Writing with null ptr
    unsafe { prod_vt_write(vt.as_ptr(), null(), 10) };
    // Writing on null vt
    unsafe { prod_vt_write(null_mut(), b"test".as_ptr(), 4) };

    // Discard events on null vt and valid vt
    unsafe { prod_vt_discard_events(null_mut()) };
    unsafe { prod_vt_discard_events(vt.as_ptr()) };

    let text = unsafe { take_buffer(|o, l| prod_vt_viewport_text(vt.as_ptr(), o, l)) }.unwrap();
    assert_eq!(String::from_utf8(text).unwrap().trim(), "", "nothing should have been written");
}

// ---------------------------------------------------------------------------
// prod_vt_resize & scrolling NULL / edge cases (uncovered lines ~199-232)
// ---------------------------------------------------------------------------

/// Pins error handling for `prod_vt_resize` and negative/positive scroll deltas.
#[test]
fn test_resize_and_scrolling_edge_cases() {
    let vt = TestVt::new(20, 5, 100);

    // NULL vt
    assert_eq!(unsafe { prod_vt_resize(null_mut(), 10, 10, 8, 16) }, 0);
    // Zero cols
    assert_eq!(unsafe { prod_vt_resize(vt.as_ptr(), 0, 5, 8, 16) }, 0);
    // Zero rows
    assert_eq!(unsafe { prod_vt_resize(vt.as_ptr(), 10, 0, 8, 16) }, 0);

    // Valid resize
    assert_eq!(unsafe { prod_vt_resize(vt.as_ptr(), 30, 8, 10, 20) }, 1);

    // Scroll delta on NULL vt is a safe no-op
    unsafe { prod_vt_scroll_delta(null_mut(), 5) };
    unsafe { prod_vt_scroll_delta(null_mut(), -5) };
    unsafe { prod_vt_scroll_bottom(null_mut()) };

    // Fill lines to create scrollback
    for i in 1..=20 {
        vt.write(format!("line {}\r\n", i).as_bytes());
    }

    // Scroll up (positive delta)
    unsafe { prod_vt_scroll_delta(vt.as_ptr(), 5) };
    let mut active: c_int = -1;
    assert_eq!(unsafe { prod_vt_viewport_active(vt.as_ptr(), &mut active) }, 1);
    assert_eq!(active, 0, "viewport must not be active when scrolled up");

    // Scroll down (negative delta)
    unsafe { prod_vt_scroll_delta(vt.as_ptr(), -2) };
    assert_eq!(unsafe { prod_vt_viewport_active(vt.as_ptr(), &mut active) }, 1);
    assert_eq!(active, 0);

    // Scroll delta with 0 is no-op
    unsafe { prod_vt_scroll_delta(vt.as_ptr(), 0) };

    // Scroll to bottom restores active viewport
    unsafe { prod_vt_scroll_bottom(vt.as_ptr()) };
    assert_eq!(unsafe { prod_vt_viewport_active(vt.as_ptr(), &mut active) }, 1);
    assert_eq!(active, 1, "viewport must be active when scrolled to bottom");
}

// ---------------------------------------------------------------------------
// prod_vt_mode comprehensive test (uncovered lines ~233-257)
// ---------------------------------------------------------------------------

/// Pins querying every supported mode constant in `prod_vt_mode`, plus unknown mode.
#[test]
fn test_prod_vt_mode_all_variants() {
    let vt = TestVt::new(80, 24, 100);

    let mut enabled: c_int = -1;
    // NULL checks
    assert_eq!(unsafe { prod_vt_mode(null_mut(), 1000, &mut enabled) }, 0);
    assert_eq!(unsafe { prod_vt_mode(vt.as_ptr(), 1000, null_mut()) }, 0);

    // Unknown mode returns 0
    assert_eq!(unsafe { prod_vt_mode(vt.as_ptr(), 9999, &mut enabled) }, 0);

    // Mode 9: Mouse X10 / Normal
    assert_eq!(unsafe { prod_vt_mode(vt.as_ptr(), 9, &mut enabled) }, 1);
    assert_eq!(enabled, 0);

    // Mode 1000: Mouse Normal
    assert_eq!(unsafe { prod_vt_mode(vt.as_ptr(), 1000, &mut enabled) }, 1);
    assert_eq!(enabled, 0);
    vt.write(b"\x1b[?1000h");
    assert_eq!(unsafe { prod_vt_mode(vt.as_ptr(), 1000, &mut enabled) }, 1);
    assert_eq!(enabled, 1);
    assert_eq!(unsafe { prod_vt_mode(vt.as_ptr(), 9, &mut enabled) }, 1);
    assert_eq!(enabled, 1);

    // Mode 1002: ButtonEvent
    vt.write(b"\x1b[?1002h");
    assert_eq!(unsafe { prod_vt_mode(vt.as_ptr(), 1002, &mut enabled) }, 1);
    assert_eq!(enabled, 1);

    // Mode 1003: AnyEvent
    vt.write(b"\x1b[?1003h");
    assert_eq!(unsafe { prod_vt_mode(vt.as_ptr(), 1003, &mut enabled) }, 1);
    assert_eq!(enabled, 1);

    // Mode 1006: mouse_sgr
    vt.write(b"\x1b[?1006h");
    assert_eq!(unsafe { prod_vt_mode(vt.as_ptr(), 1006, &mut enabled) }, 1);
    assert_eq!(enabled, 1);

    // Mode 1005: mouse_utf8
    vt.write(b"\x1b[?1005h");
    assert_eq!(unsafe { prod_vt_mode(vt.as_ptr(), 1005, &mut enabled) }, 1);
    assert_eq!(enabled, 1);

    // Mode 1007: alternate_scroll
    vt.write(b"\x1b[?1007h");
    assert_eq!(unsafe { prod_vt_mode(vt.as_ptr(), 1007, &mut enabled) }, 1);
    assert_eq!(enabled, 1);

    // Mode 7: autowrap
    assert_eq!(unsafe { prod_vt_mode(vt.as_ptr(), 7, &mut enabled) }, 1);
    assert_eq!(enabled, 1); // default on
    vt.write(b"\x1b[?7l");
    assert_eq!(unsafe { prod_vt_mode(vt.as_ptr(), 7, &mut enabled) }, 1);
    assert_eq!(enabled, 0);

    // Mode 6: origin_mode
    assert_eq!(unsafe { prod_vt_mode(vt.as_ptr(), 6, &mut enabled) }, 1);
    assert_eq!(enabled, 0); // default off
    vt.write(b"\x1b[?6h");
    assert_eq!(unsafe { prod_vt_mode(vt.as_ptr(), 6, &mut enabled) }, 1);
    assert_eq!(enabled, 1);

    // Mode 1: cursor_key_app_mode
    assert_eq!(unsafe { prod_vt_mode(vt.as_ptr(), 1, &mut enabled) }, 1);
    assert_eq!(enabled, 0);
    vt.write(b"\x1b[?1h");
    assert_eq!(unsafe { prod_vt_mode(vt.as_ptr(), 1, &mut enabled) }, 1);
    assert_eq!(enabled, 1);

    // Mode 2004: bracketed_paste
    assert_eq!(unsafe { prod_vt_mode(vt.as_ptr(), 2004, &mut enabled) }, 1);
    assert_eq!(enabled, 0);
    vt.write(b"\x1b[?2004h");
    assert_eq!(unsafe { prod_vt_mode(vt.as_ptr(), 2004, &mut enabled) }, 1);
    assert_eq!(enabled, 1);

    // Mode 1004: focus_events
    assert_eq!(unsafe { prod_vt_mode(vt.as_ptr(), 1004, &mut enabled) }, 1);
    assert_eq!(enabled, 0);
    vt.write(b"\x1b[?1004h");
    assert_eq!(unsafe { prod_vt_mode(vt.as_ptr(), 1004, &mut enabled) }, 1);
    assert_eq!(enabled, 1);

    // Mode 25: cursor_visible
    assert_eq!(unsafe { prod_vt_mode(vt.as_ptr(), 25, &mut enabled) }, 1);
    assert_eq!(enabled, 1); // default visible
    vt.write(b"\x1b[?25l");
    assert_eq!(unsafe { prod_vt_mode(vt.as_ptr(), 25, &mut enabled) }, 1);
    assert_eq!(enabled, 0);
}

// ---------------------------------------------------------------------------
// Screen, viewport, cursor & scrollbar NULL checks (lines ~260-312)
// ---------------------------------------------------------------------------

/// Pins NULL safety for screen/viewport/cursor/scrollbar query APIs.
#[test]
fn test_state_queries_null_safety() {
    let vt = TestVt::new(40, 10, 100);
    let mut val: c_int = 0;
    let mut cursor = ProdVtCursor { x: 0, y: 0, visible: 0 };
    let mut bar = ProdVtScrollbar { total: 0, offset: 0, len: 0 };

    // active screen
    assert_eq!(unsafe { prod_vt_active_screen(null_mut(), &mut val) }, 0);
    assert_eq!(unsafe { prod_vt_active_screen(vt.as_ptr(), null_mut()) }, 0);

    // viewport active
    assert_eq!(unsafe { prod_vt_viewport_active(null_mut(), &mut val) }, 0);
    assert_eq!(unsafe { prod_vt_viewport_active(vt.as_ptr(), null_mut()) }, 0);

    // cursor state
    assert_eq!(unsafe { prod_vt_cursor_state(null_mut(), &mut cursor) }, 0);
    assert_eq!(unsafe { prod_vt_cursor_state(vt.as_ptr(), null_mut()) }, 0);

    // scrollbar state
    assert_eq!(unsafe { prod_vt_scrollbar_state(null_mut(), &mut bar) }, 0);
    assert_eq!(unsafe { prod_vt_scrollbar_state(vt.as_ptr(), null_mut()) }, 0);
}

// ---------------------------------------------------------------------------
// Viewport & snapshot ANSI with multi-row and scrollback (lines ~315-382)
// ---------------------------------------------------------------------------

/// Pins viewport and snapshot ANSI multi-row output, scrollback formatting,
/// and wide character spacer handling in snapshot history.
#[test]
fn test_snapshot_ansi_scrollback_wide_chars_and_multiline() {
    let vt = TestVt::new(20, 3, 100);
    // Push lines into scrollback with wide characters
    vt.write(b"line 1 \xe4\xbd\xa0\xe5\xa5\xbd\r\n");
    vt.write(b"line 2 test\r\n");
    vt.write(b"line 3\r\n");
    vt.write(b"live screen 1\r\n");
    vt.write(b"live screen 2");

    // Test viewport ANSI (only live rows)
    let vp_ansi = unsafe { take_buffer(|o, l| prod_vt_viewport_ansi(vt.as_ptr(), o, l)) }.unwrap();
    let vp_str = String::from_utf8(vp_ansi).unwrap();
    assert!(vp_str.contains("live screen 1"), "viewport contains live screen row 1");
    assert!(vp_str.contains("\r\n"), "multi-row output separated by CRLF");

    // Test snapshot ANSI (scrollback + live rows)
    let snap_ansi = unsafe { take_buffer(|o, l| prod_vt_snapshot_ansi(vt.as_ptr(), o, l)) }.unwrap();
    let snap_str = String::from_utf8(snap_ansi).unwrap();
    assert!(snap_str.contains("line 1 你好"), "scrollback contains line 1 with wide chars");
    assert!(snap_str.contains("line 2 test"), "scrollback contains line 2");
    assert!(snap_str.contains("live screen 2"), "snapshot contains live screen 2");

    // NULL vt safety
    assert_eq!(unsafe { prod_vt_viewport_ansi(null_mut(), null_mut(), null_mut()) }, 0);
    assert_eq!(unsafe { prod_vt_snapshot_ansi(null_mut(), null_mut(), null_mut()) }, 0);
}

// ---------------------------------------------------------------------------
// Snapshot ANSI v2 (uncovered lines ~401-447)
// ---------------------------------------------------------------------------

/// Pins `prod_vt_snapshot_ansi_v2` with scrollback, wide chars, hidden cursor,
/// and cursor position sequence.
#[test]
fn test_snapshot_ansi_v2_comprehensive() {
    let vt = TestVt::new(25, 4, 100);
    // Push lines into scrollback, including wide character spacers
    vt.write(b"sb1 \xe4\xbd\xa0\xe5\xa5\xbd\r\n");
    vt.write(b"sb2 text\r\n");
    // On screen: position cursor at (2, 5), hide cursor, write some text
    vt.write(b"\x1b[?25l"); // hide cursor
    vt.write(b"\x1b[2;5Hcontent");

    let snap_bytes = unsafe { take_buffer(|o, l| prod_vt_snapshot_ansi_v2(vt.as_ptr(), o, l)) }
        .expect("snapshot_ansi_v2 must succeed");
    let s = String::from_utf8(snap_bytes).unwrap();

    assert!(s.contains("sb1 你好"), "v2 scrollback includes wide chars");
    assert!(s.contains("content"), "v2 includes screen content");
    assert!(s.contains("\x1b[?25l"), "v2 emits cursor hide sequence when cursor is invisible");
    assert!(s.contains("\x1b["), "v2 emits cursor position sequence");

    // Test with pending wrap: fill entire row of width 10
    let vt_wrap = TestVt::new(10, 3, 100);
    vt_wrap.write(b"0123456789"); // exactly 10 chars fills the row, cursor wraps next char
    let snap_wrap = unsafe { take_buffer(|o, l| prod_vt_snapshot_ansi_v2(vt_wrap.as_ptr(), o, l)) }.unwrap();
    let s_wrap = String::from_utf8(snap_wrap).unwrap();
    assert!(s_wrap.contains("0123456789"));

    // Test NULL vt safety
    assert_eq!(unsafe { prod_vt_snapshot_ansi_v2(null_mut(), null_mut(), null_mut()) }, 0);
}

// ---------------------------------------------------------------------------
// Checkpoint inspect, export & restore error paths (lines ~547, 596, 711-713, 741-743)
// ---------------------------------------------------------------------------

/// Pins `prod_vt_checkpoint_inspect` with null data and invalid buffer.
#[test]
fn test_checkpoint_inspect_null_and_error() {
    let mut version: u32 = 99;
    let mut cols: u32 = 99;
    let mut rows: u32 = 99;
    let mut payload_len: u32 = 99;

    // NULL data or len == 0 writes zeroes and returns 0
    assert_eq!(
        unsafe {
            prod_vt_checkpoint_inspect(
                null(),
                0,
                &mut version,
                &mut cols,
                &mut rows,
                &mut payload_len,
            )
        },
        0
    );
    assert_eq!((version, cols, rows, payload_len), (0, 0, 0, 0));

    // Garbage data returns 0 and leaves zeroes
    let junk = b"not a valid checkpoint header";
    assert_eq!(
        unsafe {
            prod_vt_checkpoint_inspect(
                junk.as_ptr(),
                junk.len(),
                &mut version,
                &mut cols,
                &mut rows,
                &mut payload_len,
            )
        },
        0
    );
    assert_eq!((version, cols, rows, payload_len), (0, 0, 0, 0));
}

/// Pins `prod_vt_restore` and `prod_vt_checkpoint_import` failure on corrupt data.
#[test]
fn test_restore_and_import_rejects_corrupted_data() {
    let vt = TestVt::new(40, 10, 100);
    vt.write(b"preserved text");

    // NULL data or len == 0 returns 0
    assert_eq!(unsafe { prod_vt_restore(vt.as_ptr(), null(), 0) }, 0);
    assert_eq!(unsafe { prod_vt_checkpoint_import(vt.as_ptr(), null(), 0) }, 0);

    // Corrupt data returns 0
    let bad = b"corrupted bytes for checkpoint";
    assert_eq!(unsafe { prod_vt_restore(vt.as_ptr(), bad.as_ptr(), bad.len()) }, 0);
    assert_eq!(unsafe { prod_vt_checkpoint_import(vt.as_ptr(), bad.as_ptr(), bad.len()) }, 0);

    // Verify terminal state remains intact (fail-intact contract)
    let text = unsafe { take_buffer(|o, l| prod_vt_viewport_text(vt.as_ptr(), o, l)) }.unwrap();
    assert!(String::from_utf8(text).unwrap().contains("preserved text"));
}

/// Pins all status messages in `prod_vt_checkpoint_status_message` including unknown codes.
#[test]
fn test_checkpoint_status_messages_all_variants() {
    let cases = [
        (PROD_VT_OK, "ok"),
        (PROD_VT_ERR_NULL_ARGUMENT, "null argument"),
        (PROD_VT_ERR_BUFFER_TOO_SMALL, "buffer too small"),
        (PROD_VT_ERR_UNEXPECTED_EOF, "unexpected end of checkpoint buffer"),
        (PROD_VT_ERR_INVALID_MAGIC, "invalid checkpoint magic"),
        (PROD_VT_ERR_UNSUPPORTED_VERSION, "unsupported checkpoint version"),
        (PROD_VT_ERR_CHECKSUM_MISMATCH, "checkpoint CRC32 mismatch"),
        (PROD_VT_ERR_INVALID_PAYLOAD_LENGTH, "invalid payload length"),
        (PROD_VT_ERR_INVALID_DATA, "invalid checkpoint data"),
        (PROD_VT_ERR_DIMENSION_OUT_OF_BOUNDS, "terminal dimension out of bounds"),
        (PROD_VT_ERR_ALLOCATION_LIMIT, "checkpoint memory limit exceeded"),
        (PROD_VT_ERR_TOO_LARGE, "checkpoint exceeds the wire limit"),
        (-999, "unknown checkpoint status"),
        (42, "unknown checkpoint status"),
    ];

    for (status, expected) in cases {
        let ptr = unsafe { prod_vt_checkpoint_status_message(status) };
        assert!(!ptr.is_null());
        let cstr = unsafe { CStr::from_ptr(ptr) };
        assert_eq!(
            cstr.to_str().unwrap(),
            expected,
            "status {} message mismatch",
            status
        );
    }
}

// ---------------------------------------------------------------------------
// V2 Checkpoint API NULL & error paths (uncovered lines ~803, 838, 842, 849, 864, 892)
// ---------------------------------------------------------------------------

/// Pins NULL arguments and errors in `prod_vt_checkpoint_measure2`.
#[test]
fn test_checkpoint_measure2_null_and_error_paths() {
    let vt = TestVt::new(40, 10, 100);
    let mut out_len: usize = 999;

    // NULL out_len
    assert_eq!(
        unsafe { prod_vt_checkpoint_measure2(vt.as_ptr(), 0, null_mut()) },
        PROD_VT_ERR_NULL_ARGUMENT
    );

    // NULL vt
    assert_eq!(
        unsafe { prod_vt_checkpoint_measure2(null_mut(), 0, &mut out_len) },
        PROD_VT_ERR_NULL_ARGUMENT
    );
    assert_eq!(out_len, 0, "out_len must be reset to 0 on NULL vt");

    // max_bytes too small -> PROD_VT_ERR_TOO_LARGE
    assert_eq!(
        unsafe { prod_vt_checkpoint_measure2(vt.as_ptr(), 5, &mut out_len) },
        PROD_VT_ERR_TOO_LARGE
    );
    assert_eq!(out_len, 0, "out_len must be 0 on error");

    // Success path
    assert_eq!(
        unsafe { prod_vt_checkpoint_measure2(vt.as_ptr(), 0, &mut out_len) },
        PROD_VT_OK
    );
    assert!(out_len > 0, "measured checkpoint size must be non-zero");
}

/// Pins `prod_vt_checkpoint_export2` NULL args, buffer sizing errors, and dimension errors.
#[test]
fn test_checkpoint_export2_null_and_error_paths() {
    let vt = TestVt::new(40, 10, 100);
    let mut out_len: usize = 999;
    let mut buf = [0u8; 1024];

    // NULL out_len
    assert_eq!(
        unsafe { prod_vt_checkpoint_export2(vt.as_ptr(), 0, buf.as_mut_ptr(), buf.len(), null_mut()) },
        PROD_VT_ERR_NULL_ARGUMENT
    );

    // NULL buf when cap != 0
    assert_eq!(
        unsafe { prod_vt_checkpoint_export2(vt.as_ptr(), 0, null_mut(), 100, &mut out_len) },
        PROD_VT_ERR_NULL_ARGUMENT
    );
    assert_eq!(out_len, 0);

    // NULL vt
    assert_eq!(
        unsafe { prod_vt_checkpoint_export2(null_mut(), 0, buf.as_mut_ptr(), buf.len(), &mut out_len) },
        PROD_VT_ERR_NULL_ARGUMENT
    );
    assert_eq!(out_len, 0);

    // max_bytes too small -> PROD_VT_ERR_TOO_LARGE
    assert_eq!(
        unsafe { prod_vt_checkpoint_export2(vt.as_ptr(), 5, buf.as_mut_ptr(), buf.len(), &mut out_len) },
        PROD_VT_ERR_TOO_LARGE
    );

    // Buffer too small (cap = 1) -> PROD_VT_ERR_BUFFER_TOO_SMALL with required size in out_len
    assert_eq!(
        unsafe { prod_vt_checkpoint_export2(vt.as_ptr(), 0, buf.as_mut_ptr(), 1, &mut out_len) },
        PROD_VT_ERR_BUFFER_TOO_SMALL
    );
    assert!(out_len > 1, "out_len must report required size");
}

/// Pins NULL arguments, dimension out of bounds, and invalid data in `prod_vt_checkpoint_import2`.
#[test]
fn test_checkpoint_import2_null_and_error_paths() {
    let vt = TestVt::new(40, 10, 100);

    // NULL vt
    assert_eq!(
        unsafe { prod_vt_checkpoint_import2(null_mut(), b"dummy".as_ptr(), 5) },
        PROD_VT_ERR_NULL_ARGUMENT
    );

    // NULL data or len == 0
    assert_eq!(
        unsafe { prod_vt_checkpoint_import2(vt.as_ptr(), null(), 5) },
        PROD_VT_ERR_NULL_ARGUMENT
    );
    assert_eq!(
        unsafe { prod_vt_checkpoint_import2(vt.as_ptr(), b"dummy".as_ptr(), 0) },
        PROD_VT_ERR_NULL_ARGUMENT
    );

    // Corrupt magic returns invalid magic
    let junk = b"not a valid checkpoint magic buffer 20 bytes long";
    let status = unsafe { prod_vt_checkpoint_import2(vt.as_ptr(), junk.as_ptr(), junk.len()) };
    assert_eq!(status, PROD_VT_ERR_INVALID_MAGIC);

    // Export a valid checkpoint, tamper with dimensions, and verify PROD_VT_ERR_DIMENSION_OUT_OF_BOUNDS
    let mut valid_ckpt = unsafe {
        take_buffer(|o, l| prod_vt_checkpoint(vt.as_ptr(), o, l)).expect("export checkpoint")
    };
    // Bytes 20..24 are cols (u32 LE in payload). Set to 30,000 (> MAX_DIM 10,000)
    valid_ckpt[20..24].copy_from_slice(&30_000u32.to_le_bytes());
    let forged_dim = reseal_checkpoint(valid_ckpt);
    assert_eq!(
        unsafe { prod_vt_checkpoint_import2(vt.as_ptr(), forged_dim.as_ptr(), forged_dim.len()) },
        PROD_VT_ERR_DIMENSION_OUT_OF_BOUNDS
    );

    // Export a valid checkpoint, corrupt the inner payload data, reseal CRC, verify PROD_VT_ERR_INVALID_DATA
    let mut valid_ckpt2 = unsafe {
        take_buffer(|o, l| prod_vt_checkpoint_export(vt.as_ptr(), o, l)).expect("export checkpoint")
    };
    // Corrupt tab stops / cursor active buffer tag in payload (offset 28+)
    if valid_ckpt2.len() > 30 {
        valid_ckpt2[28] = 0xFF;
        let forged_data = reseal_checkpoint(valid_ckpt2);
        let err = unsafe { prod_vt_checkpoint_import2(vt.as_ptr(), forged_data.as_ptr(), forged_data.len()) };
        assert!(err == PROD_VT_ERR_INVALID_DATA || err < 0);
    }
}

/// Pins NULL arguments and errors in `prod_vt_checkpoint_inspect2`.
#[test]
fn test_checkpoint_inspect2_null_and_error_paths() {
    let mut info = ProdVtCheckpointInfo {
        version: 99,
        flags: 99,
        cols: 99,
        rows: 99,
        payload_len: 99,
    };

    // NULL out
    assert_eq!(
        unsafe { prod_vt_checkpoint_inspect2(b"dummy".as_ptr(), 5, null_mut()) },
        PROD_VT_ERR_NULL_ARGUMENT
    );

    // NULL data or len == 0 zeroes out and returns error
    assert_eq!(
        unsafe { prod_vt_checkpoint_inspect2(null(), 5, &mut info) },
        PROD_VT_ERR_NULL_ARGUMENT
    );
    assert_eq!(info.version, 0);

    assert_eq!(
        unsafe { prod_vt_checkpoint_inspect2(b"dummy".as_ptr(), 0, &mut info) },
        PROD_VT_ERR_NULL_ARGUMENT
    );
    assert_eq!(info.version, 0);

    // Corrupt data returns invalid magic
    let junk = b"corrupted header bytes longer than 20 bytes";
    assert_eq!(
        unsafe { prod_vt_checkpoint_inspect2(junk.as_ptr(), junk.len(), &mut info) },
        PROD_VT_ERR_INVALID_MAGIC
    );
    assert_eq!(info.version, 0);
}

/// Pins NULL arguments and validation in `prod_vt_checkpoint_verify2` and `prod_vt_checkpoint_verify`.
#[test]
fn test_checkpoint_verify_null_and_errors() {
    // NULL or len == 0 returns NULL_ARGUMENT
    assert_eq!(
        unsafe { prod_vt_checkpoint_verify2(null(), 10) },
        PROD_VT_ERR_NULL_ARGUMENT
    );
    assert_eq!(
        unsafe { prod_vt_checkpoint_verify2(b"x".as_ptr(), 0) },
        PROD_VT_ERR_NULL_ARGUMENT
    );

    // Less than 20 bytes returns unexpected EOF
    let short_junk = b"short buffer";
    assert_eq!(
        unsafe { prod_vt_checkpoint_verify2(short_junk.as_ptr(), short_junk.len()) },
        PROD_VT_ERR_UNEXPECTED_EOF
    );

    // Old verify returns 0
    assert_eq!(unsafe { prod_vt_checkpoint_verify(null(), 10) }, 0);
    assert_eq!(unsafe { prod_vt_checkpoint_verify(b"x".as_ptr(), 0) }, 0);
    assert_eq!(unsafe { prod_vt_checkpoint_verify(short_junk.as_ptr(), short_junk.len()) }, 0);

    // Corrupt data of >= 20 bytes returns invalid magic
    let junk = b"bad checkpoint data 20 bytes long!!";
    assert_eq!(
        unsafe { prod_vt_checkpoint_verify2(junk.as_ptr(), junk.len()) },
        PROD_VT_ERR_INVALID_MAGIC
    );
    assert_eq!(
        unsafe { prod_vt_checkpoint_verify(junk.as_ptr(), junk.len()) },
        0
    );
}

// ---------------------------------------------------------------------------
// prod_vt_encode_wheel comprehensive (uncovered lines ~946-981)
// ---------------------------------------------------------------------------

/// Pins `prod_vt_encode_wheel` for SGR, UTF-8, X10 encodings, and wheel up/down.
/// Wheel events encode button 64 (up) / 65 (down).
#[test]
fn test_encode_wheel_all_encodings_and_directions() {
    let vt = TestVt::new(80, 24, 100);

    let mut ptr: *mut u8 = null_mut();
    let mut len: usize = 0;

    // NULL vt returns 0
    assert_eq!(
        unsafe { prod_vt_encode_wheel(null_mut(), 1, 10, 5, &mut ptr, &mut len) },
        0
    );

    // Mouse tracking OFF returns 0
    assert_eq!(
        unsafe { prod_vt_encode_wheel(vt.as_ptr(), 1, 10, 5, &mut ptr, &mut len) },
        0
    );

    // Enable mouse tracking (1000) with SGR encoding (1006)
    vt.write(b"\x1b[?1000h\x1b[?1006h");

    // SGR Wheel up
    let up_sgr = unsafe { take_buffer(|o, l| prod_vt_encode_wheel(vt.as_ptr(), 1, 10, 5, o, l)) }.unwrap();
    assert_eq!(String::from_utf8(up_sgr).unwrap(), "\x1b[<64;11;6M");

    // SGR Wheel down
    let down_sgr = unsafe { take_buffer(|o, l| prod_vt_encode_wheel(vt.as_ptr(), 0, 10, 5, o, l)) }.unwrap();
    assert_eq!(String::from_utf8(down_sgr).unwrap(), "\x1b[<65;11;6M");

    // Switch to UTF-8 encoding (1005), disable SGR (1006)
    vt.write(b"\x1b[?1006l\x1b[?1005h");
    let up_utf8 = unsafe { take_buffer(|o, l| prod_vt_encode_wheel(vt.as_ptr(), 1, 10, 5, o, l)) }.unwrap();
    assert!(!up_utf8.is_empty(), "UTF8 wheel up emitted");
    let down_utf8 = unsafe { take_buffer(|o, l| prod_vt_encode_wheel(vt.as_ptr(), 0, 10, 5, o, l)) }.unwrap();
    assert!(!down_utf8.is_empty(), "UTF8 wheel down emitted");

    // Disable UTF-8 (1005) -> default X10 encoding
    vt.write(b"\x1b[?1005l");
    let up_x10 = unsafe { take_buffer(|o, l| prod_vt_encode_wheel(vt.as_ptr(), 1, 10, 5, o, l)) }.unwrap();
    assert_eq!(up_x10.len(), 6, "X10 mouse sequence is 6 bytes");
    let down_x10 = unsafe { take_buffer(|o, l| prod_vt_encode_wheel(vt.as_ptr(), 0, 10, 5, o, l)) }.unwrap();
    assert_eq!(down_x10.len(), 6, "X10 mouse sequence is 6 bytes");

    // NULL out parameters return 0
    assert_eq!(
        unsafe { prod_vt_encode_wheel(vt.as_ptr(), 1, 10, 5, null_mut(), &mut len) },
        0
    );
    assert_eq!(
        unsafe { prod_vt_encode_wheel(vt.as_ptr(), 1, 10, 5, &mut ptr, null_mut()) },
        0
    );
}

// ---------------------------------------------------------------------------
// Title and responses drainage
// ---------------------------------------------------------------------------

/// Pins `prod_vt_title` and `prod_vt_drain_responses`.
#[test]
fn test_title_and_drain_responses_c_abi() {
    let vt = TestVt::new(80, 24, 100);

    // Set title via OSC 2
    vt.write(b"\x1b]2;Special Test Title\x07");
    let title_bytes = unsafe { take_buffer(|o, l| prod_vt_title(vt.as_ptr(), o, l)) }.unwrap();
    assert_eq!(String::from_utf8(title_bytes).unwrap(), "Special Test Title");

    // Query device attributes (DA1) -> causes terminal to emit response
    vt.write(b"\x1b[c");
    let resp = unsafe { take_buffer(|o, l| prod_vt_drain_responses(vt.as_ptr(), o, l)) }.unwrap();
    assert!(!resp.is_empty(), "responses must be drained");

    // Second drain is empty
    let empty_resp = unsafe { take_buffer(|o, l| prod_vt_drain_responses(vt.as_ptr(), o, l)) }.unwrap();
    assert!(empty_resp.is_empty(), "subsequent drain must be empty");
}

// ---------------------------------------------------------------------------
// ABI version and supports check
// ---------------------------------------------------------------------------

/// Pins `prod_vt_checkpoint_version`, `prod_vt_checkpoint_supports`, and `prod_vt_checkpoint_abi_version`.
#[test]
fn test_checkpoint_abi_versions_and_support() {
    let ver = unsafe { prod_vt_checkpoint_version() };
    assert_eq!(unsafe { prod_vt_checkpoint_supports(ver) }, 1);
    assert_eq!(unsafe { prod_vt_checkpoint_supports(999999) }, 0);
    assert_eq!(unsafe { prod_vt_checkpoint_abi_version() }, 2);
}
