//! The checkpoint C ABI, exercised through the symbols a C consumer links.
//!
//! Every function here is declared in an `extern "C"` block and resolved by
//! symbol name, exactly as CodeHaus's cgo does -- not called as a Rust path.
//! A signature that drifts, a symbol that gets renamed, or a status constant
//! that changes value fails this file rather than the consumer's build.
//!
//! What it pins:
//!
//! * the ABI version a consumer negotiates against;
//! * `0` for success and a *typed* negative status for each distinct refusal,
//!   so "renegotiate the version" is distinguishable from "the bytes are
//!   corrupt" and from "your buffer was too small";
//! * deterministic out-parameters on every path, success and failure alike;
//! * the required-size diagnostic that makes the two-call idiom exact;
//! * fail-intact import;
//! * and that the legacy boolean symbols still exist, still return 1/0, and
//!   now also leave their out-parameters in a defined state.

use std::os::raw::{c_char, c_int, c_void};

#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct ProdVtCheckpointInfo {
    version: u32,
    flags: u32,
    cols: u32,
    rows: u32,
    payload_len: u32,
}

const ZERO_INFO: ProdVtCheckpointInfo = ProdVtCheckpointInfo {
    version: 0,
    flags: 0,
    cols: 0,
    rows: 0,
    payload_len: 0,
};

// Status codes, spelled out rather than imported: a test that re-used the
// crate's constants would still pass if their values changed, and their values
// are the ABI.
const PROD_VT_OK: c_int = 0;
const PROD_VT_ERR_NULL_ARGUMENT: c_int = -1;
const PROD_VT_ERR_BUFFER_TOO_SMALL: c_int = -2;
const PROD_VT_ERR_UNEXPECTED_EOF: c_int = -3;
const PROD_VT_ERR_INVALID_MAGIC: c_int = -4;
const PROD_VT_ERR_UNSUPPORTED_VERSION: c_int = -5;
const PROD_VT_ERR_CHECKSUM_MISMATCH: c_int = -6;
const PROD_VT_ERR_INVALID_PAYLOAD_LENGTH: c_int = -7;
const PROD_VT_ERR_TOO_LARGE: c_int = -11;

unsafe extern "C" {
    fn prod_vt_new(cols: u16, rows: u16, max_scrollback: usize) -> *mut c_void;
    fn prod_vt_free(vt: *mut c_void);
    fn prod_vt_write(vt: *mut c_void, data: *const u8, len: usize);
    fn prod_vt_buffer_free(data: *mut u8);

    fn prod_vt_checkpoint_abi_version() -> u32;
    fn prod_vt_checkpoint_status_message(status: c_int) -> *const c_char;
    fn prod_vt_checkpoint_export2(
        vt: *mut c_void,
        max_bytes: u64,
        buf: *mut u8,
        cap: usize,
        out_len: *mut usize,
    ) -> c_int;
    fn prod_vt_checkpoint_export3(
        vt: *mut c_void,
        version: u32,
        max_bytes: u64,
        buf: *mut u8,
        cap: usize,
        out_len: *mut usize,
    ) -> c_int;
    fn prod_vt_checkpoint_measure3(
        vt: *mut c_void,
        version: u32,
        max_bytes: u64,
        out_len: *mut usize,
    ) -> c_int;
    fn prod_vt_checkpoint_import2(vt: *mut c_void, data: *const u8, len: usize) -> c_int;
    fn prod_vt_checkpoint_inspect2(
        data: *const u8,
        len: usize,
        out: *mut ProdVtCheckpointInfo,
    ) -> c_int;
    fn prod_vt_checkpoint_verify2(data: *const u8, len: usize) -> c_int;

    // The original surface, still exported and still boolean.
    fn prod_vt_checkpoint(vt: *mut c_void, out: *mut *mut u8, out_len: *mut usize) -> c_int;
    fn prod_vt_checkpoint_export(vt: *mut c_void, out: *mut *mut u8, out_len: *mut usize) -> c_int;
    fn prod_vt_checkpoint_export_limited(
        vt: *mut c_void,
        max_bytes: u64,
        out: *mut *mut u8,
        out_len: *mut usize,
    ) -> c_int;
    fn prod_vt_restore(vt: *mut c_void, data: *const u8, len: usize) -> c_int;
    fn prod_vt_checkpoint_import(vt: *mut c_void, data: *const u8, len: usize) -> c_int;
    fn prod_vt_checkpoint_verify(data: *const u8, len: usize) -> c_int;
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
}

