//! Focused executable C/Rust ABI tests for `prod_vt_discard_events`.
//!
//! Pins:
//! - Null safety: `prod_vt_discard_events(NULL)` is a safe no-op.
//! - Repeated discard safety: idempotent and safe on empty and populated event queues.
//! - Queued payload storage actually released: allocator-backed probe demonstrating
//!   the failing control without discard and proving release with discard.
//! - Current title/grid/parser continuation preserved: title, grid text, and
//!   in-flight escape sequences continue without interruption or reset.
//! - Pending DSR/DA/CPR/OSC responses in ResponseQueue preserved.
//! - Checkpoint export remains non-mutating and byte-identical across discards.

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;
use std::os::raw::{c_int, c_void};

thread_local! {
    static ALLOCATED: Cell<u64> = const { Cell::new(0) };
    static LIVE: Cell<i64> = const { Cell::new(0) };
    static COUNTING: Cell<bool> = const { Cell::new(false) };
}

struct Counting;

unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let _ = COUNTING.try_with(|on| {
            if on.get() {
                let _ = ALLOCATED.try_with(|n| n.set(n.get().saturating_add(layout.size() as u64)));
                let _ = LIVE.try_with(|n| n.set(n.get().saturating_add(layout.size() as i64)));
            }
        });
        unsafe { System.alloc(layout) }
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        let _ = COUNTING.try_with(|on| {
            if on.get() {
                let _ = LIVE.try_with(|n| n.set(n.get().saturating_sub(layout.size() as i64)));
            }
        });
        unsafe { System.dealloc(ptr, layout) }
    }

    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        let _ = COUNTING.try_with(|on| {
            if on.get() {
                let grown = new_size.saturating_sub(layout.size());
                let _ = ALLOCATED.try_with(|n| n.set(n.get().saturating_add(grown as u64)));
                let delta = new_size as i64 - layout.size() as i64;
                let _ = LIVE.try_with(|n| n.set(n.get().saturating_add(delta)));
            }
        });
        unsafe { System.realloc(ptr, layout, new_size) }
    }
}

#[global_allocator]
static ALLOCATOR: Counting = Counting;

fn arm_counter() {
    COUNTING.with(|on| on.set(true));
    ALLOCATED.with(|n| n.set(0));
    LIVE.with(|n| n.set(0));
}

fn disarm_counter() {
    COUNTING.with(|on| on.set(false));
}

fn live_bytes() -> i64 {
    LIVE.with(|n| n.get())
}

unsafe extern "C" {
    fn prod_vt_new(cols: u16, rows: u16, max_scrollback: usize) -> *mut c_void;
    fn prod_vt_free(vt: *mut c_void);
    fn prod_vt_write(vt: *mut c_void, data: *const u8, len: usize);
    fn prod_vt_discard_events(vt: *mut c_void);
    fn prod_vt_title(vt: *mut c_void, out: *mut *mut u8, out_len: *mut usize) -> c_int;
    fn prod_vt_viewport_text(vt: *mut c_void, out: *mut *mut u8, out_len: *mut usize) -> c_int;
    fn prod_vt_drain_responses(vt: *mut c_void, out: *mut *mut u8, out_len: *mut usize) -> c_int;
    fn prod_vt_buffer_free(data: *mut u8);
    fn prod_vt_checkpoint_export2(
        vt: *mut c_void,
        max_bytes: u64,
        buf: *mut u8,
        cap: usize,
        out_len: *mut usize,
    ) -> c_int;
    fn prod_vt_checkpoint_import2(vt: *mut c_void, data: *const u8, len: usize) -> c_int;
}

