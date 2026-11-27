/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import TakoCoreUI

extension Tako.SurfaceView {
    /// The characters of `rows` (counted from the top of the scrollback, as
    /// `viewportRow` counts them), one line per row, without styling: what
    /// `cachedScreenContents` and `cachedVisibleContents` hold.
    func plainText(ofRows rows: Range<Int>) -> String {
        rows.map { row in
            String(String.UnicodeScalarView(
                core.viewportRow(row: UInt32(row)).compactMap { UnicodeScalar($0.ch) }))
        }
        .joined(separator: "\n")
    }
}
