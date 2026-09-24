#![no_main]
//! The parser must never panic on arbitrary bytes: a terminal reads
//! whatever a program writes, including deliberate garbage.

use libfuzzer_sys::fuzz_target;
use tako_core::terminal::Terminal;
use tako_core_fuzz::assert_safe_readback;

fuzz_target!(|data: &[u8]| {
    let mut term = Terminal::new(80, 24);
    term.feed(data);
    // Exercise all public accessors, inspectors, text extractors, and drains.
    assert_safe_readback(&mut term);
});