fn exported_symbol_addresses() -> Vec<*const ()> {
    use tako_core::capi as c;
    vec![
        c::prod_vt_new as *const (),
        c::prod_vt_free as *const (),
        c::prod_vt_write as *const (),
        c::prod_vt_discard_events as *const (),
        c::prod_vt_title as *const (),
        c::prod_vt_viewport_text as *const (),
        c::prod_vt_drain_responses as *const (),
        c::prod_vt_buffer_free as *const (),
        c::prod_vt_checkpoint_export2 as *const (),
        c::prod_vt_checkpoint_import2 as *const (),
    ]
}

/// Write a byte slice through the C ABI, taking the length from the slice itself.
///
/// Every write in this suite goes through here: a manually typed length is a
/// buffer overread waiting to happen, and the compiler cannot catch it.
unsafe fn write_seq(vt: *mut c_void, bytes: &[u8]) {
    unsafe { prod_vt_write(vt, bytes.as_ptr(), bytes.len()) };
}

/// Export a checkpoint through the two-call sizing protocol.
unsafe fn export_checkpoint(vt: *mut c_void) -> Vec<u8> {
    let mut needed: usize = 0;
    let st = unsafe { prod_vt_checkpoint_export2(vt, 0, std::ptr::null_mut(), 0, &mut needed) };
    assert_eq!(st, -2, "sizing probe must report PROD_VT_ERR_BUFFER_TOO_SMALL");
    let mut buf = vec![0u8; needed];
    let mut written: usize = 0;
    let st =
        unsafe { prod_vt_checkpoint_export2(vt, 0, buf.as_mut_ptr(), buf.len(), &mut written) };
    assert_eq!(st, 0, "checkpoint export must succeed");
    assert_eq!(written, needed, "export must fill exactly the probed size");
    buf
}

unsafe fn take_buffer(f: impl FnOnce(*mut *mut u8, *mut usize) -> c_int) -> Option<Vec<u8>> {
    let mut ptr: *mut u8 = std::ptr::null_mut();
    let mut len: usize = 0;
    if f(&mut ptr, &mut len) == 0 {
        return None;
    }
    let out = if ptr.is_null() {
        Vec::new()
    } else {
        unsafe { std::slice::from_raw_parts(ptr, len) }.to_vec()
    };
    unsafe { prod_vt_buffer_free(ptr) };
    Some(out)
}

#[test]
fn test_exported_symbols_present() {
    let addrs = exported_symbol_addresses();
    assert_eq!(addrs.len(), 10);
    assert!(addrs.iter().all(|p| !p.is_null()));
}

#[test]
fn test_discard_events_null_safety() {
    unsafe {
        prod_vt_discard_events(std::ptr::null_mut());
    }
}

#[test]
fn test_discard_events_repeated_calls_are_safe() {
    let vt = unsafe { prod_vt_new(80, 24, 100) };
    assert!(!vt.is_null());

    // Multiple discards on clean instance
    unsafe {
        prod_vt_discard_events(vt);
        prod_vt_discard_events(vt);
        prod_vt_discard_events(vt);
    }

    // Queue events
    let seq = b"\x1b]0;Title\x07\x07\x1b]52;c;dGVzdA==\x07";
    unsafe { write_seq(vt, seq) };

    // Multiple discards after events
    unsafe {
        prod_vt_discard_events(vt);
        prod_vt_discard_events(vt);
        prod_vt_discard_events(vt);
    }

    // Still operational
    let post = b"text";
    unsafe { write_seq(vt, post) };
    let text = unsafe { take_buffer(|o, l| prod_vt_viewport_text(vt, o, l)) }.unwrap();
    assert!(String::from_utf8_lossy(&text).contains("text"));

    unsafe { prod_vt_free(vt) };
}

