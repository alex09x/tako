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
import CoreText


// The tab strip, drawn rather than native.
//
// The window's native tabbing is disallowed entirely (see TerminalWindow.swift)
// -- AppKit will not let its own tab bar stay hidden while a window can be
// tabbed at all, confirmed live (a reactive toggle turned into hundreds of
// thousands of calls a minute fighting it back on). `Tako.CustomTabGroup`
// owns membership/order/selection instead; this view just reads and draws it,
// and sits directly in the titlebar row (fullSizeContentView) the way Chrome
// does, rather than in a strip below it.

extension Tako {
    @MainActor
    final class TabBarView: NSView {
        /// Every number here is read from the spec doc's own CSS (Terminal
        /// UI.dc.html, "ТАБ-БАР — СПЕКА ДО ПИКСЕЛЯ"), not eyeballed off the
        /// rendered mockup -- e.g. the first-tab position is an explicit
        /// `margin-left:90px`, distinct from the traffic-light zone's own
        /// 78px width (a first pass conflated the two); tab padding is
        /// `0 8px 0 10px` (10 left, 8 right), not a symmetric 8.
        enum Metrics {
            static let barHeight: CGFloat = 38
            static let tabHeight: CGFloat = 28
            static let minTabWidth: CGFloat = 120
            /// Narrowest a tab can be and still show its close button beside
            /// the crab.
            static let compactTabWidth: CGFloat = tabPaddingLeft + crabSize + contentGap + closeSize + tabPaddingRight
            /// Narrowest a tab ever gets: its crab, whole, with its padding.
            /// Below this the crab and its badge would spill into the next tab.
            static let iconTabWidth: CGFloat = tabPaddingLeft + crabSize + tabPaddingRight
            static let maxTabWidth: CGFloat = 220
            static let firstTabX: CGFloat = 90
            static let tabPaddingLeft: CGFloat = 10
            static let tabPaddingRight: CGFloat = 8
            static let contentGap: CGFloat = 8
            static let crabSize: CGFloat = 16
            static let cornerRadius: CGFloat = 8
            static let activeBarHeight: CGFloat = 2
            static let closeSize: CGFloat = 16
            static let closeHitSize: CGFloat = 24
            /// Narrowest a pill tab can be and still show and hit-test its close button.
            static let pillCloseMinWidth: CGFloat = 54
            /// "кнопки справа 28×28, gap 4, отступ 8" -- three buttons (ⓘ
            /// about, ◫ split, + new tab).
            static let buttonCount: CGFloat = 3
            static let buttonSize: CGFloat = 28
            static let buttonRadius: CGFloat = 7
            static let buttonGap: CGFloat = 4
            static let buttonMarginRight: CGFloat = 8
            static let buttonY: CGFloat = (barHeight - buttonSize) / 2
            static let splitGlyphSize: CGFloat = 13
            static let plusGlyphSize: CGFloat = 15
            static let infoGlyphSize: CGFloat = 14
        }

        enum Palette {
            static let bar = NSColor(srgbRed: 0x14 / 255, green: 0x10 / 255, blue: 0x0E / 255, alpha: 1)
            static let activeTab = NSColor(srgbRed: 0x24 / 255, green: 0x1C / 255, blue: 0x16 / 255, alpha: 1)
            static let hoverTab = NSColor(srgbRed: 0x1F / 255, green: 0x19 / 255, blue: 0x15 / 255, alpha: 1)
            static let hairline = NSColor(srgbRed: 0x2A / 255, green: 0x21 / 255, blue: 0x1B / 255, alpha: 1)
            static let badge = NSColor(srgbRed: 0x35 / 255, green: 0x2B / 255, blue: 0x23 / 255, alpha: 1)
            static let activeText = NSColor(srgbRed: 0xFA / 255, green: 0xF7 / 255, blue: 0xF2 / 255, alpha: 1)
            static let inactiveText = NSColor(srgbRed: 0xB7 / 255, green: 0xAC / 255, blue: 0xA1 / 255, alpha: 1)
            static let dim = NSColor(srgbRed: 0x8A / 255, green: 0x7F / 255, blue: 0x76 / 255, alpha: 1)
            /// The lone-window title is AppKit chrome rather than brand.
            static let windowTitle = NSColor(srgbRed: 0xB8 / 255, green: 0xBC / 255, blue: 0xC2 / 255, alpha: 1)
        }

        enum Fonts {
            static let title = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            static let activeTitle = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
            static let pillTitle = Tako.LivingTokens.monoFont(size: 11.5, weight: .regular)
            static let pillActiveTitle = Tako.LivingTokens.monoFont(size: 11.5, weight: .medium)
            static let timer = Tako.LivingTokens.monoFont(size: 10, weight: .regular)
            static let badge = Tako.LivingTokens.monoFont(size: 10, weight: .medium)
            static let loneTitle = NSFont.systemFont(ofSize: 13, weight: .semibold)
        }

        /// One drawn tab and the window behind it.
        struct Tab {
            let window: NSWindow
            let frame: CGRect
            let isActive: Bool
            let index: Int
        }

