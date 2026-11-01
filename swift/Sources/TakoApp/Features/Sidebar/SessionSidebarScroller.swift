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

/// Keep AppKit's scroll and drag behavior, but draw only a quiet thumb.
final class SessionSidebarScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func drawKnob() {
        var knob = rect(for: .knob).insetBy(dx: 0, dy: 2)
        guard knob.width > 0, knob.height > 0 else { return }
        knob.origin.x = bounds.midX - 1.5
        knob.size.width = 3
        Tako.LivingTokens.dim.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: knob, xRadius: 1.5, yRadius: 1.5).fill()
    }
}

/// Configures only the scroll view that contains the session list.
struct SessionSidebarScrollerInstaller: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }

    func updateNSView(_ view: Probe, context: Context) { view.install() }

    final class Probe: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            install()
            DispatchQueue.main.async { [weak self] in self?.install() }
        }

        func install() {
            guard let scroll = enclosingScrollView else { return }
            if !(scroll.verticalScroller is SessionSidebarScroller) {
                scroll.verticalScroller = SessionSidebarScroller()
            }
            if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
            if !scroll.hasVerticalScroller { scroll.hasVerticalScroller = true }
            if !scroll.autohidesScrollers { scroll.autohidesScrollers = true }
        }
    }
}