#[test]
fn test_regression_control_retains_queued_payloads_without_discard() {
    // Demonstrates the defect: repeated large OSC title writes queue TerminalEvent
    // instances that are never drained by prod_vt_write, retaining memory on the heap.
    const UPDATES: usize = 10;
    const SIZE: usize = 1 << 20; // 1 MiB each -> ~10 MiB payload
    let expected_min_bytes = (UPDATES * SIZE) as i64;

    let vt = unsafe { prod_vt_new(80, 24, 100) };

    arm_counter();

    for i in 0..UPDATES {
        let mut osc = Vec::with_capacity(SIZE + 16);
        osc.extend_from_slice(b"\x1b]0;");
        let byte = b'A' + (i % 26) as u8;
        osc.extend(std::iter::repeat_n(byte, SIZE));
        osc.push(0x07);
        unsafe { write_seq(vt, &osc) };
        drop(osc);
    }

    let retained_without_discard = live_bytes();
    disarm_counter();

    assert!(
        retained_without_discard >= expected_min_bytes,
        "regression control: without discard, {UPDATES} x 1 MiB OSC titles must retain at least {expected_min_bytes} bytes, got {retained_without_discard}"
    );

    unsafe { prod_vt_free(vt) };
}

#[test]
fn test_queued_payload_storage_actually_released_by_discard() {
    const UPDATES: usize = 10;
    const SIZE: usize = 1 << 20; // 1 MiB each -> ~10 MiB payload
    let expected_min_bytes = (UPDATES * SIZE) as i64;

    let vt = unsafe { prod_vt_new(80, 24, 100) };

    arm_counter();

    for i in 0..UPDATES {
        let mut osc = Vec::with_capacity(SIZE + 16);
        osc.extend_from_slice(b"\x1b]0;");
        let byte = b'A' + (i % 26) as u8;
        osc.extend(std::iter::repeat_n(byte, SIZE));
        osc.push(0x07);
        unsafe { write_seq(vt, &osc) };
        drop(osc);
    }

    let live_before = live_bytes();
    assert!(
        live_before >= expected_min_bytes,
        "pre-discard: expected at least {expected_min_bytes} bytes, got {live_before}"
    );

    // Call discard
    unsafe { prod_vt_discard_events(vt) };

    let live_after = live_bytes();
    disarm_counter();

    let released = live_before - live_after;
    assert!(
        released >= expected_min_bytes,
        "prod_vt_discard_events must release queued event payloads: released {released} bytes, expected at least {expected_min_bytes}"
    );

    unsafe { prod_vt_free(vt) };
}