/// Pull the exported objects into this test binary's link.
///
/// A `#[no_mangle]` function is exported unconditionally from the staticlib
/// and cdylib a C consumer links, but an integration test links the *rlib*,
/// and the linker drops any object file no Rust path references -- so the
/// `extern "C"` block above would fail to resolve symbols that are perfectly
/// present in the artifact CodeHaus consumes. Taking each address by its Rust
/// path is what keeps the objects; every call below still goes through the
/// extern declarations, by symbol name.
fn exported_symbol_addresses() -> Vec<*const ()> {
    use tako_core::capi as c;
    vec![
        c::prod_vt_new as *const (),
        c::prod_vt_free as *const (),
        c::prod_vt_write as *const (),
        c::prod_vt_buffer_free as *const (),
        c::prod_vt_checkpoint_abi_version as *const (),
        c::prod_vt_checkpoint_status_message as *const (),
        c::prod_vt_checkpoint_export2 as *const (),
        c::prod_vt_checkpoint_export3 as *const (),
        c::prod_vt_checkpoint_measure3 as *const (),
        c::prod_vt_checkpoint_import2 as *const (),
        c::prod_vt_checkpoint_inspect2 as *const (),
        c::prod_vt_checkpoint_verify2 as *const (),
        c::prod_vt_checkpoint as *const (),
        c::prod_vt_checkpoint_export as *const (),
        c::prod_vt_checkpoint_export_limited as *const (),
        c::prod_vt_restore as *const (),
        c::prod_vt_checkpoint_import as *const (),
        c::prod_vt_checkpoint_verify as *const (),
        c::prod_vt_checkpoint_version as *const (),
        c::prod_vt_checkpoint_supports as *const (),
        c::prod_vt_checkpoint_inspect as *const (),
    ]
}

#[test]
fn every_symbol_the_consumer_links_is_present() {
    let addrs = exported_symbol_addresses();
    assert_eq!(addrs.len(), 21);
    assert!(addrs.iter().all(|p| !p.is_null()));
}

/// A terminal with a little state in it, through the C entry points.
fn vt_with(text: &[u8]) -> *mut c_void {
    let vt = unsafe { prod_vt_new(40, 10, 200) };
    assert!(!vt.is_null());
    unsafe { prod_vt_write(vt, text.as_ptr(), text.len()) };
    vt
}

/// The two-call idiom, as a C caller would write it.
fn export_via_abi(vt: *mut c_void, max_bytes: u64) -> Vec<u8> {
    let mut needed: usize = 0;
    let sized =
        unsafe { prod_vt_checkpoint_export2(vt, max_bytes, std::ptr::null_mut(), 0, &mut needed) };
    assert_eq!(sized, PROD_VT_ERR_BUFFER_TOO_SMALL);
    assert!(needed > 0);

    let mut buf = vec![0u8; needed];
    let mut written: usize = 0;
    let code =
        unsafe { prod_vt_checkpoint_export2(vt, max_bytes, buf.as_mut_ptr(), buf.len(), &mut written) };
    assert_eq!(code, PROD_VT_OK, "{}", status_text(code));
    assert_eq!(written, needed, "the sizing call and the writing call agree");
    buf.truncate(written);
    buf
}

fn status_text(status: c_int) -> String {
    let p = unsafe { prod_vt_checkpoint_status_message(status) };
    assert!(!p.is_null(), "a status message is never NULL");
    unsafe { std::ffi::CStr::from_ptr(p) }
        .to_string_lossy()
        .into_owned()
}

// ---------------------------------------------------------------------------
// Negotiation
// ---------------------------------------------------------------------------

#[test]
fn abi_version_is_queryable_and_pinned() {
    assert_eq!(unsafe { prod_vt_checkpoint_abi_version() }, 2);
}

#[test]
fn every_status_has_a_message_and_none_is_null() {
    // Including a code this build has never heard of: a consumer logs the
    // status it got, whatever it got.
    for status in [
        PROD_VT_OK,
        PROD_VT_ERR_NULL_ARGUMENT,
        PROD_VT_ERR_BUFFER_TOO_SMALL,
        PROD_VT_ERR_UNEXPECTED_EOF,
        PROD_VT_ERR_INVALID_MAGIC,
        PROD_VT_ERR_UNSUPPORTED_VERSION,
        PROD_VT_ERR_CHECKSUM_MISMATCH,
        PROD_VT_ERR_INVALID_PAYLOAD_LENGTH,
        PROD_VT_ERR_TOO_LARGE,
        -9999,
    ] {
        assert!(!status_text(status).is_empty());
    }
    assert_eq!(status_text(PROD_VT_OK), "ok");
    assert_eq!(status_text(-9999), "unknown checkpoint status");
}

