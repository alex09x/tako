//! Cross-cutting panic-safety guarantees for the two FFI surfaces:
//!
//! * `src/capi.rs` -- every `prod_vt_*` extern "C" function routes its body
//!   through a private `guarded` helper so an engine panic returns the
//!   documented failure value instead of unwinding across the C ABI.
//! * `src/ffi/mod.rs` -- `TakoCore`'s internal mutex is locked through a
//!   private `lock_recover` helper that survives poisoning, so one panicking
//!   call cannot make every later call on the same core panic too.
//!
//! `guarded` and `lock_recover` are private, and forcing a real panic inside
//! `TakoCore::inner` needs direct access to that private field, so the
//! panic-injection tests for both live as unit tests next to them
//! (`src/capi.rs`, `src/ffi/mod.rs`). This file instead proves the rewrite
//! did not change anything observable through the surfaces an actual host
//! uses: the raw C ABI and `TakoCore`'s public Rust API.

use std::os::raw::{c_int, c_void};
use std::ptr::null_mut;
use std::sync::Arc;
use std::thread;

use tako_core::ffi::TakoCore;

unsafe extern "C" {
    fn prod_vt_new(cols: u16, rows: u16, max_scrollback: usize) -> *mut c_void;
    fn prod_vt_free(vt: *mut c_void);
    fn prod_vt_write(vt: *mut c_void, data: *const u8, len: usize);
    fn prod_vt_resize(vt: *mut c_void, cols: u16, rows: u16, cell_w: u32, cell_h: u32) -> c_int;
    fn prod_vt_viewport_text(vt: *mut c_void, out: *mut *mut u8, out_len: *mut usize) -> c_int;
    fn prod_vt_buffer_free(data: *mut u8);
    fn prod_vt_checkpoint_version() -> u32;
    fn prod_vt_checkpoint_abi_version() -> u32;
    fn prod_vt_checkpoint_status_message(status: c_int) -> *const std::os::raw::c_char;
}

unsafe fn take_text(vt: *mut c_void) -> String {
    let mut ptr: *mut u8 = null_mut();
    let mut len: usize = 0;
    let ok = unsafe { prod_vt_viewport_text(vt, &mut ptr, &mut len) };
    assert_eq!(ok, 1, "a live handle must still report success");
    let bytes = if ptr.is_null() {
        Vec::new()
    } else {
        unsafe { std::slice::from_raw_parts(ptr, len) }.to_vec()
    };
    unsafe { prod_vt_buffer_free(ptr) };
    String::from_utf8(bytes).unwrap()
}

/// The `guarded` rewrite must not change a single observable byte of
/// ordinary, successful behaviour: write, then read the same text back.
#[test]
fn capi_write_and_read_round_trip_is_unchanged() {
    unsafe {
        let vt = prod_vt_new(24, 3, 100);
        assert!(!vt.is_null());
        let data = b"hello, guarded world";
        prod_vt_write(vt, data.as_ptr(), data.len());
        assert_eq!(take_text(vt), "hello, guarded world");
        prod_vt_free(vt);
    }
}

/// A NULL handle still returns the documented failure value (0 / no-op), not
/// a crash -- the case where the closure never runs at all, so `guarded` must
/// stay exactly as transparent as a bare call was before it existed.
#[test]
fn capi_null_handle_still_returns_documented_failure() {
    unsafe {
        assert_eq!(prod_vt_resize(null_mut(), 10, 10, 0, 0), 0);
        let mut ptr: *mut u8 = null_mut();
        let mut len: usize = 0;
        assert_eq!(prod_vt_viewport_text(null_mut(), &mut ptr, &mut len), 0);
        prod_vt_write(null_mut(), b"x".as_ptr(), 1);
        prod_vt_free(null_mut());
    }
}

/// Getters with no failure path of their own must still behave correctly
/// once wrapped: the happy path through `guarded` is a no-op.
#[test]
fn capi_version_queries_are_unaffected_by_the_guarded_wrapper() {
    unsafe {
        assert_eq!(prod_vt_checkpoint_abi_version(), 2);
        assert!(prod_vt_checkpoint_version() >= 1);
        let msg = prod_vt_checkpoint_status_message(0);
        assert!(!msg.is_null());
        assert_eq!(std::ffi::CStr::from_ptr(msg).to_str().unwrap(), "ok");
    }
}

/// `TakoCore`'s public surface stays fully usable under concurrent access
/// from multiple threads -- the ordinary-contention half of the guarantee
/// `lock_recover` provides. (The other half -- that it also survives an
/// actual poisoning panic -- needs direct access to the private `inner`
/// field and is covered by the unit test in `src/ffi/mod.rs`.)
#[test]
fn takocore_stays_responsive_under_concurrent_access() {
    let core = Arc::new(TakoCore::new(40, 10));
    core.feed(b"seed line".to_vec());

    let mut handles = Vec::new();
    for i in 0..4u8 {
        let core = Arc::clone(&core);
        handles.push(thread::spawn(move || {
            for _ in 0..200 {
                core.feed(format!("\x1b[{};1Hline {i}", (i % 9) + 1).into_bytes());
                let _ = core.render_frame();
                let _ = core.get_line(0);
            }
        }));
    }
    for handle in handles {
        handle.join().expect("no thread should panic under ordinary concurrent use");
    }

    // The core is still fully functional afterward.
    core.feed(b"\x1b[10;1Hfinal".to_vec());
    assert_eq!(core.get_line(9).trim_end_matches(['\0', ' ']), "final");
}
