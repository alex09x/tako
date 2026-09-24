// Host-configured base colors (Terminal::set_base_colors / TakoCore::set_base_colors).
//
// Today the macOS/iOS hosts have no way to tell the engine "this is my
// theme" -- they replay OSC 10/11/12/4 once at startup, indistinguishable
// from a program doing the same thing. That means any program that resets
// colors (OSC 104/110/111/112, or a full reset) drops the user back to the
// engine's built-in defaults. `set_base_colors` gives the host a color layer
// underneath whatever a running program sets: base = built-in defaults
// unless the host configures them, resets go to base instead of built-in,
// and a live base change repaints anything a program hasn't explicitly
// overridden.

use tako_core::ffi::{FfiPaletteEntry, FfiRgb, TakoCore};
use tako_core::terminal::Terminal;

// A couple of custom RGB triples, chosen to be distinguishable from both the
// engine's built-in Tomorrow Night palette and the FFI layer's brand
// DEFAULT_FG/DEFAULT_BG fallback ((0xED, 0xE6, 0xDF) / (0x14, 0x10, 0x0E)).
const BASE_FG: (u8, u8, u8) = (10, 20, 30);
const BASE_BG: (u8, u8, u8) = (40, 50, 60);
const BASE_CURSOR: (u8, u8, u8) = (1, 2, 3);
const BASE_IDX1: (u8, u8, u8) = (100, 110, 120);
const BASE_IDX2: (u8, u8, u8) = (130, 140, 150);

const BUILTIN_IDX1: (u8, u8, u8) = (0xCC, 0x66, 0x66); // default_color(1)
const BUILTIN_IDX2: (u8, u8, u8) = (0xB5, 0xBD, 0x68); // default_color(2)

fn osc4_set(index: u8, rgb: (u8, u8, u8)) -> Vec<u8> {
    format!("\x1b]4;{};#{:02x}{:02x}{:02x}\x07", index, rgb.0, rgb.1, rgb.2).into_bytes()
}

// ── Engine API (Terminal) ───────────────────────────────────────────────

#[test]
fn set_base_colors_applies_immediately_when_nothing_overridden() {
    let mut term = Terminal::new(10, 3);
    term.set_base_colors(
        Some(BASE_FG),
        Some(BASE_BG),
        Some(BASE_CURSOR),
        &[(1, BASE_IDX1), (2, BASE_IDX2)],
    );

    assert_eq!(term.default_colors(), (Some(BASE_FG), Some(BASE_BG), Some(BASE_CURSOR)));
    assert_eq!(term.base_colors(), (Some(BASE_FG), Some(BASE_BG), Some(BASE_CURSOR)));
    assert_eq!(term.palette().get(1), BASE_IDX1);
    assert_eq!(term.palette().get(2), BASE_IDX2);
    assert_eq!(term.palette().base(1), BASE_IDX1);

    // An index the host never mentioned keeps the built-in default.
    assert_eq!(term.palette().get(3), tako_core::palette::Palette::new().get(3));
}

#[test]
fn program_override_via_osc_wins_until_reset() {
    let mut term = Terminal::new(10, 3);
    term.set_base_colors(Some(BASE_FG), None, None, &[(1, BASE_IDX1)]);

    // Program takes over fg and palette index 1.
    let program_fg = (200, 201, 202);
    let program_idx1 = (203, 204, 205);
    term.feed(b"\x1b]10;#c8c9ca\x07"); // 200,201,202
    term.feed(&osc4_set(1, program_idx1));

    assert_eq!(term.default_colors().0, Some(program_fg));
    assert_eq!(term.palette().get(1), program_idx1);

    // Host pushes a theme change while the program's overrides are live:
    // the live values must NOT move, only the recorded base does.
    let new_base_fg = (11, 22, 33);
    let new_base_idx1 = (44, 55, 66);
    term.set_base_colors(Some(new_base_fg), None, None, &[(1, new_base_idx1)]);

    assert_eq!(term.default_colors().0, Some(program_fg), "program's fg override got clobbered");
    assert_eq!(term.palette().get(1), program_idx1, "program's palette override got clobbered");
    assert_eq!(term.base_colors().0, Some(new_base_fg));
    assert_eq!(term.palette().base(1), new_base_idx1);
}

#[test]
fn theme_change_updates_non_overridden_entries_immediately() {
    let mut term = Terminal::new(10, 3);
    term.set_base_colors(Some(BASE_FG), Some(BASE_BG), None, &[(1, BASE_IDX1), (2, BASE_IDX2)]);

    // Program only overrides index 2, leaves fg/bg/index1 alone.
    term.feed(&osc4_set(2, (9, 9, 9)));

    let new_fg = (7, 8, 9);
    let new_idx1 = (12, 13, 14);
    term.set_base_colors(Some(new_fg), Some(BASE_BG), None, &[(1, new_idx1), (2, (250, 250, 250))]);

    // Non-overridden entries follow the new base immediately.
    assert_eq!(term.default_colors().0, Some(new_fg));
    assert_eq!(term.palette().get(1), new_idx1);
    // The overridden entry stays put even though the host tried to move it.
    assert_eq!(term.palette().get(2), (9, 9, 9));
}

