/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use crate::ffi::core::{TakoCore, lock_recover};
use crate::ffi::query_types::TakoCheckpointError;
use crate::ffi::types::PACKED_CELL_SIZE;
use std::sync::Mutex;

#[test]
fn lock_recover_locks_a_healthy_mutex() {
    let mutex = Mutex::new(5);
    assert_eq!(*lock_recover(&mutex), 5);
}

#[test]
fn lock_recover_survives_a_poisoned_mutex() {
    let mutex = Mutex::new(1);
    let prev_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(|_| {}));
    let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
        let mut guard = mutex.lock().unwrap();
        *guard = 2;
        panic!("simulated engine bug while holding the lock");
    }));
    std::panic::set_hook(prev_hook);
    assert!(result.is_err());
    assert!(mutex.is_poisoned());

    let mut guard = lock_recover(&mutex);
    assert_eq!(
        *guard, 2,
        "the poisoned guard must carry the last write, not be reset"
    );
    *guard = 3;
    drop(guard);
    assert_eq!(*lock_recover(&mutex), 3);
}

#[test]
fn takocore_keeps_working_after_its_engine_mutex_is_poisoned() {
    let core = std::sync::Arc::new(TakoCore::new(20, 5));
    core.feed(b"before poison".to_vec());

    let poisoner = std::sync::Arc::clone(&core);
    let prev_hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(|_| {}));
    let handle = std::thread::spawn(move || {
        let _guard = poisoner.inner.lock().unwrap();
        panic!("simulated engine bug while holding the terminal lock");
    });
    let _ = handle.join();
    std::panic::set_hook(prev_hook);

    assert!(core.inner.is_poisoned());

    core.feed(b"\r\nafter poison".to_vec());
    assert_eq!(
        core.get_line(0).trim_end_matches(['\0', ' ']),
        "before poison"
    );
    assert_eq!(
        core.get_line(1).trim_end_matches(['\0', ' ']),
        "after poison"
    );

    let frame = core.render_frame();
    assert_eq!(frame.snapshot.cols, 20);
    assert_eq!(frame.snapshot.rows, 5);
    assert_eq!(frame.packed_cells.len(), 20 * 5 * PACKED_CELL_SIZE);

    assert_eq!(core.cursor_row(), 1);
}

#[test]
fn test_feed_with_outcome_returns_output_and_events_once() {
    let core = TakoCore::new(80, 24);
    let outcome = core.feed_with_outcome(b"\x1b[c\x07".to_vec());
    assert!(
        !outcome.output.is_empty(),
        "expected primary device attributes response"
    );
    assert!(
        outcome
            .events
            .iter()
            .any(|e| matches!(e, crate::ffi::FfiEvent::Bell)),
        "expected bell event"
    );
    assert!(
        core.take_output().is_empty(),
        "take_output should be drained"
    );
    assert!(
        core.take_events().is_empty(),
        "take_events should be drained"
    );
}

#[test]
fn test_feed_with_outcome_has_damage_does_not_drain_rows() {
    let core = TakoCore::new(80, 24);
    let outcome = core.feed_with_outcome(b"hello world\r\n".to_vec());
    assert!(outcome.has_damage, "feed produced visible content");
    assert!(!core.render_frame().snapshot.damaged_rows.is_empty());
}

#[test]
fn test_feed_with_outcome_reports_post_feed_synchronized_output() {
    let core = TakoCore::new(80, 24);
    let o1 = core.feed_with_outcome(b"\x1b[?2026h".to_vec());
    assert!(o1.synchronized_output_active);
    assert!(core.is_synchronized_output_active());

    let o2 = core.feed_with_outcome(b"\x1b[?2026l".to_vec());
    assert!(!o2.synchronized_output_active);
    assert!(!core.is_synchronized_output_active());
}

#[test]
fn test_takocore_modes_tracks_alternate_screen_and_alternate_scroll() {
    let core = TakoCore::new(80, 24);

    let m = core.modes();
    assert!(!m.alternate_screen);
    assert!(m.alternate_scroll);
    assert!(!core.snapshot().modes.alternate_screen);
    assert!(core.snapshot().modes.alternate_scroll);

    core.feed(b"\x1b[?1049h".to_vec());
    let m = core.modes();
    assert!(m.alternate_screen);
    assert!(m.alternate_scroll);
    assert!(core.snapshot().modes.alternate_screen);

    core.feed(b"\x1b[?1007l".to_vec());
    let m = core.modes();
    assert!(m.alternate_screen);
    assert!(!m.alternate_scroll);
    assert!(!core.snapshot().modes.alternate_scroll);

    core.feed(b"\x1b[?1049l".to_vec());
    let m = core.modes();
    assert!(!m.alternate_screen);
    assert!(!m.alternate_scroll);

    core.feed(b"\x1b[!p".to_vec());
    let m = core.modes();
    assert!(!m.alternate_screen);
    assert!(m.alternate_scroll);

    core.feed(b"\x1b[?47h".to_vec());
    assert!(core.modes().alternate_screen);
    core.feed(b"\x1b[?47l".to_vec());
    assert!(!core.modes().alternate_screen);

    core.feed(b"\x1b[?1047h".to_vec());
    assert!(core.modes().alternate_screen);
    core.feed(b"\x1b[?1047l".to_vec());
    assert!(!core.modes().alternate_screen);
}