        var tabs: [Tab] = []
        var cachedAccessibilityChildren: [NSAccessibilityElement] = []
        /// How many tabs the strip last laid out (0 in single-window mode).
        var laidOutTabCount: Int { tabs.count }
        /// Where tabs are drawn and clicked; ones scrolled past it are not.
        var stripRect: CGRect = .zero
        var hovered: Int?
        var hoveredClose = false
        var plusHovered = false
        var splitHovered = false
        var infoHovered = false
        /// Command-number badges show only while the key is actually held,
        /// after a beat, so they do not flash during ordinary shortcuts.
        var showingBadges = false
        var badgeWork: DispatchWorkItem?
        var tracking: NSTrackingArea?

        var draggingTabIndex: Int?
        weak var draggingWindow: NSWindow?
        var dragStartPoint: CGPoint?
        var isTabDragging: Bool = false
        var paintedPillDots: [ObjectIdentifier: String] = [:]
        var paintedRingStates: [ObjectIdentifier: SurfaceState] = [:]
        var statusLayers: [ObjectIdentifier: TabStatusLayer] = [:]

        override var isFlipped: Bool { false }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            wantsLayer = true
            layer?.masksToBounds = false
            superview?.wantsLayer = true
            superview?.layer?.masksToBounds = false
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
            true
        }

        override var mouseDownCanMoveWindow: Bool {
            false
        }

        var group: CustomTabGroup? { window.map { Tako.CustomTabGroup.group(for: $0) } }
        var windows: [NSWindow] { group?.visibleWindows ?? [] }
        /// A single window in pill style shows a pill tab (the "бублик").
        /// In classic style, a single window shows no strip -- just its title, centred.
        var showsStrip: Bool {
            switch effectiveTabStyle {
            case .pill:
                return !windows.isEmpty
            case .classic:
                return windows.count > 1
            }
        }

        var workspaceHovered = false
        var showsWorkspacePill: Bool {
            true
        }

        /// Override tab presentation style for tests and dynamic previews.
        var styleOverride: Tako.Config.TabStyle?
        var workspaceStoreOverride: WorkspaceStore?
        var effectiveWorkspaceStore: WorkspaceStore { workspaceStoreOverride ?? .shared }

        /// Effective tab presentation style.
        var effectiveTabStyle: Tako.Config.TabStyle {
            styleOverride ?? (NSApplication.shared.delegate as? AppDelegate)?.tako.config.tabStyle ?? .default
        }

        var workspacePillRect: CGRect {
            guard showsWorkspacePill else { return .zero }
            let ws = effectiveWorkspaceStore.activeWorkspace
            let title = ws.name
            let titleWidth = TabText.width(of: title, font: Fonts.badge)
            let attention = workspaceAttentionCount(for: ws)
            let pillWidth = min(140, max(54, 8 + 7 + 6 + titleWidth + (attention > 0 ? 22 : 0) + 9))
            return CGRect(x: 84, y: Metrics.buttonY, width: pillWidth, height: Metrics.buttonSize)
        }

        var effectiveFirstTabX: CGFloat {
            showsWorkspacePill ? workspacePillRect.maxX + 6 : Metrics.firstTabX
        }

        /// "кнопки справа 28×28, gap 4, отступ 8": + is rightmost (window
        /// edge minus the 8px margin), ◫ sits 4px to its left, ⓘ sits 4px to the left of ◫.
        var plusRect: CGRect {
            CGRect(x: bounds.width - Metrics.buttonMarginRight - Metrics.buttonSize,
                   y: Metrics.buttonY, width: Metrics.buttonSize, height: Metrics.buttonSize)
        }

        var splitRect: CGRect {
            CGRect(x: plusRect.minX - Metrics.buttonGap - Metrics.buttonSize,
                   y: Metrics.buttonY, width: Metrics.buttonSize, height: Metrics.buttonSize)
        }

        var infoRect: CGRect {
            CGRect(x: splitRect.minX - Metrics.buttonGap - Metrics.buttonSize,
                   y: Metrics.buttonY, width: Metrics.buttonSize, height: Metrics.buttonSize)
        }

        func refresh() {
            needsDisplay = true
        }

        // MARK: Layout

        /// Right edge reserved for buttons: ⓘ info, ◫ split, + new tab.
        var buttonsReservedWidth: CGFloat {
            Metrics.buttonSize * Metrics.buttonCount + Metrics.buttonGap * (Metrics.buttonCount - 1) + Metrics.buttonMarginRight
        }