// ---------------------------------------------------------------------------
// Export: required-size diagnostics and deterministic outputs
// ---------------------------------------------------------------------------

#[test]
fn export_sizes_then_writes_exactly() {
    let vt = vt_with(b"sized export");
    let blob = export_via_abi(vt, 0);
    assert_eq!(&blob[..4], b"TKCK");

    // A buffer one byte short is refused, reports the real size, and writes
    // nothing -- the sentinel survives.
    let mut short = vec![0xABu8; blob.len() - 1];
    let mut needed: usize = 0;
    let code = unsafe {
        prod_vt_checkpoint_export2(vt, 0, short.as_mut_ptr(), short.len(), &mut needed)
    };
    assert_eq!(code, PROD_VT_ERR_BUFFER_TOO_SMALL);
    assert_eq!(needed, blob.len());
    assert!(short.iter().all(|&b| b == 0xAB), "nothing was written");

    unsafe { prod_vt_free(vt) };
}

#[test]
fn export_reports_zero_length_on_every_non_sizing_failure() {
    let vt = vt_with(b"deterministic outputs");

    // A caller cap the state cannot fit is a refusal, not a sizing hint: the
    // container is over the *declared limit*, so there is no size to report.
    let mut len: usize = 12345;
    let code = unsafe { prod_vt_checkpoint_export2(vt, 8, std::ptr::null_mut(), 0, &mut len) };
    assert_eq!(code, PROD_VT_ERR_TOO_LARGE, "{}", status_text(code));
    assert_eq!(len, 0, "the stale 12345 was overwritten");

    // A NULL handle likewise: status first, and the out-parameter defined.
    let mut len2: usize = 999;
    let code = unsafe {
        prod_vt_checkpoint_export2(std::ptr::null_mut(), 0, std::ptr::null_mut(), 0, &mut len2)
    };
    assert_eq!(code, PROD_VT_ERR_NULL_ARGUMENT);
    assert_eq!(len2, 0);

    // A NULL out_len is the one thing that cannot be made deterministic, so it
    // is rejected before anything else happens.
    let code = unsafe {
        prod_vt_checkpoint_export2(vt, 0, std::ptr::null_mut(), 0, std::ptr::null_mut())
    };
    assert_eq!(code, PROD_VT_ERR_NULL_ARGUMENT);

    // A NULL buffer with a non-zero capacity is a caller bug, not a size query.
    let mut len3: usize = 777;
    let code = unsafe { prod_vt_checkpoint_export2(vt, 0, std::ptr::null_mut(), 64, &mut len3) };
    assert_eq!(code, PROD_VT_ERR_NULL_ARGUMENT);
    assert_eq!(len3, 0);

    unsafe { prod_vt_free(vt) };
}

// ---------------------------------------------------------------------------
// Import: typed refusals, and fail-intact
// ---------------------------------------------------------------------------

