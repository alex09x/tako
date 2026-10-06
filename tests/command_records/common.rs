/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

#[allow(unused_imports)]
pub(crate) use tako_core::ffi::TakoCore;
#[allow(unused_imports)]
pub(crate) use tako_core::grid::{RowOwner, SearchHit, SemanticPrompt};
#[allow(unused_imports)]
pub(crate) use tako_core::terminal::commands::{
    CommandStatus, MAX_COMMAND_RECORDS, MAX_INPUT_CHARS,
};
#[allow(unused_imports)]
pub(crate) use tako_core::terminal::{CommandMarkStatus, Terminal, TerminalEvent};

pub(crate) const A: &[u8] = b"\x1b]133;A\x07";
pub(crate) const B: &[u8] = b"\x1b]133;B\x07";
pub(crate) const C: &[u8] = b"\x1b]133;C\x07";

pub(crate) fn d(code: i32) -> Vec<u8> {
    format!("\x1b]133;D;{code}\x07").into_bytes()
}

pub(crate) fn run(t: &mut Terminal, line: &str, output: &str, code: Option<i32>) {
    t.feed(A);
    t.feed(b"$ ");
    t.feed(B);
    t.feed(line.as_bytes());
    t.feed(b"\r\n");
    t.feed(C);
    t.feed(output.as_bytes());
    match code {
        Some(code) => t.feed(&d(code)),
        None => t.feed(b"\x1b]133;D\x07"),
    }
}

pub(crate) fn hits(t: &Terminal, needle: &str) -> Vec<SearchHit> {
    t.active_grid()
        .search_chunk(needle, None, usize::MAX, usize::MAX)
        .hits
}

pub(crate) fn command_of(t: &Terminal, needle: &str) -> Option<u64> {
    let found = hits(t, needle);
    assert_eq!(found.len(), 1, "{needle}");
    found[0].command
}

pub(crate) fn owners(t: &Terminal) -> Vec<RowOwner> {
    let g = t.active_grid();
    (0..g.rows()).map(|r| g.row_owner(r)).collect()
}

pub(crate) fn core_with_finished_command() -> (TakoCore, u64) {
    let core = TakoCore::new(30, 8);
    core.feed(b"\x1b]133;C\x07output\r\n\x1b]133;D;3\x07".to_vec());
    let id = core
        .take_events()
        .into_iter()
        .find_map(|e| match e {
            tako_core::ffi::FfiEvent::CommandStart { id } => id,
            _ => None,
        })
        .unwrap();
    (core, id)
}
