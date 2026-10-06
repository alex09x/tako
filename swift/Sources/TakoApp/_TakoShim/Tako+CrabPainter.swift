/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import CoreGraphics

extension Tako {
    /// The brand mark at any size, from the grid the app icons use.
    enum CrabPainter {
        static let rows = [
            "CC......CC",
            "C........C",
            ".#......#.",
            "..######..",
            "..#o##o#..",
            "..######..",
            ".#.#..#.#.",
        ]

        /// Whole-pixel cells only: the mark is a pixel grid and a fractional
        /// cell turns it to mush.
        static func draw(in rect: CGRect, color: NSColor, unread: Bool = false, context ctx: CGContext) {
            let step = min(rect.width / 10, rect.height / 7).rounded(.down)
            guard step >= 1 else { return }
            let cell = max(step - 1, 1)
            let originX = (rect.midX - step * 5).rounded()
            let topY = (rect.midY + step * 3.5).rounded()

            func fill(_ predicate: (Character) -> Bool) {
                for (r, row) in rows.enumerated() {
                    for (c, ch) in row.enumerated() where predicate(ch) {
                        ctx.fill(CGRect(x: originX + CGFloat(c) * step,
                                        y: topY - CGFloat(r + 1) * step,
                                        width: cell, height: cell))
                    }
                }
            }

            ctx.setFillColor(color.cgColor)
            fill { $0 != "." && $0 != "o" }
            // The eyes are holes, so the tab behind shows through.
            ctx.setBlendMode(.clear)
            fill { $0 == "o" }
            ctx.setBlendMode(.normal)

            if unread {
                ctx.setFillColor(Brand.claw.cgColor)
                ctx.fillEllipse(in: CGRect(x: rect.maxX - 3, y: rect.maxY - 3, width: 3, height: 3))
            }
        }
    }
}
