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

    /// The width the sidebar has now, as the user left it. The terminal
    /// beside it is sized from this; a guess here pushes the terminal's
    /// right edge, its scrollbar with it, out of the window.
    static func current(in defaults: UserDefaults = .tako) -> CGFloat {
        let stored = defaults.object(forKey: defaultsKey) as? Double
        return clamped(stored.map { CGFloat($0) } ?? standard)
    }
}

/// A thin strip on the sidebar's right edge: drag to resize, double-click
/// for the standard width. Shows the left-right resize cursor.
struct SessionSidebarResizeHandle: View {
    @Binding var width: Double
    @State private var dragStart: Double?
    @State private var isHovered = false

    /// The strip that takes the drag, inside the sidebar's edge: the
    /// terminal beside it is an AppKit view and takes every click over it.
    static let hitWidth: CGFloat = 10

    var body: some View {
        Color.clear
            .frame(width: Self.hitWidth)
            .overlay(alignment: .trailing) {
                // The edge lights up in Ember while it can be dragged, as the
                // active row's bar does.
                Rectangle()
                    .fill(Color(nsColor: Tako.LivingTokens.ember))
                    .frame(width: 2)
                    .opacity(isHovered || dragStart != nil ? 1 : 0)
                    .animation(.easeOut(duration: 0.12), value: isHovered || dragStart != nil)
            }
            .contentShape(Rectangle())
            .onHover { inside in
                isHovered = inside
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
