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
import SwiftUI

/// Watches a SwiftUI view move: hosted in a window on screen, a change is
/// made and the view is drawn as the window would draw it every few
/// milliseconds after, each frame reduced to a number (how much of it shows,
/// where it sits). A change made at once has no frame in between; one
/// animated has some, and they stop when its time is up.
@MainActor
final class SwiftUIMotionProbe {
    let window: NSWindow
    let host: NSView

    init(_ view: some View, size: CGSize) {
        let root = view.frame(width: size.width, height: size.height, alignment: .top).background(Color.black)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = CGRect(origin: .zero, size: size)
        host = hosting
        window = NSWindow(contentRect: CGRect(x: 40, y: 40, width: size.width, height: size.height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFrontRegardless()
        settle(0.1)
    }

    func close() { window.orderOut(nil) }

    func settle(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    func snapshot() -> NSBitmapImageRep {
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    /// `measure` of each frame drawn for `seconds` after `change`.
    func frames(after change: () -> Void, for seconds: TimeInterval,
                measure: (NSBitmapImageRep) -> Double) -> [(t: TimeInterval, value: Double)] {
        change()
        let start = Date()
        var out: [(t: TimeInterval, value: Double)] = []
        while Date().timeIntervalSince(start) < seconds {
            RunLoop.current.run(until: Date().addingTimeInterval(0.006))
            out.append((Date().timeIntervalSince(start), measure(snapshot())))
        }
        return out
    }

    /// How much light the frame holds over its black: 0 nothing shows.
    static func light(_ rep: NSBitmapImageRep) -> Double {
        var sum = 0.0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let c = rep.colorAt(x: x, y: y) else { continue }
                sum += Double(max(c.redComponent, c.greenComponent, c.blueComponent))
            }
        }
        return sum
    }

}
