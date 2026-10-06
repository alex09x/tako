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
fn test_size_query_does_not_materialize_the_checkpoint() {
    assert_eq!(keep_symbols().len(), 6);

    let vt = filled_terminal(8_000);

    // What the size query reports, and what it cost.
    let (status, size, query_cost) = size_query(vt);
    // The two-call idiom: NULL/0 reports the required size and says the
    // buffer was too small, which is the documented way to ask.
    assert_eq!(
        status, PROD_VT_ERR_BUFFER_TOO_SMALL,
        "sizing with NULL/0 must report the required size"
    );
    assert!(
        size > 1 << 20,
        "this test is only meaningful on a large checkpoint; got {size} bytes"
    );

    // The number must be exact: the caller allocates exactly this and the
    // second call must fit in it.
    let mut buf = vec![0u8; size];
    let mut written: usize = 0;
    let status =
        unsafe { prod_vt_checkpoint_export2(vt, 0, buf.as_mut_ptr(), buf.len(), &mut written) };
    assert_eq!(status, PROD_VT_OK);
    assert_eq!(written, size, "the size query and the export disagreed");

    // The dedicated measurement entry point is the same number, plainly said.
    let mut measured: usize = 0;
    let status = unsafe { prod_vt_checkpoint_measure2(vt, 0, &mut measured) };
    assert_eq!(status, PROD_VT_OK);
    assert_eq!(measured, size, "measure2 and export2 disagreed on the size");

    unsafe { prod_vt_free(vt) };

    // The measurement's cost must not scale with the payload. A counting
    // measurement needs working space, not a copy of the container.
    assert!(
        query_cost < 128 * 1024,
        "the size query allocated {query_cost} bytes to measure a {size}-byte \
         checkpoint -- it serialized the whole thing and threw it away"
    );

    // "Does not scale" is a claim about two points, not one: an eighth of the
    // content must not cost meaningfully less to measure. A serializing query
    // would fall by roughly the same factor the payload does.
    let small = filled_terminal(1_000);
    let (small_status, small_size, small_cost) = size_query(small);
    unsafe { prod_vt_free(small) };
    assert_eq!(small_status, PROD_VT_ERR_BUFFER_TOO_SMALL);
    assert!(
        size > small_size * 4,
        "the two fixtures are not far enough apart: {size} vs {small_size}"
    );
    assert!(
        small_cost * 4 > query_cost,
        "the size query cost tracks the payload: {query_cost} bytes to measure \
         {size} but only {small_cost} to measure {small_size}"
    );
}