#[test]
fn osc104_all_and_by_index_restore_to_base_not_builtin() {
    let mut term = Terminal::new(10, 3);
    term.set_base_colors(None, None, None, &[(1, BASE_IDX1), (2, BASE_IDX2)]);
    term.feed(&osc4_set(1, (1, 1, 1)));
    term.feed(&osc4_set(2, (2, 2, 2)));

    // Reset a single index.
    term.feed(b"\x1b]104;1\x07");
    assert_eq!(term.palette().get(1), BASE_IDX1);
    assert_ne!(term.palette().get(1), BUILTIN_IDX1);
    assert_eq!(term.palette().get(2), (2, 2, 2), "untouched index must stay overridden");

    // Reset everything.
    term.feed(b"\x1b]104\x07");
    assert_eq!(term.palette().get(2), BASE_IDX2);
    assert_ne!(term.palette().get(2), BUILTIN_IDX2);
}

#[test]
fn osc110_111_112_restore_default_colors_to_base() {
    let mut term = Terminal::new(10, 3);
    term.set_base_colors(Some(BASE_FG), Some(BASE_BG), Some(BASE_CURSOR), &[]);
    term.feed(b"\x1b]10;#010101\x07");
    term.feed(b"\x1b]11;#020202\x07");
    term.feed(b"\x1b]12;#030303\x07");
    assert_ne!(term.default_colors(), (Some(BASE_FG), Some(BASE_BG), Some(BASE_CURSOR)));

    term.feed(b"\x1b]110\x07\x1b]111\x07\x1b]112\x07");
    assert_eq!(term.default_colors(), (Some(BASE_FG), Some(BASE_BG), Some(BASE_CURSOR)));
}

#[test]
fn ris_restores_everything_to_base() {
    let mut term = Terminal::new(10, 3);
    term.set_base_colors(
        Some(BASE_FG),
        Some(BASE_BG),
        Some(BASE_CURSOR),
        &[(1, BASE_IDX1)],
    );
    term.feed(b"\x1b]10;#010101\x07");
    term.feed(b"\x1b]11;#020202\x07");
    term.feed(b"\x1b]12;#030303\x07");
    term.feed(&osc4_set(1, (9, 9, 9)));

    term.feed(b"\x1bc"); // RIS

    assert_eq!(term.default_colors(), (Some(BASE_FG), Some(BASE_BG), Some(BASE_CURSOR)));
    assert_eq!(term.palette().get(1), BASE_IDX1);
    assert_ne!(term.palette().get(1), BUILTIN_IDX1);
    // The host's base configuration itself survives RIS.
    assert_eq!(term.base_colors(), (Some(BASE_FG), Some(BASE_BG), Some(BASE_CURSOR)));
}

#[test]
fn ris_without_a_configured_base_clears_overrides_to_unconfigured() {
    // No set_base_colors call at all -- a program's OSC 10/11/12 overrides
    // must not survive a full reset either.
    let mut term = Terminal::new(10, 3);
    term.feed(b"\x1b]10;#010101\x07\x1b]11;#020202\x07");
    assert_eq!(term.default_colors(), (Some((1, 1, 1)), Some((2, 2, 2)), None));

    term.feed(b"\x1bc"); // RIS
    assert_eq!(term.default_colors(), (None, None, None));
}

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
    assert_eq!(term.take_output(), b"\x1b]10;rgb:ffff/0000/0000\x07".to_vec());
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

// ── FFI API (TakoCore) ───────────────────────────────────────────────────

fn rgb(r: u8, g: u8, b: u8) -> FfiRgb {
    FfiRgb { r, g, b }
}

#[test]
fn ffi_set_base_colors_resolves_into_rendered_cells() {
    let core = TakoCore::new(10, 3);
    core.set_base_colors(
        Some(rgb(BASE_FG.0, BASE_FG.1, BASE_FG.2)),
        Some(rgb(BASE_BG.0, BASE_BG.1, BASE_BG.2)),
        None,
        vec![FfiPaletteEntry { index: 1, color: rgb(BASE_IDX1.0, BASE_IDX1.1, BASE_IDX1.2) }],
    );

    // A plain glyph uses Color::Default, which must resolve to the host's
    // base -- not the FFI layer's brand fallback colors.
    core.feed(b"X".to_vec());
    let cell = core.get_cell(0, 0).unwrap();
    assert_eq!((cell.fg_r, cell.fg_g, cell.fg_b), BASE_FG);
    assert_eq!((cell.bg_r, cell.bg_g, cell.bg_b), BASE_BG);

    // An indexed color uses the base palette entry.
    core.feed(b"\x1b[38;5;1mY".to_vec());
    let cell = core.get_cell(0, 1).unwrap();
    assert_eq!((cell.fg_r, cell.fg_g, cell.fg_b), BASE_IDX1);

    // A program override wins over the base...
    core.feed(osc4_set(1, (9, 9, 9)));
    core.feed(b"\x1b[38;5;1mZ".to_vec());
    let cell = core.get_cell(0, 2).unwrap();
    assert_eq!((cell.fg_r, cell.fg_g, cell.fg_b), (9, 9, 9));

    // ...until OSC 104 resets it back to base, not the engine's built-in.
    core.feed(b"\x1b]104\x07".to_vec());
    core.feed(b"\x1b[38;5;1mW".to_vec());
    let cell = core.get_cell(0, 3).unwrap();
    assert_eq!((cell.fg_r, cell.fg_g, cell.fg_b), BASE_IDX1);
    assert_ne!((cell.fg_r, cell.fg_g, cell.fg_b), BUILTIN_IDX1);
}

