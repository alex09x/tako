/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::*;

#[test]
fn test_palette_new_defaults() {
    let palette = Palette::new();
    // ANSI 16
    assert_eq!(palette.get(1), (0xCC, 0x66, 0x66));
    // 6x6x6 color cube
    assert_eq!(palette.get(16), (0, 0, 0));
    assert_eq!(palette.get(231), (255, 255, 255));
    // 24-step grayscale ramp
    assert_eq!(palette.get(232), (8, 8, 8));
    assert_eq!(palette.get(255), (238, 238, 238));
}

#[test]
fn test_set_get_roundtrip() {
    let mut palette = Palette::new();
    palette.set(42, (12, 34, 56));
    assert_eq!(palette.get(42), (12, 34, 56));
}

#[test]
fn test_reset() {
    let mut palette = Palette::new();
    palette.set(10, (1, 2, 3));
    palette.set(20, (4, 5, 6));

    palette.reset(10);
    assert_eq!(palette.get(10), (0xB9, 0xCA, 0x4A)); // default for 10
    assert_eq!(palette.get(20), (4, 5, 6)); // untouched
}

#[test]
fn test_reset_all() {
    let mut palette = Palette::new();
    palette.set(10, (1, 2, 3));
    palette.set(20, (4, 5, 6));
    palette.set(200, (7, 8, 9));

    palette.reset_all();
    let default_p = Palette::new();
    for i in 0..=255 {
        assert_eq!(palette.get(i), default_p.get(i));
    }
}

#[test]
fn test_query_response() {
    let palette = Palette::new();
    // index 1: (0xCC, 0x66, 0x66) - tests channel 0
    assert_eq!(
        palette.query_response(1),
        "\x1b]4;1;rgb:cccc/6666/6666\x1b\\"
    );
    // index 231: (255, 255, 255) - tests channel 255
    assert_eq!(
        palette.query_response(231),
        "\x1b]4;231;rgb:ffff/ffff/ffff\x1b\\"
    );
}

#[test]
fn test_parse_color_spec_valid() {
    let expected = (255, 128, 0);
    assert_eq!(parse_color_spec("#ff8000"), Some(expected));
    assert_eq!(parse_color_spec("#FF8000"), Some(expected));
    assert_eq!(parse_color_spec("rgb:ff/80/00"), Some(expected));
    assert_eq!(parse_color_spec("RGB:ff/80/00"), Some(expected));
    assert_eq!(parse_color_spec("rgb:ffff/8080/0000"), Some(expected));

    // 1-digit test
    assert_eq!(parse_color_spec("rgb:f/8/0"), Some((255, 136, 0)));
}

#[test]
fn test_parse_color_spec_malformed() {
    // wrong prefix
    assert_eq!(parse_color_spec("xyz:ff/80/00"), None);
    assert_eq!(parse_color_spec("ff8000"), None);
    assert_eq!(parse_color_spec("#ff80000"), None);

    // wrong digit count
    assert_eq!(parse_color_spec("rgb:f/8/00"), None);
    assert_eq!(parse_color_spec("#fff"), None);
    assert_eq!(parse_color_spec("rgb:fffff/80800/00000"), None);

    // non-hex characters
    assert_eq!(parse_color_spec("rgb:fg/80/00"), None);
    assert_eq!(parse_color_spec("#ff800g"), None);

    // mismatched group lengths
    assert_eq!(parse_color_spec("rgb:ff/800/00"), None);

    // empty / unicode / malformed
    assert_eq!(parse_color_spec(""), None);
    assert_eq!(parse_color_spec("#"), None);
    assert_eq!(parse_color_spec("rgb:"), None);
    assert_eq!(parse_color_spec("rgb:///"), None);
    assert_eq!(parse_color_spec("\u{1f600}"), None);
    assert_eq!(parse_color_spec("#\u{1f600}"), None);
}
