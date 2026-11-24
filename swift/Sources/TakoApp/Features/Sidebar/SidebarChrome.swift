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

/// What a sidebar style does to the sidebar around its rows: the search
/// field, the All / Needs you segments, the workspace headings and the row's
/// shape. From the approved design (sidebar-variants.css); Classic is the
/// reference sidebar as it is.
struct SidebarChromeMetrics: Equatable {
    let searchHeight: CGFloat
    let searchHorizontalMargin: CGFloat
    let searchTop: CGFloat
    let searchBottom: CGFloat
    /// Classic and Compact fill the field; Minimal only outlines it.
    let searchFilled: Bool
    let segmentHeight: CGFloat
    let segmentFontSize: CGFloat
    let headingFont: NSFont
    let headingUppercased: Bool
    let headingTracking: CGFloat
    let headingTop: CGFloat
    let headingColor: NSColor
    let rowRadius: CGFloat
    let rowLeading: CGFloat
    let rowTrailing: CGFloat

    static func of(_ style: SidebarStyle) -> SidebarChromeMetrics {
        typealias T = Tako.LivingTokens
        switch style {
        case .classic:
            return .init(searchHeight: 28, searchHorizontalMargin: 10, searchTop: 2, searchBottom: 0, searchFilled: true,
                         segmentHeight: 24, segmentFontSize: 11,
                         headingFont: T.monoFont(size: 10.5, weight: .semibold), headingUppercased: true, headingTracking: 0.8,
                         headingTop: 10, headingColor: T.dim, rowRadius: 8, rowLeading: 4, rowTrailing: 6)
        case .minimal:
            // .sb-search{margin:4px 12px 10px; transparent, outlined} .ws{500 11.5 interface font, mute, margin-top 18}
            // .row{radius 9; padding 7 10 7 6}; the segments are hidden.
            return .init(searchHeight: 28, searchHorizontalMargin: 12, searchTop: 4, searchBottom: 4, searchFilled: false,
                         segmentHeight: 24, segmentFontSize: 11,
                         headingFont: .systemFont(ofSize: 11.5, weight: .medium), headingUppercased: false, headingTracking: 0,
                         headingTop: 18, headingColor: T.faint, rowRadius: 9, rowLeading: 6, rowTrailing: 10)
        case .compact:
            // .sb-search{height 24; margin 2 8 6} .seg{height 20; 10px} .ws{20 high, 9.5px, margin-top 8} .row{radius 4; 2 6 2 2}
            return .init(searchHeight: 24, searchHorizontalMargin: 8, searchTop: 2, searchBottom: 0, searchFilled: true,
                         segmentHeight: 20, segmentFontSize: 10,
                         headingFont: T.monoFont(size: 9.5, weight: .semibold), headingUppercased: true, headingTracking: 0.8,
                         headingTop: 8, headingColor: T.dim, rowRadius: 4, rowLeading: 2, rowTrailing: 6)
        }
    }

    /// The All / Needs you segments: hidden in Minimal, and grouped by
    /// status, where Needs you is already the first group.
    static func showsSegments(style: SidebarStyle, grouping: SidebarGrouping) -> Bool {
        style != .minimal && grouping != .status
    }
}

extension SessionSidebarStore {
    /// Where the All / Needs you segments are hidden (Minimal, grouped by
    /// status), a Needs-you filter set before would go on hiding sessions with
    /// nothing on screen to say so or to clear it: it is cleared. The text
    /// search stays as it is.
    func dropHiddenAttentionFilter(_ preferences: DesktopPreferences, for window: NSWindow?) {
        guard !SidebarChromeMetrics.showsSegments(style: preferences.sidebarStyle, grouping: preferences.sidebarGrouping),
              filterNeedsAttention(for: window) else { return }
        setFilterNeedsAttention(false, for: window)
    }
}

extension DesktopPreferences {
    /// Everything that changes how the sidebar's rows are drawn, as one
    /// value: the list is built anew when it changes.
    var sidebarLook: String { "\(sidebarStyle)-\(sidebarGrouping)-\(sidebarTextSize)-\(sidebarSecondaryText)" }
}

private struct SidebarStyleKey: EnvironmentKey {
    static let defaultValue = SidebarStyle.classic
}

extension EnvironmentValues {
    /// The sidebar's style, for the parts drawn away from the list itself
    /// (workspace headings).
    var sidebarStyle: SidebarStyle {
        get { self[SidebarStyleKey.self] }
        set { self[SidebarStyleKey.self] = newValue }
    }
}