#[test]
fn ffi_theme_change_updates_non_overridden_palette_entries_only() {
    let core = TakoCore::new(10, 3);
    core.set_base_colors(
        None,
        None,
        None,
        vec![
            FfiPaletteEntry { index: 1, color: rgb(BASE_IDX1.0, BASE_IDX1.1, BASE_IDX1.2) },
            FfiPaletteEntry { index: 2, color: rgb(BASE_IDX2.0, BASE_IDX2.1, BASE_IDX2.2) },
        ],
    );
    // Cell A references index 1 (left alone); cell B references index 2
    // (the program is about to override it).
    core.feed(b"\x1b[38;5;1mA\x1b[38;5;2mB".to_vec());

    let overridden_idx2 = (9, 9, 9);
    core.feed(osc4_set(2, overridden_idx2));

    // Host pushes a new theme touching both indices.
    let new_base_idx1 = (77, 88, 99);
    let new_base_idx2 = (55, 44, 33);
    core.set_base_colors(
        None,
        None,
        None,
        vec![
            FfiPaletteEntry { index: 1, color: rgb(new_base_idx1.0, new_base_idx1.1, new_base_idx1.2) },
            FfiPaletteEntry { index: 2, color: rgb(new_base_idx2.0, new_base_idx2.1, new_base_idx2.2) },
        ],
    );

    // The non-overridden index follows the new theme immediately...
    let cell_a = core.get_cell(0, 0).unwrap();
    assert_eq!((cell_a.fg_r, cell_a.fg_g, cell_a.fg_b), new_base_idx1);
    // ...but the program's explicit override is not clobbered.
    let cell_b = core.get_cell(0, 1).unwrap();
    assert_eq!((cell_b.fg_r, cell_b.fg_g, cell_b.fg_b), overridden_idx2);
}

/// The host's own "reset terminal" rebuilds the engine. It used to build a
/// bare one, so after a reset the default colors and every themed palette
/// entry fell back to the built-ins until the host thought to reapply them.
#[test]
fn ffi_reset_keeps_the_host_base_colors_and_drops_program_overrides() {
    let core = TakoCore::new(10, 3);
    core.set_base_colors(
        Some(rgb(BASE_FG.0, BASE_FG.1, BASE_FG.2)),
        Some(rgb(BASE_BG.0, BASE_BG.1, BASE_BG.2)),
        Some(rgb(BASE_CURSOR.0, BASE_CURSOR.1, BASE_CURSOR.2)),
        vec![FfiPaletteEntry { index: 1, color: rgb(BASE_IDX1.0, BASE_IDX1.1, BASE_IDX1.2) }],
    );
    core.feed(b"\x1b]10;#090909\x07".to_vec());
    core.feed(osc4_set(1, (9, 9, 9)));
    core.feed(b"old".to_vec());

    core.reset();

    core.feed(b"X\x1b[38;5;1mY".to_vec());
    let plain = core.get_cell(0, 0).unwrap();
    assert_eq!((plain.fg_r, plain.fg_g, plain.fg_b), BASE_FG);
    assert_eq!((plain.bg_r, plain.bg_g, plain.bg_b), BASE_BG);
    let indexed = core.get_cell(0, 1).unwrap();
    assert_eq!((indexed.fg_r, indexed.fg_g, indexed.fg_b), BASE_IDX1);

    // Still a reset: the old content and the program's override are gone.
    assert!(!core.buffer_text().contains("old"));
    let mut term = Terminal::new(10, 3);
    term.set_base_colors(Some(BASE_FG), Some(BASE_BG), Some(BASE_CURSOR), &[(1, BASE_IDX1)]);
    term.feed(b"\x1b]10;#090909\x07");
    let fresh = term.fresh_keeping_host_config();
    assert_eq!(fresh.base_colors(), (Some(BASE_FG), Some(BASE_BG), Some(BASE_CURSOR)));
    assert_eq!(fresh.default_colors(), (Some(BASE_FG), Some(BASE_BG), Some(BASE_CURSOR)));
    assert_eq!(fresh.palette().get(1), BASE_IDX1);
    assert_eq!(fresh.palette().get(2), term.palette().base(2));
}
