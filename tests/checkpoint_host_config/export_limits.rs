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
fn export_version_writes_what_was_asked_or_refuses() {
    let term = themed_source();
    assert_eq!(MIN_EXPORT_VERSION, 2);
    assert_eq!(
        header_version(&term.export_checkpoint_version(0, 0).unwrap()),
        6
    );
    assert_eq!(
        header_version(&term.export_checkpoint_version(3, 0).unwrap()),
        3
    );
    assert_eq!(
        header_version(&term.export_checkpoint_version(4, 0).unwrap()),
        4
    );
    assert_eq!(
        header_version(&term.export_checkpoint_version(5, 0).unwrap()),
        5
    );
    assert_eq!(
        header_version(&term.export_checkpoint_version(6, 0).unwrap()),
        6
    );
    for version in [1, 7, u32::MAX] {
        assert_eq!(
            term.export_checkpoint_version(version, 0),
            Err(CheckpointError::UnsupportedVersion(version))
        );
        assert_eq!(
            term.measure_checkpoint_version(version, 0),
            Err(CheckpointError::UnsupportedVersion(version))
        );
    }
    // The measurement is the export's exact length, per version; v3 is v2
    // plus the host block.
    for version in [2, 3] {
        let blob = term.export_checkpoint_version(version, 0).unwrap();
        assert_eq!(
            term.measure_checkpoint_version(version, 0).unwrap(),
            blob.len() as u64
        );
        assert!(checkpoint::verify(&blob));
    }
    let v2 = term.export_checkpoint_version(2, 0).unwrap().len();
    let v3 = term.export_checkpoint_version(3, 0).unwrap().len();
    // 256 base colours, 256 override bits, the fg base (set: flag + rgb) and
    // the bg and cursor bases (unset: flag only), three override flags, the
    // default cursor style and whether a program changed it, and two empty
    // cluster lists.
    assert_eq!(v3 - v2, 256 * 3 + 32 + 4 + 1 + 1 + 3 + 2 + 1 + 4 + 4);
    // A cap still applies to the version asked for.
    assert!(matches!(
        term.export_checkpoint_version(2, 64),
        Err(CheckpointError::TooLarge { .. })
    ));
}

#[test]
fn a_truncated_host_block_is_refused_not_half_applied() {
    let term = themed_source();
    let blob = term.export_checkpoint().unwrap();
    let mut short = blob[..blob.len() - 1].to_vec();
    let payload_len = (short.len() - 20) as u32;
    short[12..16].copy_from_slice(&payload_len.to_le_bytes());
    let crc = checkpoint::crc32(&short[20..]);
    short[16..20].copy_from_slice(&crc.to_le_bytes());

    let mut dest = Terminal::new(20, 4);
    dest.feed(b"DEST");
    assert_eq!(
        dest.import_checkpoint(&short),
        Err(CheckpointError::UnexpectedEof)
    );
    assert_eq!(
        dest.palette().get(1),
        tako_core::palette::Palette::new().get(1)
    );
}

#[test]
fn ffi_exports_the_version_a_peer_asks_for() {
    let core = TakoCore::new(20, 4);
    core.feed(b"negotiate".to_vec());
    let v2 = core.checkpoint_export_version(2, 0).unwrap();
    assert_eq!(header_version(&v2), 2);
    assert_eq!(
        header_version(&core.checkpoint_export_version(0, 0).unwrap()),
        6
    );
    assert!(core.checkpoint_export_version(1, 0).is_err());

    let dest = TakoCore::new(20, 4);
    dest.checkpoint_import(v2).unwrap();
}

// ── The host's scrollback limit survives a reset ─────────────────────────

#[test]
fn ris_keeps_the_hosts_scrollback_limit() {
    let mut term = Terminal::new(20, 4);
    term.set_scrollback_capacity(50_000);
    term.feed(b"\x1bc");
    assert_eq!(term.active_grid().scrollback_capacity(), 50_000);

    // And it is honoured, not just reported: 60 lines through a 4-row
    // screen with a 10-line limit keep 10.
    let mut small = Terminal::new(20, 4);
    small.set_scrollback_capacity(10);
    small.feed(b"\x1bc");
    for i in 0..60 {
        small.feed(format!("line {i}\r\n").as_bytes());
    }
    assert_eq!(small.active_grid().scrollback_len(), 10);
}

#[test]
fn a_host_reset_keeps_the_hosts_scrollback_limit() {
    let mut term = Terminal::new(20, 4);
    term.set_scrollback_capacity(123);
    let fresh = term.fresh_keeping_host_config();
    assert_eq!(fresh.active_grid().scrollback_capacity(), 123);

    let core = TakoCore::new(20, 4);
    core.set_scrollback_limit(10);
    core.reset();
    for i in 0..60 {
        core.feed(format!("line {i}\r\n").into_bytes());
    }
    assert_eq!(core.scrollback_len(), 10);
}