#[test]
fn import_reports_which_refusal_it_is() {
    let vt = vt_with(b"source state");
    let good = export_via_abi(vt, 0);

    let dest = unsafe { prod_vt_new(40, 10, 200) };
    let cases: Vec<(c_int, Vec<u8>)> = vec![
        (PROD_VT_ERR_NULL_ARGUMENT, Vec::new()),
        (PROD_VT_ERR_UNEXPECTED_EOF, good[..8].to_vec()),
        (PROD_VT_ERR_INVALID_MAGIC, {
            let mut b = good.clone();
            b[0] ^= 0xFF;
            b
        }),
        (PROD_VT_ERR_UNSUPPORTED_VERSION, {
            let mut b = good.clone();
            // Header layout: magic(4) | version(4) | flags(4) | len(4) | crc(4).
            b[4..8].copy_from_slice(&0xFFFF_FFFFu32.to_le_bytes());
            b
        }),
        (PROD_VT_ERR_INVALID_PAYLOAD_LENGTH, {
            let mut b = good.clone();
            b.pop();
            b
        }),
        (PROD_VT_ERR_CHECKSUM_MISMATCH, {
            let mut b = good.clone();
            let last = b.len() - 1;
            b[last] ^= 0xFF;
            b
        }),
    ];

    for (expected, blob) in cases {
        let code = unsafe { prod_vt_checkpoint_import2(dest, blob.as_ptr(), blob.len()) };
        assert_eq!(
            code,
            expected,
            "expected {}, got {}",
            status_text(expected),
            status_text(code)
        );
    }

    // Nothing above landed: the destination is still exactly what it was.
    let untouched = export_via_abi(dest, 0);
    let fresh = unsafe { prod_vt_new(40, 10, 200) };
    assert_eq!(untouched, export_via_abi(fresh, 0), "fail-intact");
    unsafe { prod_vt_free(fresh) };

    // And the good one still imports.
    let code = unsafe { prod_vt_checkpoint_import2(dest, good.as_ptr(), good.len()) };
    assert_eq!(code, PROD_VT_OK, "{}", status_text(code));
    assert_eq!(export_via_abi(dest, 0), good, "the round trip is byte-exact");

    unsafe { prod_vt_free(dest) };
    unsafe { prod_vt_free(vt) };
}

// ---------------------------------------------------------------------------
// Inspect and verify
// ---------------------------------------------------------------------------

#[test]
fn inspect_fills_on_success_and_zeroes_on_failure() {
    let vt = vt_with(b"inspect me");
    let good = export_via_abi(vt, 0);

    let mut info = ZERO_INFO;
    let code = unsafe { prod_vt_checkpoint_inspect2(good.as_ptr(), good.len(), &mut info) };
    assert_eq!(code, PROD_VT_OK, "{}", status_text(code));
    assert_eq!(info.version, unsafe { prod_vt_checkpoint_version() });
    assert_eq!((info.cols, info.rows), (40, 10));
    assert_eq!(info.payload_len as usize, good.len() - 20);

    // A second call over a corrupt buffer must not leave the previous answer
    // sitting in the caller's struct.
    let mut bad = good.clone();
    bad[0] ^= 0xFF;
    let code = unsafe { prod_vt_checkpoint_inspect2(bad.as_ptr(), bad.len(), &mut info) };
    assert_eq!(code, PROD_VT_ERR_INVALID_MAGIC);
    assert_eq!(info, ZERO_INFO, "the 40x10 answer did not survive");

    let code = unsafe { prod_vt_checkpoint_inspect2(good.as_ptr(), good.len(), std::ptr::null_mut()) };
    assert_eq!(code, PROD_VT_ERR_NULL_ARGUMENT);

    unsafe { prod_vt_free(vt) };
}

#[test]
fn verify_reports_the_reason() {
    let vt = vt_with(b"verify me");
    let good = export_via_abi(vt, 0);

    assert_eq!(unsafe { prod_vt_checkpoint_verify2(good.as_ptr(), good.len()) }, PROD_VT_OK);
    assert_eq!(
        unsafe { prod_vt_checkpoint_verify2(std::ptr::null(), 0) },
        PROD_VT_ERR_NULL_ARGUMENT
    );

    let mut bad = good.clone();
    bad[1] ^= 0xFF;
    assert_eq!(
        unsafe { prod_vt_checkpoint_verify2(bad.as_ptr(), bad.len()) },
        PROD_VT_ERR_INVALID_MAGIC
    );

    unsafe { prod_vt_free(vt) };
}

// ---------------------------------------------------------------------------
// The legacy surface is preserved, and no longer leaves stale outputs
// ---------------------------------------------------------------------------

