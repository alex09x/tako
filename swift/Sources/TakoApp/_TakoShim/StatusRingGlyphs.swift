/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import SwiftUI

/// The glyphs drawn inside a finished ring: the check mark and the exclamation mark.
extension StatusRingView {
    func checkmarkShape(in d: CGFloat) -> Path {
        let s = d / 14.0
        var path = Path()
        path.move(to: CGPoint(x: 4.0 * s, y: 7.2 * s))
        path.addLine(to: CGPoint(x: 6.1 * s, y: 9.3 * s))
        path.addLine(to: CGPoint(x: 10.0 * s, y: 5.0 * s))
        return path
    }

    func exclamationShape(in d: CGFloat) -> Path {
        var path = Path()
        if d >= 18 {
            path.addRoundedRect(in: CGRect(x: 8, y: 4, width: 2, height: 6), cornerSize: CGSize(width: 1, height: 1))
            path.addRoundedRect(in: CGRect(x: 8, y: 12.5, width: 2, height: 2), cornerSize: CGSize(width: 1, height: 1))
        } else {
            let s = d / 14.0
            path.addRoundedRect(in: CGRect(x: 6 * s, y: 3 * s, width: 2 * s, height: 5 * s), cornerSize: CGSize(width: 1, height: 1))
            path.addRoundedRect(in: CGRect(x: 6 * s, y: 9.5 * s, width: 2 * s, height: 2 * s), cornerSize: CGSize(width: 1, height: 1))
        }
        return path
    }
}
