//! The checkpoint size query must measure, not serialize.
//!
//! Prod sizes a buffer before it asks for the blob. If the size query builds
//! the whole checkpoint and throws it away, that costs a full serialization
//! and a full allocation of a near-cap container for a number -- and then the
//! real call does it again, alongside the caller's buffer. The agreed shape is
//! a counting measurement whose cost does not scale with the payload.
//!
//! The counter this file installs is thread-local, so the tests here do not
//! see each other's allocations even when the harness runs them in parallel.
//! Nothing outside a `bytes_allocated_by` body is counted at all.

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;
use std::os::raw::{c_int, c_void};

thread_local! {
    /// Bytes requested on this thread since the last reset. `const` init, so
    /// touching it from inside the allocator cannot itself allocate.
    static ALLOCATED: Cell<u64> = const { Cell::new(0) };
    /// Bytes still held: every `alloc` adds, every `dealloc` subtracts, and a
    /// `realloc` moves it by the difference. `ALLOCATED` answers "how much did
    /// this cost"; this answers "how much is this still holding".
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
static ALLOC: Counting = Counting;

/// Run `body` with this thread's allocation counter armed, and report the
/// bytes it asked the allocator for.
fn bytes_allocated_by<T>(body: impl FnOnce() -> T) -> (T, u64) {
    arm_counter();
    let out = body();
    disarm_counter();
    (out, ALLOCATED.with(|n| n.get()))
}

/// Start counting on this thread, from zero.
fn arm_counter() {
    ALLOCATED.with(|n| n.set(0));
    LIVE.with(|n| n.set(0));
    COUNTING.with(|on| on.set(true));
}

fn disarm_counter() {
    COUNTING.with(|on| on.set(false));
}

/// Bytes still held by allocations made since [`arm_counter`].
///
/// Only allocations made inside the armed window are tracked, so a window has
/// to own what it frees -- every caller here builds its fixture after arming.
fn live_bytes() -> i64 {
    LIVE.with(|n| n.get())
}

const PROD_VT_OK: c_int = 0;
const PROD_VT_ERR_BUFFER_TOO_SMALL: c_int = -2;

unsafe extern "C" {
    fn prod_vt_new(cols: u16, rows: u16, max_scrollback: usize) -> *mut c_void;
    fn prod_vt_free(vt: *mut c_void);
    fn prod_vt_write(vt: *mut c_void, data: *const u8, len: usize);
    fn prod_vt_checkpoint_export2(
        vt: *mut c_void,
        max_bytes: u64,
        buf: *mut u8,
        cap: usize,
        out_len: *mut usize,
    ) -> c_int;
    fn prod_vt_checkpoint_measure2(vt: *mut c_void, max_bytes: u64, out_len: *mut usize) -> c_int;
    fn prod_vt_checkpoint_import2(vt: *mut c_void, data: *const u8, len: usize) -> c_int;
}

/// Keep the exported objects in this test binary's link (an integration test
/// links the rlib, and the linker drops object files nothing references).
fn keep_symbols() -> Vec<*const ()> {
    use tako_core::capi as c;
    vec![
        c::prod_vt_new as *const (),
        c::prod_vt_free as *const (),
        c::prod_vt_write as *const (),
        c::prod_vt_checkpoint_export2 as *const (),
        c::prod_vt_checkpoint_measure2 as *const (),
        c::prod_vt_checkpoint_import2 as *const (),
    ]
}

/// A terminal holding `lines` rows of distinct, incompressible text -- so the
/// payload is genuinely large rather than a run the encoder collapses to
/// nothing.
fn filled_terminal(lines: u32) -> *mut c_void {
    let vt = unsafe { prod_vt_new(120, 40, 20_000) };
    assert!(!vt.is_null());
    let mut text = Vec::new();
    for line in 0..lines {
        for col in 0..110u32 {
            text.push(b'a' + ((line.wrapping_mul(31).wrapping_add(col.wrapping_mul(7))) % 26) as u8);
        }
        text.extend_from_slice(b"\r\n");
    }
    unsafe { prod_vt_write(vt, text.as_ptr(), text.len()) };
    vt
}

/// Size a terminal through the NULL/0 half of the two-call idiom, reporting
/// the size, the status and what the query cost.
fn size_query(vt: *mut c_void) -> (c_int, usize, u64) {
    let mut size: usize = 0;
    let (status, cost) = bytes_allocated_by(|| unsafe {
        prod_vt_checkpoint_export2(vt, 0, std::ptr::null_mut(), 0, &mut size)
    });
    (status, size, cost)
}

#[test]
fn test_size_query_does_not_materialize_the_checkpoint() {
    assert_eq!(keep_symbols().len(), 6);

    let vt = filled_terminal(8_000);

    // What the size query reports, and what it cost.
    let (status, size, query_cost) = size_query(vt);
    // The two-call idiom: NULL/0 reports the required size and says the
    // buffer was too small, which is the documented way to ask.
    assert_eq!(
        status, PROD_VT_ERR_BUFFER_TOO_SMALL,
        "sizing with NULL/0 must report the required size"
    );
    assert!(
        size > 1 << 20,
        "this test is only meaningful on a large checkpoint; got {size} bytes"
    );

    // The number must be exact: the caller allocates exactly this and the
    // second call must fit in it.
    let mut buf = vec![0u8; size];
    let mut written: usize = 0;
    let status =
        unsafe { prod_vt_checkpoint_export2(vt, 0, buf.as_mut_ptr(), buf.len(), &mut written) };
    assert_eq!(status, PROD_VT_OK);
    assert_eq!(written, size, "the size query and the export disagreed");

    // The dedicated measurement entry point is the same number, plainly said.
    let mut measured: usize = 0;
    let status = unsafe { prod_vt_checkpoint_measure2(vt, 0, &mut measured) };
    assert_eq!(status, PROD_VT_OK);
    assert_eq!(measured, size, "measure2 and export2 disagreed on the size");

    unsafe { prod_vt_free(vt) };

    // The measurement's cost must not scale with the payload. A counting
    // measurement needs working space, not a copy of the container.
    assert!(
        query_cost < 128 * 1024,
        "the size query allocated {query_cost} bytes to measure a {size}-byte \
         checkpoint -- it serialized the whole thing and threw it away"
    );

    // "Does not scale" is a claim about two points, not one: an eighth of the
    // content must not cost meaningfully less to measure. A serializing query
    // would fall by roughly the same factor the payload does.
    let small = filled_terminal(1_000);
    let (small_status, small_size, small_cost) = size_query(small);
    unsafe { prod_vt_free(small) };
    assert_eq!(small_status, PROD_VT_ERR_BUFFER_TOO_SMALL);
    assert!(
        size > small_size * 4,
        "the two fixtures are not far enough apart: {size} vs {small_size}"
    );
    assert!(
        small_cost * 4 > query_cost,
        "the size query cost tracks the payload: {query_cost} bytes to measure \
         {size} but only {small_cost} to measure {small_size}"
    );
}


/// A terminal parked mid-sequence with `payload` bytes accumulated in the
/// parser's raw buffer. `intro` is the sequence that opens the string -- no
/// terminator is sent, so the parser is still inside it and the bytes are
/// live state a checkpoint has to carry.
fn terminal_in_flight(intro: &[u8], payload: usize) -> *mut c_void {
    let vt = unsafe { prod_vt_new(80, 24, 100) };
    assert!(!vt.is_null());
    unsafe { prod_vt_write(vt, intro.as_ptr(), intro.len()) };
    let body = vec![b'x'; payload];
    unsafe { prod_vt_write(vt, body.as_ptr(), body.len()) };
    vt
}

fn export_exactly(vt: *mut c_void, size: usize) -> Vec<u8> {
    let mut buf = vec![0u8; size];
    let mut written: usize = 0;
    let status =
        unsafe { prod_vt_checkpoint_export2(vt, 0, buf.as_mut_ptr(), buf.len(), &mut written) };
    assert_eq!(status, PROD_VT_OK, "export of a {size}-byte checkpoint failed");
    assert_eq!(written, size, "the size query and the export disagreed");
    buf
}

/// Measuring a terminal parked in the middle of a large OSC or APC must not
/// copy the payload it is parked on.
///
/// The counting sink stopped the *encoder* from materializing the container,
/// and borrowing the grids stopped serialization from cloning the cells -- but
/// the parser's own raw buffer was still copied out through `Parser::snapshot`
/// twice on every measurement, once to price it and once to encode it. An
/// in-flight OSC is bounded by nothing but the host's input, so that put the
/// payload straight back into the cost of asking for a number.
///
/// This is a checkpoint boundary the container is required to survive, not an
/// edge case: a checkpoint taken while a shell is halfway through writing a
/// long title has to restore into the middle of that same sequence.
#[test]
fn test_measuring_an_in_flight_string_does_not_copy_its_payload() {
    const SMALL: usize = 1 << 20; // 1 MiB
    const LARGE: usize = 8 << 20; // 8 MiB

    // `ESC ] 0 ;` opens an OSC; `ESC _` opens an APC. Both accumulate raw
    // bytes until their terminator, which is never sent here.
    for (label, intro) in [("OSC", &b"\x1b]0;"[..]), ("APC", &b"\x1b_"[..])] {
        let mut costs = Vec::new();
        let mut sizes = Vec::new();

        for payload in [SMALL, LARGE] {
            let vt = terminal_in_flight(intro, payload);

            let mut measured: usize = 0;
            let (status, cost) = bytes_allocated_by(|| unsafe {
                prod_vt_checkpoint_measure2(vt, 0, &mut measured)
            });
            assert_eq!(status, PROD_VT_OK, "{label}: measuring failed");
            assert!(
                measured > payload,
                "{label}: the in-flight payload is not in the checkpoint \
                 ({measured} bytes for a {payload}-byte payload)"
            );

            // Exact agreement with the export, on the same fixture.
            let blob = export_exactly(vt, measured);

            // Continuation is unchanged: the restored terminal is still parked
            // inside the same sequence, holding the same bytes, and finishing
            // it produces the same state.
            let dest = unsafe { prod_vt_new(80, 24, 100) };
            assert!(!dest.is_null());
            let status =
                unsafe { prod_vt_checkpoint_import2(dest, blob.as_ptr(), blob.len()) };
            assert_eq!(status, PROD_VT_OK, "{label}: import of the measured blob failed");

            let terminator = b"\x1b\\PING\r\n";
            unsafe { prod_vt_write(vt, terminator.as_ptr(), terminator.len()) };
            unsafe { prod_vt_write(dest, terminator.as_ptr(), terminator.len()) };

            let mut after_src: usize = 0;
            assert_eq!(
                unsafe { prod_vt_checkpoint_measure2(vt, 0, &mut after_src) },
                PROD_VT_OK
            );
            let mut after_dst: usize = 0;
            assert_eq!(
                unsafe { prod_vt_checkpoint_measure2(dest, 0, &mut after_dst) },
                PROD_VT_OK
            );
            assert_eq!(
                export_exactly(vt, after_src),
                export_exactly(dest, after_dst),
                "{label}: finishing the sequence diverged after a round trip"
            );

            unsafe { prod_vt_free(dest) };
            unsafe { prod_vt_free(vt) };

            costs.push(cost);
            sizes.push(measured);
        }

        // Absolute: the measurement needs working space, not a copy of the
        // payload it is measuring.
        assert!(
            costs[1] < 128 * 1024,
            "{label}: measuring a {}-byte checkpoint allocated {} bytes -- the \
             in-flight payload was copied",
            sizes[1],
            costs[1]
        );
        // Relative: eight times the payload must not cost eight times as much.
        assert!(
            costs[1] < costs[0].saturating_mul(4).max(128 * 1024),
            "{label}: the measurement cost tracks the payload -- {} bytes for \
             {} but {} bytes for {}",
            costs[0],
            sizes[0],
            costs[1],
            sizes[1]
        );
    }
}

/// A queued host event is the destination's memory, and the reservation has to
/// say so.
///
/// Events are deliberately *not* in a checkpoint: they are host-bound side
/// effects, and replaying them on restore would ring the bell twice. But
/// `take_events` is the host's call to make, and until it makes it the
/// terminal owns every payload the byte stream produced -- an OSC 0 title, an
/// OSC 52 clipboard blob, an OSC 9 notification body. All of it is live for
/// the whole of a staged import, on the side of the ledger that is not freed
/// until the assignment.
///
/// Counting `events.capacity() * size_of::<TerminalEvent>()` charges the
/// vector's spine and nothing hanging off it: 24 bytes for a megabyte. This
/// measures the terminal against the allocator rather than against another
/// estimate, and pins the reservation to what the heap actually holds.
#[test]
fn test_retained_cost_counts_the_payloads_of_queued_events() {
    use tako_core::terminal::checkpoint::retained_cost;
    use tako_core::terminal::Terminal;

    const EVENTS: usize = 8;
    const EACH: usize = 1 << 20;
    const PAYLOADS: i64 = (EVENTS * EACH) as i64;

    arm_counter();

    let mut term = Terminal::new(20, 6);
    for _ in 0..EVENTS {
        let mut osc = Vec::with_capacity(EACH + 8);
        osc.extend_from_slice(b"\x1b]0;");
        osc.extend(std::iter::repeat_n(b'x', EACH));
        osc.push(0x07);
        term.feed(&osc);
        // The fixture's own buffer is not the terminal's memory. Dropping it
        // inside the window keeps it out of both numbers below.
        drop(osc);
    }

    let live_before = live_bytes();
    let charged_before = retained_cost(&term) as i64;

    let drained = term.take_events();
    let drained_count = drained.len();
    drop(drained);

    let live_after = live_bytes();
    let charged_after = retained_cost(&term) as i64;

    disarm_counter();

    assert_eq!(
        drained_count, EVENTS,
        "each OSC 0 should have queued exactly one title event"
    );

    // What the events were actually holding, as the allocator saw it.
    let released = live_before - live_after;
    assert!(
        released >= PAYLOADS,
        "the fixture is wrong: draining {EVENTS} x {EACH}-byte events released \
         only {released} bytes"
    );

    // The finding: the reservation has to fall by what was released.
    let charged_drop = charged_before - charged_after;
    assert!(
        charged_drop >= PAYLOADS,
        "draining the events released {released} bytes but the reservation fell \
         by only {charged_drop} -- event payloads are not being charged \
         (before: live={live_before} charged={charged_before}, \
         after: live={live_after} charged={charged_after})"
    );

    // And the reservation as a whole must not be substantially under what the
    // terminal holds, in either state. One percent of slack covers the small
    // allocations `retained_cost` deliberately does not model (the `Terminal`
    // itself, `Vec` headers) without admitting a missing megabyte.
    for (label, live, charged) in [
        ("with the events queued", live_before, charged_before),
        ("after draining them", live_after, charged_after),
    ] {
        assert!(
            charged.saturating_mul(100) >= live.saturating_mul(99),
            "{label}: the terminal holds {live} bytes and the reservation \
             charges {charged}"
        );
    }
}