#[test]
fn legacy_boolean_symbols_still_mean_one_and_zero() {
    let vt = vt_with(b"legacy caller");

    let mut ptr: *mut u8 = std::ptr::null_mut();
    let mut len: usize = 0;
    assert_eq!(unsafe { prod_vt_checkpoint(vt, &mut ptr, &mut len) }, 1);
    assert!(!ptr.is_null() && len > 0);
    let blob = unsafe { std::slice::from_raw_parts(ptr, len) }.to_vec();
    unsafe { prod_vt_buffer_free(ptr) };

    // The alias and the limited form agree with it.
    let mut ptr2: *mut u8 = std::ptr::null_mut();
    let mut len2: usize = 0;
    assert_eq!(unsafe { prod_vt_checkpoint_export(vt, &mut ptr2, &mut len2) }, 1);
    assert_eq!(unsafe { std::slice::from_raw_parts(ptr2, len2) }, &blob[..]);
    unsafe { prod_vt_buffer_free(ptr2) };

    let dest = unsafe { prod_vt_new(40, 10, 200) };
    assert_eq!(unsafe { prod_vt_restore(dest, blob.as_ptr(), blob.len()) }, 1);
    assert_eq!(unsafe { prod_vt_checkpoint_import(dest, blob.as_ptr(), blob.len()) }, 1);
    assert_eq!(unsafe { prod_vt_restore(dest, std::ptr::null(), 0) }, 0);
    assert_eq!(unsafe { prod_vt_checkpoint_verify(blob.as_ptr(), blob.len()) }, 1);
    assert_eq!(unsafe { prod_vt_checkpoint_verify(std::ptr::null(), 0) }, 0);
    assert_eq!(unsafe { prod_vt_checkpoint_supports(prod_vt_checkpoint_version()) }, 1);
    assert_eq!(unsafe { prod_vt_checkpoint_supports(0) }, 0);

    unsafe { prod_vt_free(dest) };
    unsafe { prod_vt_free(vt) };
}

#[test]
fn legacy_failure_leaves_defined_outputs_not_the_callers_stale_ones() {
    // This is the shape the backend's probe hit: a boolean 0 with the caller's
    // previous `out`/`out_len` still in place, which reads as a 123-byte
    // buffer that was never produced.
    let stale = 123usize;
    let sentinel = 0xDEAD_BEEFusize as *mut u8;

    let mut ptr = sentinel;
    let mut len = stale;
    assert_eq!(
        unsafe { prod_vt_checkpoint(std::ptr::null_mut(), &mut ptr, &mut len) },
        0
    );
    assert!(ptr.is_null(), "out was cleared");
    assert_eq!(len, 0, "out_len was cleared");

    let mut ptr = sentinel;
    let mut len = stale;
    assert_eq!(
        unsafe {
            prod_vt_checkpoint_export_limited(std::ptr::null_mut(), 0, &mut ptr, &mut len)
        },
        0
    );
    assert!(ptr.is_null());
    assert_eq!(len, 0);

    // A caller-supplied cap the state cannot fit is the other failure path.
    let vt = vt_with(b"too small a cap");
    let mut ptr = sentinel;
    let mut len = stale;
    assert_eq!(
        unsafe { prod_vt_checkpoint_export_limited(vt, 8, &mut ptr, &mut len) },
        0
    );
    assert!(ptr.is_null());
    assert_eq!(len, 0);
    unsafe { prod_vt_free(vt) };

    // And the five-out-parameter inspect.
    let (mut v, mut c, mut r, mut p) = (7u32, 7u32, 7u32, 7u32);
    assert_eq!(
        unsafe { prod_vt_checkpoint_inspect(b"nope".as_ptr(), 4, &mut v, &mut c, &mut r, &mut p) },
        0
    );
    assert_eq!((v, c, r, p), (0, 0, 0, 0));
}

// ---------------------------------------------------------------------------
// The published header must describe this library, not a past version of it
// ---------------------------------------------------------------------------

/// Every `prod_vt_*` function the header declares.
fn header_declarations() -> Vec<String> {
    let header = std::fs::read_to_string(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/include/prod_vt_checkpoint.h"
    ))
    .expect("include/prod_vt_checkpoint.h is part of the deliverable");

    let mut names: Vec<String> = header
        .split("prod_vt_")
        .skip(1)
        .filter_map(|tail| {
            let name: String = tail
                .chars()
                .take_while(|c| c.is_ascii_alphanumeric() || *c == '_')
                .collect();
            // A declaration, not a mention in prose: the identifier is
            // immediately followed by its parameter list.
            tail[name.len()..].starts_with('(').then(|| format!("prod_vt_{name}"))
        })
        .collect();
    names.sort();
    names.dedup();
    names
}

/// Every `prod_vt_*` symbol `capi.rs` exports.
fn exported_declarations() -> Vec<String> {
    let capi = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/src/capi.rs"))
        .expect("src/capi.rs");
    let mut names: Vec<String> = capi
        .split("pub extern \"C\" fn prod_vt_")
        .skip(1)
        .map(|tail| {
            let name: String = tail
                .chars()
                .take_while(|c| c.is_ascii_alphanumeric() || *c == '_')
                .collect();
            format!("prod_vt_{name}")
        })
        .collect();
    names.sort();
    names.dedup();
    names
}

