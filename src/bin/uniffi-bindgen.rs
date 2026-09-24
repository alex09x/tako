// Helper binary that drives UniFFI's bindings generator (`uniffi generate ...`)
// against the compiled `tako_core` cdylib. Only built with the
// `uniffi-cli` feature enabled (see Cargo.toml / scripts/build-xcframework.sh).

fn main() {
    uniffi::uniffi_bindgen_main();
}
