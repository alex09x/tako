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
    /// The crab as the brand draws it (Terminal UI › «Краб во вкладке: 7
    /// состояний»): the mark on the grid the app icons use, the ghost's own
    /// figure, and the colours of each state.
    enum CrabPainter {
        /// Row 0 at the top: `C` a claw, `#` the body, `o` an eye -- a hole
        /// the tab shows through.
        static let rows = [
            "CC......CC",
            "C........C",
            ".#......#.",
            "..######..",
            "..#o##o#..",
            "..######..",
            ".#.#..#.#.",
        ]

        /// "призрак — связь оборвалась": the crab as a ghost, its arms one
        /// row, its eyes higher, a hem for legs.
        static let ghostRows = [
            "CC......CC",
            "C........C",
            ".########.",
            "..#o##o#..",
            "..######..",
            "..######..",
            "..#.##.#..",
        ]

        static func rows(for state: CrabState) -> [String] { state == .ghost ? ghostRows : rows }

        /// Claws and body: Claw and Ember at rest and on a bell, Claw all
        /// over while it works or reconnects, green or red when a command ends.
        static func colors(for state: CrabState) -> (claws: NSColor, body: NSColor) {
            switch state {
            case .idle, .attention, .ghost: return (Brand.claw, Brand.ember)
            case .running, .reconnecting: return (Brand.claw, Brand.claw)
            case .succeeded: return (Brand.ok, Brand.ok)
            case .failed: return (Brand.error, Brand.error)
            }
        }

        /// The ghost is the crab at 45 %.
        static func opacity(for state: CrabState) -> Float { state == .ghost ? 0.45 : 1 }

        /// The claws' and the body's cells of `rows` in `rect`, on whole
        /// device pixels: the mark is a pixel grid and a fractional cell
        /// turns it to mush. Cells touch until there is room for a pixel
        /// between them.
        static func cells(_ rows: [String], in rect: CGRect, scale: CGFloat) -> (claws: CGPath, body: CGPath) {
            let claws = CGMutablePath(), body = CGMutablePath()
            let scale = max(scale, 1)
            let step = (min(rect.width / 10, rect.height / 7) * scale).rounded(.down) / scale
            guard step * scale >= 1 else { return (claws, body) }
            let cell = step * scale >= 4 ? step - 1 / scale : step
            let originX = ((rect.midX - step * 5) * scale).rounded() / scale
            let topY = ((rect.midY + step * 3.5) * scale).rounded() / scale
            for (r, row) in rows.enumerated() {
                for (c, mark) in row.enumerated() {
                    let square = CGRect(x: originX + CGFloat(c) * step, y: topY - CGFloat(r + 1) * step, width: cell, height: cell)
                    switch mark {
                    case "C": claws.addRect(square)
                    case "#": body.addRect(square)
                    default: break
                    }
                }
            }
            return (claws, body)
        }
    }
}

extension Tako.CrabState {
    /// The same state whatever a failure's exit code: a second failure is
    /// not a new change to shiver for.
    func isSameKind(as other: Self) -> Bool {
        switch (self, other) {
        case (.failed, .failed): return true
        default: return self == other
        }
    }
}