#[test]
fn the_header_declares_exactly_the_checkpoint_symbols_that_exist() {
    let declared = header_declarations();
    let exported = exported_declarations();

    // Nothing may be declared that is not exported: that is the failure a
    // consumer only discovers at link time, in their build, not ours.
    for name in &declared {
        assert!(
            exported.contains(name),
            "{name} is declared in include/prod_vt_checkpoint.h but not exported by src/capi.rs"
        );
    }

    // And every checkpoint symbol that exists must be declared: a new one that
    // never reaches the header is a surface the consumer cannot reach.
    for name in exported.iter().filter(|n| n.contains("checkpoint")) {
        assert!(
            declared.contains(name),
            "{name} is exported but missing from include/prod_vt_checkpoint.h"
        );
    }

    // The handle-lifetime and event functions the examples use are the deliberate
    // non-checkpoint entries; prod_vt_new/free live in the consumer's own
    // existing header.
    assert!(declared.contains(&"prod_vt_buffer_free".to_string()));
    assert!(declared.contains(&"prod_vt_discard_events".to_string()));
}

#[test]
fn the_header_compiles_as_c() {
    // A header nobody compiles is a header that drifts. `-Werror` with the
    // pedantic set is what catches a stray comma or a type only C++ accepts.
    let cc = std::env::var("CC").unwrap_or_else(|_| "cc".to_string());
    let probe = std::env::temp_dir().join("tako_prod_vt_checkpoint_header_probe.c");
    std::fs::write(
        &probe,
        concat!(
            "#include \"prod_vt_checkpoint.h\"\n",
            "int main(void) {\n",
            "    ProdVtCheckpointInfo info = {0, 0, 0, 0, 0};\n",
            "    (void)info;\n",
            "    return (int)prod_vt_checkpoint_abi_version() == 2 ? 0 : 1;\n",
            "}\n"
        ),
    )
    .unwrap();

    let out = std::process::Command::new(&cc)
        .args([
            "-fsyntax-only",
            "-std=c11",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-I",
            concat!(env!("CARGO_MANIFEST_DIR"), "/include"),
        ])
        .arg(&probe)
        .output();

    let out = match out {
        Ok(out) => out,
        // No C compiler on this machine is not a defect in the header.
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return,
        Err(e) => panic!("could not run {cc}: {e}"),
    };
    assert!(
        out.status.success(),
        "the published header does not compile as C11:\n{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let _ = std::fs::remove_file(&probe);
}

/// A host writes the newest container its peer reads: export3 and measure3
/// take the version, 0 meaning the current one.
#[test]
fn export3_writes_the_version_asked_for() {
    let vt = unsafe { prod_vt_new(20, 4, 100) };
    let text = b"versioned";
    unsafe { prod_vt_write(vt, text.as_ptr(), text.len()) };

    for (asked, written) in [(0u32, 3u32), (2, 2), (3, 3)] {
        let mut needed = 0usize;
        assert_eq!(
            unsafe { prod_vt_checkpoint_measure3(vt, asked, 0, &mut needed) },
            PROD_VT_OK
        );
        let mut buf = vec![0u8; needed];
        let mut got = 0usize;
        assert_eq!(
            unsafe { prod_vt_checkpoint_export3(vt, asked, 0, buf.as_mut_ptr(), buf.len(), &mut got) },
            PROD_VT_OK
        );
        assert_eq!(got, needed);
        assert_eq!(u32::from_le_bytes(buf[4..8].try_into().unwrap()), written);
        assert_eq!(unsafe { prod_vt_checkpoint_import2(vt, buf.as_ptr(), got) }, PROD_VT_OK);
    }

    for asked in [1u32, 4] {
        let mut len = 99usize;
        assert_eq!(
            unsafe { prod_vt_checkpoint_export3(vt, asked, 0, std::ptr::null_mut(), 0, &mut len) },
            PROD_VT_ERR_UNSUPPORTED_VERSION
        );
        assert_eq!(len, 0);
        let mut len = 99usize;
        assert_eq!(
            unsafe { prod_vt_checkpoint_measure3(vt, asked, 0, &mut len) },
            PROD_VT_ERR_UNSUPPORTED_VERSION
        );
        assert_eq!(len, 0);
    }
    unsafe { prod_vt_free(vt) };
}
