// The published C headers: every exported function is declared, and the
// headers and the C example compile as strict C11.

use std::path::Path;

const ROOT: &str = env!("CARGO_MANIFEST_DIR");

fn exported() -> Vec<String> {
    let src = std::fs::read_to_string(Path::new(ROOT).join("src/capi.rs")).unwrap();
    src.lines()
        .filter_map(|l| l.trim().strip_prefix("pub extern \"C\" fn "))
        .map(|rest| rest.split('(').next().unwrap().trim().to_string())
        .collect()
}

#[test]
fn every_exported_function_is_declared_in_a_header() {
    let headers = ["include/prod_vt.h", "include/prod_vt_checkpoint.h"]
        .map(|h| std::fs::read_to_string(Path::new(ROOT).join(h)).unwrap())
        .join("\n");
    let names = exported();
    assert!(names.len() > 20, "found {names:?}");
    for name in names {
        assert!(headers.contains(&format!("{name}(")), "{name} is exported but declared in no header");
    }
}

#[test]
fn the_c_example_compiles_against_the_headers() {
    let cc = std::env::var("CC").unwrap_or_else(|_| "cc".to_string());
    let out = std::process::Command::new(&cc)
        .args(["-fsyntax-only", "-std=c11", "-Wall", "-Wextra", "-Werror", "-pedantic", "-I"])
        .arg(Path::new(ROOT).join("include"))
        .arg(Path::new(ROOT).join("examples/c/headless.c"))
        .output();
    let out = match out {
        Ok(out) => out,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return,
        Err(e) => panic!("could not run {cc}: {e}"),
    };
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
}
