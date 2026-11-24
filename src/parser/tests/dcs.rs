/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

//! A device control string reaches the performer as a hook with its
//! parameters and final byte, each data byte put in order, then an unhook.

use super::*;

#[test]
fn a_dcs_is_hooked_put_byte_by_byte_and_unhooked() {
    let p = parse_str("\x1bP1;2|ab\x1b\\");
    assert_eq!(
        p.actions.first(),
        Some(&Action::Hook(vec![1, 2], 0, vec![], false, '|'))
    );
    let puts: Vec<_> = p
        .actions
        .iter()
        .filter_map(|a| match a {
            Action::Put(b) => Some(*b),
            _ => None,
        })
        .collect();
    assert_eq!(puts, b"ab");
    assert!(p.actions.contains(&Action::Unhook));
    assert!(matches!(
        p.actions.last(),
        Some(Action::EscDispatch(_, _, b'\\')) | Some(Action::Unhook)
    ));
}

#[test]
fn a_dcs_keeps_its_intermediates() {
    // DECRQSS: DCS $ q <setting> ST.
    let p = parse_str("\x1bP$qm\x1b\\");
    assert_eq!(
        p.actions.first(),
        Some(&Action::Hook(vec![], 0, vec![b'$'], false, 'q'))
    );
    assert!(p.actions.contains(&Action::Put(b'm')));
    assert!(p.actions.contains(&Action::Unhook));
}

#[test]
fn a_cancelled_dcs_is_unhooked_without_its_rest() {
    let p = parse_str("\x1bPqab\x18cd");
    assert!(p.actions.contains(&Action::Unhook), "CAN ends the string");
    assert!(
        !p.actions.contains(&Action::Put(b'c')),
        "bytes after CAN are not part of it: {:?}",
        p.actions
    );
    assert!(p.actions.contains(&Action::Print('c')));
}
