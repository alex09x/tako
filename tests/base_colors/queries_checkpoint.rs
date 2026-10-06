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

#[test]
fn queries_report_base_until_a_program_changes_them() {
    let mut term = Terminal::new(10, 3);
    term.set_base_colors(Some(BASE_FG), None, None, &[(1, BASE_IDX1)]);

    term.feed(b"\x1b]10;?\x07");
    assert_eq!(
        term.take_output(),
        b"\x1b]10;rgb:0a0a/1414/1e1e\x07".to_vec(),
        "OSC 10 query should report the host base, not stay silent"
    );

    term.feed(b"\x1b]4;1;?\x07");
    assert_eq!(
        term.take_output(),
        b"\x1b]4;1;rgb:6464/6e6e/7878\x1b\\".to_vec(),
        "OSC 4 query should report the base palette entry"
    );

    // Once a program overrides it, the query reports the live value instead.
    term.feed(b"\x1b]10;#ff0000\x07\x1b]10;?\x07");
    assert_eq!(
        term.take_output(),
        b"\x1b]10;rgb:ffff/0000/0000\x07".to_vec()
    );
}

#[test]
fn checkpoint_restore_preserves_program_override_against_later_base_change() {
    // A program's explicit OSC 10 override must survive an
    // export/import round trip, and a host base change issued *after*
    // restore must not silently reach past it.
    let mut term = Terminal::new(10, 3);
    term.set_base_colors(Some(BASE_FG), None, None, &[]);

    let program_fg = (200, 201, 202);
    term.feed(b"\x1b]10;#c8c9ca\x07"); // program override -> (200,201,202)
    assert_eq!(term.default_colors().0, Some(program_fg));

    let checkpoint = term.export_checkpoint().unwrap();
    let mut restored = Terminal::new(10, 3);
    restored.import_checkpoint(&checkpoint).unwrap();

    assert_eq!(
        restored.default_colors().0,
        Some(program_fg),
        "restored terminal must still report the program's override"
    );

    // A host base change after restore must not clobber the restored
    // program override, even though the checkpoint format doesn't carry
    // the pre-checkpoint base configuration.
    let new_base_fg = (11, 22, 33);
    restored.set_base_colors(Some(new_base_fg), None, None, &[]);
    assert_eq!(
        restored.default_colors().0,
        Some(program_fg),
        "post-restore base change must not clobber the program's restored override"
    );
}

#[test]
fn old_behavior_without_a_base_is_unchanged() {
    let mut term = Terminal::new(10, 3);

    // No base ever configured: OSC 10 query on an unset slot stays silent,
    // exactly like before this feature existed.
    term.feed(b"\x1b]10;?\x07");
    assert!(term.take_output().is_empty());

    // OSC 104 with no base configured still restores the engine's built-in
    // defaults.
    term.feed(&osc4_set(1, (1, 1, 1)));
    term.feed(b"\x1b]104\x07");
    assert_eq!(term.palette().get(1), BUILTIN_IDX1);

    // OSC 110 with no base configured goes back to "unset" (None), like
    // upstream's existing behavior.
    term.feed(b"\x1b]10;#010101\x07\x1b]110\x07");
    assert_eq!(term.default_colors().0, None);
}
