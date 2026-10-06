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

/// Measuring a terminal parked in the middle of a large OSC or APC must not
/// copy the payload it is parked on.
///
/// The counting sink stopped the *encoder* from materializing the container,
/// and borrowing the grids stopped serialization from cloning the cells -- but
/// the parser's own raw buffer was still copied out through `Parser::snapshot`
/// twice on every measurement, once to price it and once to encode it. An
/// in-flight OSC is bounded by nothing but the host's input, so that put the
/// payload straight back into the cost of asking for a number.
///
/// This is a checkpoint boundary the container is required to survive, not an
/// edge case: a checkpoint taken while a shell is halfway through writing a
/// long title has to restore into the middle of that same sequence.
#[test]
fn test_measuring_an_in_flight_string_does_not_copy_its_payload() {
    const SMALL: usize = 1 << 20; // 1 MiB
    const LARGE: usize = 8 << 20; // 8 MiB

    // `ESC ] 0 ;` opens an OSC; `ESC _` opens an APC. Both accumulate raw
    // bytes until their terminator, which is never sent here.
    for (label, intro) in [("OSC", &b"\x1b]0;"[..]), ("APC", &b"\x1b_"[..])] {
        let mut costs = Vec::new();
        let mut sizes = Vec::new();

        for payload in [SMALL, LARGE] {
            let vt = terminal_in_flight(intro, payload);

            let mut measured: usize = 0;
            let (status, cost) =
                bytes_allocated_by(|| unsafe { prod_vt_checkpoint_measure2(vt, 0, &mut measured) });
            assert_eq!(status, PROD_VT_OK, "{label}: measuring failed");
            assert!(
                measured > payload,
                "{label}: the in-flight payload is not in the checkpoint \
                 ({measured} bytes for a {payload}-byte payload)"
            );

            // Exact agreement with the export, on the same fixture.
            let blob = export_exactly(vt, measured);

            // Continuation is unchanged: the restored terminal is still parked
            // inside the same sequence, holding the same bytes, and finishing
            // it produces the same state.
            let dest = unsafe { prod_vt_new(80, 24, 100) };
            assert!(!dest.is_null());
            let status = unsafe { prod_vt_checkpoint_import2(dest, blob.as_ptr(), blob.len()) };
            assert_eq!(
                status, PROD_VT_OK,
                "{label}: import of the measured blob failed"
            );

            let terminator = b"\x1b\\PING\r\n";
            unsafe { prod_vt_write(vt, terminator.as_ptr(), terminator.len()) };
            unsafe { prod_vt_write(dest, terminator.as_ptr(), terminator.len()) };

            let mut after_src: usize = 0;
            assert_eq!(
                unsafe { prod_vt_checkpoint_measure2(vt, 0, &mut after_src) },
                PROD_VT_OK
            );
            let mut after_dst: usize = 0;
            assert_eq!(
                unsafe { prod_vt_checkpoint_measure2(dest, 0, &mut after_dst) },
                PROD_VT_OK
            );
            assert_eq!(
                export_exactly(vt, after_src),
                export_exactly(dest, after_dst),
                "{label}: finishing the sequence diverged after a round trip"
            );

            unsafe { prod_vt_free(dest) };
            unsafe { prod_vt_free(vt) };

            costs.push(cost);
            sizes.push(measured);
        }

        // Absolute: the measurement needs working space, not a copy of the
        // payload it is measuring.
        assert!(
            costs[1] < 128 * 1024,
            "{label}: measuring a {}-byte checkpoint allocated {} bytes -- the \
             in-flight payload was copied",
            sizes[1],
            costs[1]
        );
        // Relative: eight times the payload must not cost eight times as much.
        assert!(
            costs[1] < costs[0].saturating_mul(4).max(128 * 1024),
            "{label}: the measurement cost tracks the payload -- {} bytes for \
             {} but {} bytes for {}",
            costs[0],
            sizes[0],
            costs[1],
            sizes[1]
        );
    }
}
