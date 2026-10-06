/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::common::*;

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
            tail[name.len()..]
                .starts_with('(')
                .then(|| format!("prod_vt_{name}"))
        })
        .collect();
    names.sort();
    names.dedup();
    names
}

/// Every `prod_vt_*` symbol `capi.rs` exports.
fn exported_declarations() -> Vec<String> {
    let capi_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/capi");
    let files: Vec<_> = if capi_dir.is_dir() {
        std::fs::read_dir(capi_dir)
            .unwrap()
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.extension().is_some_and(|ext| ext == "rs"))
            .collect()
    } else {
        vec![std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/capi.rs")]
    };
    let mut names: Vec<String> = Vec::new();
    for file in files {
        let capi = std::fs::read_to_string(file).expect("capi file");
        for tail in capi.split("pub extern \"C\" fn prod_vt_").skip(1) {
            let name: String = tail
                .chars()
                .take_while(|c| c.is_ascii_alphanumeric() || *c == '_')
                .collect();
            names.push(format!("prod_vt_{name}"));
        }
    }
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

    for (asked, written) in [(0u32, 6u32), (2, 2), (3, 3), (4, 4), (5, 5), (6, 6)] {
        let mut needed = 0usize;
        assert_eq!(
            unsafe { prod_vt_checkpoint_measure3(vt, asked, 0, &mut needed) },
            PROD_VT_OK
        );
        let mut buf = vec![0u8; needed];
        let mut got = 0usize;
        assert_eq!(
            unsafe {
                prod_vt_checkpoint_export3(vt, asked, 0, buf.as_mut_ptr(), buf.len(), &mut got)
            },
            PROD_VT_OK
        );
        assert_eq!(got, needed);
        assert_eq!(u32::from_le_bytes(buf[4..8].try_into().unwrap()), written);
        assert_eq!(
            unsafe { prod_vt_checkpoint_import2(vt, buf.as_ptr(), got) },
            PROD_VT_OK
        );
    }

    for asked in [1u32, 7] {
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
