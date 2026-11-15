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

/// How the sidebar dresses its rows (`sidebar-style`). Only the look changes:
/// every row does the same things in every style. Classic is the reference
/// sidebar (4a); the design's Minimal and Compact are the others
/// (Desktop Prototype, CHANGELOG 2026-11-11 (3)/(4)).
enum SidebarStyle: String, CaseIterable, Sendable {
    case classic, minimal, compact
}

/// How the sidebar groups its sessions (`sidebar-group`): under their
/// workspaces, or by what they need -- Needs you, Running, Done, Quiet --
/// with the workspace a coloured dot on the row.
enum SidebarGrouping: String, CaseIterable, Sendable {
    case workspace, status
}

/// How large the sidebar's text is (`sidebar-text-size`), relative to the style.
enum SidebarTextSize: String, CaseIterable, Sendable {
    case small, standard = "default", large
    var scale: CGFloat {
        switch self { case .small: 0.9; case .standard: 1; case .large: 1.15 }
    }
}

/// How strongly the second line reads (`sidebar-secondary-text`): folders,
/// branches, ports, a quiet program. A waiting question and an error keep
/// their status colours at every setting.
enum SidebarSecondaryText: String, CaseIterable, Sendable {
    case soft, standard = "default", strong
    var color: NSColor {
        typealias T = Tako.LivingTokens
        switch self { case .soft: return T.faint; case .standard: return T.dim; case .strong: return T.textInactive }
    }
}

/// The sizes and choices a style makes for a row.
struct SidebarRowMetrics {
    let titleFont: NSFont
    let metaFont: NSFont
    let childFont: NSFont
    /// Between the chevron, the ring and the title.
    let gap: CGFloat
    let titleHeight: CGFloat
    let secondLineHeight: CGFloat
    let rowVerticalPadding: CGFloat
    let childVerticalPadding: CGFloat
    let childIndent: CGFloat
    /// The second line sits to the right of the title instead of under it.
    let inlineSecondLine: Bool
    let showsTreeLines: Bool
    /// The status ring drawn smaller about its centre (.ring in the design: .78 / .8).
    var ringScale: CGFloat = 1
    /// A pane row's number tag (`.kid .tag`), hidden in Minimal.
    var showsChildTag = true
    /// A pane row's corner radius (`.kid`): 6, Compact's 4.
    var childRadius: CGFloat = 6
    /// Outside a row (`.row`/`.kid` margin): 1 above and below, 8 at the
    /// side; Compact's rows touch (0) and sit 6 in.
    var rowMarginVertical: CGFloat = 1
    var rowMarginHorizontal: CGFloat = 8
    /// Inside a pane row at the sides (`.kid` padding): 8, Compact's 6.
    var childHorizontalPadding: CGFloat = 8
    private let secondLine: (Tako.SurfaceState) -> Bool

    /// Where the second line starts: chevron 12 + gap + ring 14 (33 in the reference).
    var secondLineIndent: CGFloat { 12 + gap + 14 }

    func showsSecondLine(for state: Tako.SurfaceState) -> Bool { secondLine(state) }

    /// The style's metrics at a text size: type and line heights grow with
    /// it, gaps and indents stay. At 1 the style is exactly itself.
    static func of(_ style: SidebarStyle, textScale s: CGFloat) -> SidebarRowMetrics {
        let m = of(style)
        guard s != 1 else { return m }
        func font(_ f: NSFont) -> NSFont { f.withSize((f.pointSize * s * 2).rounded() / 2) }
        return .init(titleFont: font(m.titleFont), metaFont: font(m.metaFont), childFont: font(m.childFont), gap: m.gap,
                     titleHeight: (m.titleHeight * s).rounded(), secondLineHeight: (m.secondLineHeight * s).rounded(),
                     rowVerticalPadding: m.rowVerticalPadding, childVerticalPadding: m.childVerticalPadding,
                     childIndent: m.childIndent, inlineSecondLine: m.inlineSecondLine, showsTreeLines: m.showsTreeLines,
                     ringScale: m.ringScale, showsChildTag: m.showsChildTag, childRadius: m.childRadius,
                     rowMarginVertical: m.rowMarginVertical, rowMarginHorizontal: m.rowMarginHorizontal,
                     childHorizontalPadding: m.childHorizontalPadding, secondLine: m.secondLine)
    }

    static func of(_ style: SidebarStyle) -> SidebarRowMetrics {
        typealias T = Tako.LivingTokens
        switch style {
        case .classic:
            // Reference A01 `.row`: title 12.5/500, meta 11, pane rows 11.5, 7 pt gaps.
            return .init(titleFont: T.monoFont(size: 12.5, weight: .medium), metaFont: T.monoFont(size: 11, weight: .regular),
                         childFont: T.monoFont(size: 11.5, weight: .regular), gap: 7, titleHeight: 18, secondLineHeight: 14,
                         rowVerticalPadding: 6, childVerticalPadding: 4, childIndent: 40,
                         inlineSecondLine: false, showsTreeLines: true, secondLine: { _ in true })
        case .minimal:
            // One line unless the session needs you or lost its connection; the interface font; more air.
            return .init(titleFont: .systemFont(ofSize: 13.5, weight: .medium), metaFont: .systemFont(ofSize: 12),
                         childFont: .systemFont(ofSize: 12.5), gap: 9, titleHeight: 20, secondLineHeight: 16,
                         rowVerticalPadding: 7, childVerticalPadding: 4, childIndent: 40,
                         inlineSecondLine: false, showsTreeLines: false, ringScale: 0.78, showsChildTag: false,
                         secondLine: { $0 == .waiting || $0 == .failed || $0 == .offline })
        case .compact:
            // One small line; what is happening sits on the right, only while something happens.
            // .row{margin 0 6; padding 2 inside the 1 pt border} .l1{18 high}: 24 a row, as Classic's 46 counts
            // its border; .kid{margin 0 6 0 30; padding 1 6}.
            return .init(titleFont: T.monoFont(size: 11.5, weight: .medium), metaFont: T.monoFont(size: 10, weight: .regular),
                         childFont: T.monoFont(size: 11, weight: .regular), gap: 5, titleHeight: 18, secondLineHeight: 13,
                         rowVerticalPadding: 3, childVerticalPadding: 1, childIndent: 30,
                         inlineSecondLine: true, showsTreeLines: false, ringScale: 0.8, childRadius: 4,
                         rowMarginVertical: 0, rowMarginHorizontal: 6, childHorizontalPadding: 6,
                         secondLine: { $0 != .idle })
        }
    }
}