#[test]
fn test_current_title_grid_and_parser_continuation_preserved() {
    // Two terminals are driven with byte-identical input in lockstep. Only `vt`
    // has prod_vt_discard_events called at the split points; `control` runs the
    // same script uninterrupted. Any state the discard disturbed - including SGR
    // parser state, which no C getter exposes - shows up as a checkpoint diff at
    // the end. Asserting that the screen merely contains "StyledText" would not
    // establish that, because the text renders either way.
    let vt = unsafe { prod_vt_new(80, 24, 100) };
    let control = unsafe { prod_vt_new(80, 24, 100) };

    // 1. Set title and write initial grid text
    let setup = b"\x1b]0;Authoritative Production Title\x07Line 1\r\nLine 2";
    unsafe { write_seq(vt, setup) };
    unsafe { write_seq(control, setup) };

    unsafe { prod_vt_discard_events(vt) };

    let title_bytes = unsafe { take_buffer(|o, l| prod_vt_title(vt, o, l)) }.unwrap();
    assert_eq!(
        String::from_utf8(title_bytes).unwrap(),
        "Authoritative Production Title",
        "title must be preserved across discard"
    );

    let text_bytes = unsafe { take_buffer(|o, l| prod_vt_viewport_text(vt, o, l)) }.unwrap();
    let text = String::from_utf8_lossy(&text_bytes);
    assert!(text.contains("Line 1\nLine 2"), "grid text must be preserved: {text}");

    // 2. Parser continuation: an SGR sequence (underline + italic) split so that
    //    the discard lands mid-escape, between the parameters and the final byte.
    let sgr_head = b"\r\n\x1b[4;3";
    let sgr_tail = b"mStyledText\x1b[0m";
    unsafe { write_seq(vt, sgr_head) };
    unsafe { write_seq(control, sgr_head) };

    unsafe { prod_vt_discard_events(vt) };

    unsafe { write_seq(vt, sgr_tail) };
    unsafe { write_seq(control, sgr_tail) };

    let updated_text_bytes = unsafe { take_buffer(|o, l| prod_vt_viewport_text(vt, o, l)) }.unwrap();
    let updated_text = String::from_utf8_lossy(&updated_text_bytes);
    assert!(
        updated_text.contains("StyledText"),
        "parser must continue valid sequence across discard without truncation: {updated_text}"
    );

    // 3. Parser continuation for OSC: a title sequence split across the discard.
    let osc_head = b"\x1b]0;Updated ";
    let osc_tail = b"Title\x07";
    unsafe { write_seq(vt, osc_head) };
    unsafe { write_seq(control, osc_head) };

    unsafe { prod_vt_discard_events(vt) };

    unsafe { write_seq(vt, osc_tail) };
    unsafe { write_seq(control, osc_tail) };

    let updated_title_bytes = unsafe { take_buffer(|o, l| prod_vt_title(vt, o, l)) }.unwrap();
    assert_eq!(
        String::from_utf8(updated_title_bytes).unwrap(),
        "Updated Title",
        "split OSC title must complete across discard"
    );

    // 4. The real gate: full serialized state against the uninterrupted control.
    //    The control still holds every queued event; the discarded terminal holds
    //    none. Events are excluded from checkpoint serialization, so the two must
    //    be byte-identical - cell attributes, cursor, modes, parser state and all.
    let after_discards = unsafe { export_checkpoint(vt) };
    let uninterrupted = unsafe { export_checkpoint(control) };
    if after_discards != uninterrupted {
        // A full byte dump of two checkpoints is unreadable; report the shape of
        // the divergence instead.
        let at = after_discards
            .iter()
            .zip(uninterrupted.iter())
            .position(|(a, b)| a != b);
        let window = at.map(|i| {
            let lo = i.saturating_sub(8);
            let hi = (i + 8).min(after_discards.len().min(uninterrupted.len()));
            (
                after_discards[lo..hi].to_vec(),
                uninterrupted[lo..hi].to_vec(),
            )
        });
        panic!(
            "terminal state after interleaved discards must equal the uninterrupted control: \
             lengths {} vs {}, first difference at byte offset {:?}, \
             window (discarded vs control) {:?}",
            after_discards.len(),
            uninterrupted.len(),
            at,
            window
        );
    }

    unsafe {
        prod_vt_free(vt);
        prod_vt_free(control);
    }
}

#[test]
fn test_pending_responses_preserved() {
    let vt = unsafe { prod_vt_new(80, 24, 100) };

    // Position cursor at row 5, col 10 (1-indexed)
    let move_cursor = b"\x1b[5;10H";
    unsafe { write_seq(vt, move_cursor) };

    // Give the palette a known synthetic entry so the OSC query below has a
    // deterministic answer.
    let palette_setup = b"\x1b]4;1;#ff8000\x07";
    unsafe { write_seq(vt, palette_setup) };

    // Four queries spanning both response-producing paths:
    //   CSI 6 n   CPR            -> CSI 5 ; 10 R
    //   CSI 5 n   DSR status     -> CSI 0 n
    //   CSI c     Primary DA     -> CSI ? 62 ; 22 c
    //   OSC 4;1;? palette query  -> OSC 4 ; 1 ; rgb:ffff/8080/0000
    let queries = b"\x1b[6n\x1b[5n\x1b[c\x1b]4;1;?\x07";
    unsafe { write_seq(vt, queries) };

    // Discard events: MUST NOT drain or touch ResponseQueue
    unsafe { prod_vt_discard_events(vt) };

    // Drain responses via C API
    let responses = unsafe { take_buffer(|o, l| prod_vt_drain_responses(vt, o, l)) }.unwrap();
    assert!(
        !responses.is_empty(),
        "pending responses must be preserved across discard_events"
    );
    let resp_str = String::from_utf8_lossy(&responses);
    assert!(
        resp_str.contains("\x1b[5;10R"),
        "CPR response must be present: {resp_str:?}"
    );
    assert!(
        resp_str.contains("\x1b[0n"),
        "DSR status response must be present: {resp_str:?}"
    );
    assert!(
        resp_str.contains("\x1b[?62;22c"),
        "Primary DA response must be present: {resp_str:?}"
    );
    assert!(
        resp_str.contains("\x1b]4;1;rgb:ffff/8080/0000"),
        "OSC palette query response must be present: {resp_str:?}"
    );

    // Draining again returns empty
    let empty_responses = unsafe { take_buffer(|o, l| prod_vt_drain_responses(vt, o, l)) }.unwrap();
    assert!(
        empty_responses.is_empty(),
        "second drain must be empty"
    );

    unsafe { prod_vt_free(vt) };
}