#[test]
fn checkpoint_version_negotiation_is_explicit() {
    let core = TakoCore::new(40, 10);
    assert_eq!(core.checkpoint_version(), 6);
    assert!(core.checkpoint_supports(1));
    assert!(core.checkpoint_supports(2));
    assert!(core.checkpoint_supports(3));
    assert!(core.checkpoint_supports(4));
    assert!(core.checkpoint_supports(5));
    assert!(core.checkpoint_supports(6));
    assert!(!core.checkpoint_supports(0));
    assert!(!core.checkpoint_supports(7));

    core.feed(b"negotiate".to_vec());
    let blob = core.checkpoint_export(0, 1 << 20).unwrap();

    let mut newer = blob.clone();
    newer[4..8].copy_from_slice(&7u32.to_le_bytes());
    let crc = crate::terminal::checkpoint::crc32(&newer[20..]);
    newer[16..20].copy_from_slice(&crc.to_le_bytes());

    let dest = TakoCore::new(20, 6);
    assert_eq!(
        dest.checkpoint_import(newer.clone()),
        Err(TakoCheckpointError::UnsupportedVersion { version: 7 })
    );
    assert_eq!(
        dest.checkpoint_inspect(newer),
        Err(TakoCheckpointError::UnsupportedVersion { version: 7 })
    );

    let mut corrupt = blob.clone();
    let last = corrupt.len() - 1;
    corrupt[last] ^= 0xFF;
    assert!(matches!(
        dest.checkpoint_import(corrupt),
        Err(TakoCheckpointError::Corrupt { .. })
    ));

    let info = dest.checkpoint_inspect(blob.clone()).unwrap();
    assert_eq!((info.version, info.cols, info.rows), (6, 40, 10));
    assert_eq!(info.payload_len as usize, blob.len() - 20);
    assert_eq!(dest.checkpoint_import(blob), Ok(()));
}

#[test]
fn checkpoint_export_refuses_at_the_caller_supplied_cap() {
    let core = TakoCore::new(40, 10);
    core.feed(b"bounded".to_vec());
    let full = core.checkpoint_export(0, u64::MAX).unwrap();

    match core.checkpoint_export(0, 32) {
        Err(TakoCheckpointError::TooLarge { size, limit }) => {
            assert_eq!(limit, 32);
            assert!(size > 32);
        }
        other => panic!("expected TooLarge, got {other:?}"),
    }
    assert_eq!(core.checkpoint_export(0, u64::MAX).unwrap(), full);
    assert_eq!(core.checkpoint_export(0, 0).unwrap(), full);
    assert_eq!(
        core.checkpoint_export(0, full.len() as u64).unwrap().len(),
        full.len()
    );
    match core.checkpoint_export(0, full.len() as u64 - 1) {
        Err(TakoCheckpointError::TooLarge { size, limit }) => {
            assert_eq!(size, full.len() as u64);
            assert_eq!(limit, full.len() as u64 - 1);
        }
        other => panic!("expected TooLarge one byte under the blob, got {other:?}"),
    }
    assert_eq!(
        core.checkpoint_import(Vec::new()),
        Err(TakoCheckpointError::NullArgument)
    );
}

#[test]
fn checkpoint_import_is_fail_intact_and_publishes_an_epoch() {
    let dest = TakoCore::new(60, 20);
    dest.feed(b"DESTINATION\r\nsecond".to_vec());
    let before = dest.checkpoint_export(0, u64::MAX).unwrap();
    let epoch_before = dest.state_epoch();

    for blob in [Vec::new(), vec![1, 2, 3], before[..8].to_vec()] {
        assert!(dest.checkpoint_import(blob).is_err());
        assert_eq!(
            dest.checkpoint_export(0, u64::MAX).unwrap(),
            before,
            "a rejected import leaves the destination byte-identical"
        );
        assert_eq!(
            dest.state_epoch(),
            epoch_before,
            "and does not move the epoch"
        );
    }

    let source = TakoCore::new(30, 8);
    source.feed(b"SOURCE".to_vec());
    let good = source.checkpoint_export(0, u64::MAX).unwrap();
    dest.checkpoint_import(good.clone()).unwrap();
    assert!(
        dest.state_epoch() > epoch_before,
        "a swap publishes a new epoch"
    );
    assert_eq!(dest.checkpoint_export(0, u64::MAX).unwrap(), good);
    assert_eq!(dest.cols(), 30);
    assert_eq!(dest.rows(), 8);
}

#[test]
fn feed_outcomes_and_frames_carry_the_epoch_they_were_taken_under() {
    let core = TakoCore::new(40, 10);
    let first = core.feed_with_outcome(b"before".to_vec());
    assert_eq!(first.epoch, core.state_epoch());
    assert_eq!(core.render_frame().epoch, first.epoch);

    let source = TakoCore::new(40, 10);
    source.feed(b"after".to_vec());
    core.checkpoint_import(source.checkpoint_export(0, u64::MAX).unwrap())
        .unwrap();

    assert_ne!(first.epoch, core.state_epoch());
    let second = core.feed_with_outcome(b"!".to_vec());
    assert_eq!(second.epoch, core.state_epoch());
    assert_eq!(core.render_frame().epoch, second.epoch);

    let epoch = core.state_epoch();
    core.reset();
    assert_ne!(core.state_epoch(), epoch);
}