        /// "ширина: по контенту, clamp 120-220px. НИКОГДА не justify на
        /// всю ширину бара" -- each tab is sized to its own content, not an
        /// equal share of whatever space is left.
        private func naturalWidth(for window: NSWindow) -> CGFloat {
            if effectiveTabStyle == .pill {
                let isSelected = (group?.selectedWindow ?? self.window) === window
                let titleFont = isSelected ? Fonts.pillActiveTitle : Fonts.pillTitle
                let title = titleFor(window)
                let titleWidth = TabText.width(of: title, font: titleFont)
                let metaText = pillMetaText(for: window)
                let metaExtra = metaText.map { 7 + TabText.width(of: $0, font: Fonts.timer) } ?? 0
                let state = pillSurfaceState(for: window)
                let rightExtra: CGFloat = isSelected
                    ? (7 + 10)
                    : ((hasUnreadInWindow(window) || state == .failed) ? (7 + 5) : 0)
                // §4: padding-left 8 -> ring S=14 -> gap 7 -> title -> (gap 7 + meta) -> rightExtra -> padding-right 9
                let needed = 8 + 14 + 7 + titleWidth + metaExtra + rightExtra + 9
                return min(Metrics.maxTabWidth, max(Metrics.minTabWidth, ceil(needed)))
            }
            let title = titleFor(window)
            var width = Metrics.tabPaddingLeft + Metrics.crabSize + Metrics.contentGap
            width += TabText.width(of: title, font: Fonts.title)
            if let timer = elapsedFor(window) {
                width += Metrics.contentGap + TabText.width(of: timer, font: Fonts.timer)
            }
            width += Metrics.tabPaddingRight
            return min(Metrics.maxTabWidth, max(Metrics.minTabWidth, width))
        }

        func layoutTabs() {
            tabs = []
            guard showsStrip else { return }
            let all = windows
            if all.count <= 1 && showingBadges {
                showingBadges = false
            }
            let selected = group?.selectedWindow ?? window
            let startX = effectiveFirstTabX
            let available = bounds.width - startX - buttonsReservedWidth
            let natural = all.map(naturalWidth(for:))
            let isPill = effectiveTabStyle == .pill

            let preferredGap: CGFloat = isPill ? 6 : 0
            let availableForGaps = available - CGFloat(all.count) * Metrics.iconTabWidth
            let gap: CGFloat = (all.count > 1 && preferredGap > 0)
                ? max(0, min(preferredGap, availableForGaps / CGFloat(all.count - 1)))
                : 0

            let totalGaps = CGFloat(max(0, all.count - 1)) * gap
            let naturalSum = natural.reduce(0, +)
            let totalNatural = naturalSum + totalGaps
            let widths: [CGFloat]
            if totalNatural <= available || all.isEmpty || naturalSum <= 0 {
                widths = natural
            } else {
                let availableForTabs = max(0, available - totalGaps)
                let scale = availableForTabs / naturalSum
                widths = natural.map { max(Metrics.iconTabWidth, floor($0 * scale)) }
            }

            let tabHeight = isPill ? Metrics.buttonSize : Metrics.tabHeight
            let tabY = isPill ? Metrics.buttonY : 0
            stripRect = CGRect(x: startX, y: 0, width: max(0, available), height: bounds.height)
            var x = startX - Self.scrollOffset(
                widths: widths,
                gap: gap,
                selected: all.firstIndex { $0 === selected },
                available: available)
            for (index, candidate) in all.enumerated() {
                let width = widths[index]
                tabs.append(Tab(
                    window: candidate,
                    frame: CGRect(x: x, y: tabY, width: width, height: tabHeight),
                    isActive: candidate === selected,
                    index: index))
                x += width + gap
            }
        }

        /// How far the row scrolls left so the selected tab is in view: none
        /// while everything fits, otherwise just enough to show the selected
        /// tab's right edge, and never past the last tab.
        static func scrollOffset(widths: [CGFloat], gap: CGFloat = 0, selected: Int?, available: CGFloat) -> CGFloat {
            guard !widths.isEmpty else { return 0 }
            let total = widths.reduce(0, +) + CGFloat(max(0, widths.count - 1)) * gap
            guard total > available, let selected else { return 0 }
            let selectedEnd = widths[...selected].reduce(0, +) + CGFloat(selected) * gap
            return min(max(0, selectedEnd - available), total - available)
        }

        // MARK: Drawing

        override func draw(_ dirtyRect: NSRect) {
            if let window { Tako.TabBarController.clearTitlebarBackground(in: window) }
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            ctx.setFillColor(Palette.bar.cgColor)
            ctx.fill(bounds)
            ctx.setFillColor(Palette.hairline.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: bounds.width, height: 1))

            drawWorkspacePill(in: ctx)

            guard showsStrip else {
                tabs = []
                stripRect = .zero
                hovered = nil
                hoveredClose = false
                syncStatusLayers(visibleTabIds: [])
                drawLoneTitle()
                drawButtons(in: ctx)
                return
            }
            layoutTabs()
            ctx.saveGState()
            ctx.clip(to: stripRect)
            var visibleTabIds: Set<ObjectIdentifier> = []
            for tab in tabs where tab.frame.intersects(stripRect) {
                visibleTabIds.insert(ObjectIdentifier(tab.window))
                drawTab(tab, in: ctx)
            }
            ctx.restoreGState()
            syncStatusLayers(visibleTabIds: visibleTabIds)
            if let w = window {
                let style = progressStyle(for: w)
                if style.showsInWindow && !style.showsInTab, let prog = aggregateProgress(for: w) {
                    drawProgressBar(in: bounds, progress: prog, context: ctx)
                }
            }
            drawButtons(in: ctx)
        }

    }
}