#[test]
fn test_checkpoint_export_remains_non_mutating() {
    let vt = unsafe { prod_vt_new(40, 10, 100) };

    let setup = b"\x1b]0;Export Title\x07Hello Checkpoint World!\r\nSecond line.";
    unsafe { write_seq(vt, setup) };

    // Discard any events from setup
    unsafe { prod_vt_discard_events(vt) };

    // Measure checkpoint export
    let mut needed: usize = 0;
    let st = unsafe { prod_vt_checkpoint_export2(vt, 0, std::ptr::null_mut(), 0, &mut needed) };
    assert_eq!(st, -2); // PROD_VT_ERR_BUFFER_TOO_SMALL
    assert!(needed > 20);

    let mut buf1 = vec![0u8; needed];
    let mut written1: usize = 0;
    let st1 = unsafe {
        prod_vt_checkpoint_export2(vt, 0, buf1.as_mut_ptr(), buf1.len(), &mut written1)
    };
    assert_eq!(st1, 0); // PROD_VT_OK
    assert_eq!(written1, needed);

    // Discard events again: non-mutating
    unsafe { prod_vt_discard_events(vt) };

    // Export again: must produce byte-for-byte identical checkpoint!
    let mut buf2 = vec![0u8; needed];
    let mut written2: usize = 0;
    let st2 = unsafe {
        prod_vt_checkpoint_export2(vt, 0, buf2.as_mut_ptr(), buf2.len(), &mut written2)
    };
    assert_eq!(st2, 0); // PROD_VT_OK
    assert_eq!(written2, needed);
    assert_eq!(buf1, buf2, "checkpoint bytes must be identical");

    // Terminal title and viewport text must remain identical
    let title = unsafe { take_buffer(|o, l| prod_vt_title(vt, o, l)) }.unwrap();
    assert_eq!(String::from_utf8(title).unwrap(), "Export Title");

    let text = unsafe { take_buffer(|o, l| prod_vt_viewport_text(vt, o, l)) }.unwrap();
    assert!(String::from_utf8_lossy(&text).contains("Hello Checkpoint World!"));

    // Import into a target terminal
    let target_vt = unsafe { prod_vt_new(80, 24, 100) };
    let imp_st = unsafe { prod_vt_checkpoint_import2(target_vt, buf1.as_ptr(), buf1.len()) };
    assert_eq!(imp_st, 0); // PROD_VT_OK

    let imp_title = unsafe { take_buffer(|o, l| prod_vt_title(target_vt, o, l)) }.unwrap();
    assert_eq!(String::from_utf8(imp_title).unwrap(), "Export Title");

    // Discard events on imported terminal is safe
    unsafe { prod_vt_discard_events(target_vt) };

    unsafe {
        prod_vt_free(vt);
        prod_vt_free(target_vt);
    }
}
