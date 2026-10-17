/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import QuartzCore

/// The terminal's scrollbar in the brand's look: a thin Ember line on the
/// right edge, like the active tab's bar and the sidebar's resize edge. The
/// track is not drawn, but it still takes clicks across its whole width; the
/// line widens while the pointer is on it or drags it. Nothing is drawn when
/// there is nothing to scroll.
enum TerminalScrollbarStyle {
    static let ember = NSColor(srgbRed: 0xF4 / 255.0, green: 0x58 / 255.0, blue: 0x1C / 255.0, alpha: 1)
    /// The clickable track.
    static let trackWidth: CGFloat = 10
    static let restingWidth: CGFloat = 3
    static let activeWidth: CGFloat = 5
    /// Space between the line and the terminal's right edge.
    static let rightInset: CGFloat = 1.5

    static func knobColor(active: Bool) -> CGColor {
        ember.withAlphaComponent(active ? 1 : 0.7).cgColor
    }

    /// The line's frame in the track's coordinates.
    static func knobFrame(y: CGFloat, height: CGFloat, active: Bool) -> CGRect {
        let width = active ? activeWidth : restingWidth
        return CGRect(x: trackWidth - rightInset - width, y: y, width: width, height: height)
    }
}

extension TakoTerminalNSView {
    var isScrollbarActive: Bool { isDraggingScrollbar || isHoveringScrollbar }

    /// Shows the line at `y` with `height` in the track, styled for now.
    func placeScrollbarKnob(y: CGFloat, height: CGFloat) {
        let active = isScrollbarActive
        scrollbarKnob.isHidden = false
        scrollbarKnob.frame = TerminalScrollbarStyle.knobFrame(y: y, height: height, active: active)
        scrollbarKnob.cornerRadius = scrollbarKnob.frame.width / 2
        scrollbarKnob.backgroundColor = TerminalScrollbarStyle.knobColor(active: active)
    }

    /// Nothing to scroll: no line at all.
    func hideScrollbarKnob() {
        scrollbarKnob.isHidden = true
    }

    /// Whether the scrollbar takes a press or hover at `point` (view
    /// coordinates): only while its line shows. With nothing to scroll the
    /// track is not there, and the last columns under it are text again --
    /// a command-click on a link there opened nothing at all.
    func scrollbarTakesPointer(at point: CGPoint) -> Bool {
        !scrollbarKnob.isHidden && scrollbarLayer.frame.contains(point)
    }

    /// Whether a point in the track's coordinates is on the line's span:
    /// only its height counts, so the thin line is as easy to grab as the
    /// whole track is wide.
    func scrollbarKnobSpanContains(_ pointInTrack: CGPoint) -> Bool {
        !scrollbarKnob.isHidden
            && pointInTrack.y >= scrollbarKnob.frame.minY && pointInTrack.y <= scrollbarKnob.frame.maxY
    }
}
#endif
