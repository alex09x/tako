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

/// The session sidebar's width: 280 pt as in the design (4a), dragged wider
/// or narrower by its right edge, remembered across launches.
enum SessionSidebarWidth {
    static let standard: CGFloat = 280
    static let range: ClosedRange<CGFloat> = 260...720
    static let defaultsKey = "TakoSessionSidebarWidth"

    static func clamped(_ width: CGFloat) -> CGFloat {
        min(max(width, range.lowerBound), range.upperBound)
    }
}

/// A thin strip on the sidebar's right edge: drag to resize, double-click
/// for the standard width. Shows the left-right resize cursor.
struct SessionSidebarResizeHandle: View {
    @Binding var width: Double
    @State private var dragStart: Double?

    var body: some View {
        Color.clear
            .frame(width: 6)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStart ?? width
                        dragStart = start
                        width = Double(SessionSidebarWidth.clamped(CGFloat(start) + value.translation.width))
                    }
                    .onEnded { _ in dragStart = nil }
            )
            .onTapGesture(count: 2) { width = Double(SessionSidebarWidth.standard) }
            .accessibilityLabel("Resize session sidebar")
    }
}
