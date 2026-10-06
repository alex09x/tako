/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

// The published C headers: every exported function is declared, and the
// headers and the C example compile as strict C11.

use std::path::Path;

const ROOT: &str = env!("CARGO_MANIFEST_DIR");

fn exported() -> Vec<String> {
    let capi_dir = Path::new(ROOT).join("src/capi");
    let files: Vec<_> = if capi_dir.is_dir() {
        std::fs::read_dir(capi_dir)
            .unwrap()
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.extension().is_some_and(|ext| ext == "rs"))
            .collect()
    } else {
        vec![Path::new(ROOT).join("src/capi.rs")]
    };
    let mut names = Vec::new();
    for file in files {
        let src = std::fs::read_to_string(file).unwrap();
        for l in src.lines() {
            if let Some(rest) = l.trim().strip_prefix("pub extern \"C\" fn ") {
                names.push(rest.split('(').next().unwrap().trim().to_string());
            }
        }
    }
    names
}

#[test]
fn every_exported_function_is_declared_in_a_header() {
    let headers = ["include/prod_vt.h", "include/prod_vt_checkpoint.h"]
        .map(|h| std::fs::read_to_string(Path::new(ROOT).join(h)).unwrap())
        .join("\n");
    let names = exported();
    assert!(names.len() > 20, "found {names:?}");
    for name in names {
        assert!(
            headers.contains(&format!("{name}(")),
            "{name} is exported but declared in no header"
        );
    }
}

#[test]
fn the_c_example_compiles_against_the_headers() {
    let cc = std::env::var("CC").unwrap_or_else(|_| "cc".to_string());
    let out = std::process::Command::new(&cc)
        .args([
            "-fsyntax-only",
            "-std=c11",
            "-Wall",
            "-Wextra",
            "-Werror",
            "-pedantic",
            "-I",
        ])
        .arg(Path::new(ROOT).join("include"))
        .arg(Path::new(ROOT).join("examples/c/headless.c"))
        .output();
    let out = match out {
        Ok(out) => out,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return,
        Err(e) => panic!("could not run {cc}: {e}"),
    };
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
}
