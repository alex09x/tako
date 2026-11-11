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
    private let secondLine: (Tako.SurfaceState) -> Bool

    /// Where the second line starts: chevron 12 + gap + ring 14 (33 in the reference).
    var secondLineIndent: CGFloat { 12 + gap + 14 }

    func showsSecondLine(for state: Tako.SurfaceState) -> Bool { secondLine(state) }

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
                         inlineSecondLine: false, showsTreeLines: false,
                         secondLine: { $0 == .waiting || $0 == .failed || $0 == .offline })
        case .compact:
            // One small line; what is happening sits on the right, only while something happens.
            return .init(titleFont: T.monoFont(size: 11.5, weight: .medium), metaFont: T.monoFont(size: 10, weight: .regular),
                         childFont: T.monoFont(size: 11, weight: .regular), gap: 5, titleHeight: 16, secondLineHeight: 13,
                         rowVerticalPadding: 2, childVerticalPadding: 1, childIndent: 30,
                         inlineSecondLine: true, showsTreeLines: false, secondLine: { $0 != .idle })
        }
    }
}
