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
            static let timer = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
            static let badge = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
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

        override var isFlipped: Bool { false }

        var group: CustomTabGroup? { window.map { Tako.CustomTabGroup.group(for: $0) } }
        var windows: [NSWindow] { group?.visibleWindows ?? [] }
        /// A single window shows no strip -- just its title, centred. There
        /// is no such thing as an empty bar.
        var showsStrip: Bool { windows.count > 1 }

        var workspaceHovered = false
        var showsWorkspacePill: Bool {
            WorkspaceStore.shared.workspaces.count > 1 || WorkspaceStore.shared.activeWorkspace.name != "Default"
        }

        var workspacePillRect: CGRect {
            guard showsWorkspacePill else { return .zero }
            let ws = WorkspaceStore.shared.activeWorkspace
            let title = ws.name
            let titleWidth = TabText.width(of: title, font: Fonts.badge)
            let attention = WorkspaceStore.shared.attentionCount(for: ws)
            let pillWidth = min(140, max(54, 8 + 8 + 6 + titleWidth + (attention > 0 ? 20 : 0) + 8))
            return CGRect(x: 84, y: Metrics.buttonY, width: pillWidth, height: Metrics.buttonSize)
        }

        var effectiveFirstTabX: CGFloat {
            showsWorkspacePill ? workspacePillRect.maxX + 8 : Metrics.firstTabX
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
        private var buttonsReservedWidth: CGFloat {
            Metrics.buttonSize * Metrics.buttonCount + Metrics.buttonGap * (Metrics.buttonCount - 1) + Metrics.buttonMarginRight
        }

        /// "ширина: по контенту, clamp 120-220px. НИКОГДА не justify на
        /// всю ширину бара" -- each tab is sized to its own content, not an
        /// equal share of whatever space is left. A first pass divided
        /// space evenly instead, which read as visibly wrong: three short
        /// titles all stretched out with dead air around them.
        private func naturalWidth(for window: NSWindow) -> CGFloat {
            let title = titleFor(window)
            var width = Metrics.tabPaddingLeft + Metrics.crabSize + Metrics.contentGap
            width += TabText.width(of: title, font: Fonts.title)
            if let timer = elapsedFor(window) {
                width += Metrics.contentGap + TabText.width(of: timer, font: Fonts.timer)
            }
            width += Metrics.tabPaddingRight
            return min(Metrics.maxTabWidth, max(Metrics.minTabWidth, width))
        }

        private func layoutTabs() {
            tabs = []
            guard showsStrip else { return }
            let all = windows
            let selected = group?.selectedWindow
            let startX = effectiveFirstTabX
            let available = bounds.width - startX - buttonsReservedWidth
            let natural = all.map(naturalWidth(for:))

            // Only when the natural widths genuinely don't fit do tabs give
            // up room evenly (down to the 120px floor) rather than each
            // keeping its own content width -- see "тесно: равномерно
            // жмутся до 120" in the spec. Past that they keep shrinking to
            // the icon width (crab only), and when even that doesn't fit the
            // row scrolls to keep the selected tab in view. Stopping at 120
            // with no scrolling drew the seventh tab of a 900pt window under
            // the buttons, as if no more than six could be opened.
            let totalNatural = natural.reduce(0, +)
            let widths: [CGFloat]
            if totalNatural <= available || all.isEmpty {
                widths = natural
            } else {
                let shrunk = max(Metrics.iconTabWidth, available / CGFloat(all.count))
                widths = all.map { _ in shrunk }
            }

            stripRect = CGRect(x: startX, y: 0, width: max(0, available), height: Metrics.tabHeight)
            var x = startX - Self.scrollOffset(
                widths: widths,
                selected: all.firstIndex { $0 === selected },
                available: available)
            for (index, candidate) in all.enumerated() {
                let width = widths[index]
                tabs.append(Tab(
                    window: candidate,
                    frame: CGRect(x: x, y: 0, width: width, height: Metrics.tabHeight),
                    isActive: candidate === selected,
                    index: index))
                x += width
            }
        }

        /// How far the row scrolls left so the selected tab is in view: none
        /// while everything fits, otherwise just enough to show the selected
        /// tab's right edge, and never past the last tab.
        static func scrollOffset(widths: [CGFloat], selected: Int?, available: CGFloat) -> CGFloat {
            let total = widths.reduce(0, +)
            guard total > available, let selected else { return 0 }
            let selectedEnd = widths[...selected].reduce(0, +)
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
                // Down to one window: forget the strip, or a click where it
                // was would still be taken as a tab click instead of a drag
                // of the title bar.
                tabs = []
                stripRect = .zero
                hovered = nil
                hoveredClose = false
                drawLoneTitle()
                drawButtons(in: ctx)
                return
            }
            layoutTabs()
            ctx.saveGState()
            ctx.clip(to: stripRect)
            for tab in tabs where tab.frame.intersects(stripRect) { drawTab(tab, in: ctx) }
            ctx.restoreGState()
            if let w = window {
                let style = progressStyle(for: w)
                if style.showsInWindow && !style.showsInTab, let prog = aggregateProgress(for: w) {
                    drawProgressBar(in: bounds, progress: prog, context: ctx)
                }
            }
            drawButtons(in: ctx)
        }

        // MARK: Input

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
                owner: self)
            addTrackingArea(area)
            tracking = area
        }

        override func mouseMoved(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            // Do NOT call layoutTabs() here: it calls NSString.sizeWithAttributes
            // which crashes in CoreText when invoked outside a draw pass
            // (SIGABRT in TAttributes::ApplyFont, seen in TakoCore-2026-08-06*.ips).
            // The tabs array is kept current by draw(), which is always called
            // before user interaction reaches us.
            let previousTab = hovered
            let previousPlus = plusHovered
            let previousSplit = splitHovered
            let previousInfo = infoHovered
            let previousWorkspace = workspaceHovered
            workspaceHovered = showsWorkspacePill && workspacePillRect.contains(point)
            hovered = stripRect.contains(point) ? tabs.first { $0.frame.contains(point) }?.index : nil
            hoveredClose = hovered.map { closeRect(of: tabs[$0]).contains(point) } ?? false
            plusHovered = plusRect.contains(point)
            splitHovered = splitRect.contains(point)
            infoHovered = infoRect.contains(point)

            if workspaceHovered {
                let ws = WorkspaceStore.shared.activeWorkspace
                let count = WorkspaceStore.shared.attentionCount(for: ws)
                toolTip = "Project Workspace: \(ws.name)\(count > 0 ? " (\(count) needing attention)" : "") — Click to switch"
            } else if infoHovered {
                let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
                toolTip = v.isEmpty ? "About Tako" : "About Tako (v\(v))"
            } else if splitHovered {
                toolTip = "Split Terminal Right (⌘D)"
            } else if plusHovered {
                toolTip = "New Tab (⌘T)"
            } else {
                toolTip = nil
            }

            if hovered != previousTab || plusHovered != previousPlus || splitHovered != previousSplit || infoHovered != previousInfo || workspaceHovered != previousWorkspace {
                needsDisplay = true
            }
        }

        override func mouseExited(with event: NSEvent) {
            hovered = nil
            plusHovered = false
            splitHovered = false
            infoHovered = false
            workspaceHovered = false
            toolTip = nil
            needsDisplay = true
        }

        /// The close button's hit area is larger than the glyph.
        private func closeRect(of tab: Tab) -> CGRect {
            // No close button is drawn on a tab this narrow, so none is hit.
            guard tab.frame.width >= Metrics.compactTabWidth else { return .null }
            let inset = (Metrics.closeHitSize - Metrics.closeSize) / 2
            return CGRect(x: tab.frame.maxX - Metrics.tabPaddingRight - Metrics.closeSize - inset,
                          y: tab.frame.midY - Metrics.closeHitSize / 2,
                          width: Metrics.closeHitSize, height: Metrics.closeHitSize)
        }

        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            // Same as mouseMoved: use the cached tabs from the last draw() pass.
            if showsWorkspacePill && workspacePillRect.contains(point) {
                showWorkspaceMenu(at: point)
                return
            }
            if infoRect.contains(point) {
                NSApp.sendAction(#selector(AppDelegate.showAbout(_:)), to: nil, from: self)
                return
            }
            if plusRect.contains(point) {
                NSApp.sendAction(#selector(TerminalController.newTab(_:)), to: nil, from: self)
                return
            }
            if splitRect.contains(point) {
                NSApp.sendAction(#selector(BaseTerminalController.splitRight(_:)), to: nil, from: self)
                return
            }
            guard showsStrip, stripRect.contains(point), let tab = tabs.first(where: { $0.frame.contains(point) }) else {
                // Empty bar: drag the window, or zoom it on a double click.
                if event.clickCount == 2 {
                    window?.performZoom(nil)
                } else {
                    window?.performDrag(with: event)
                }
                return
            }
            if closeRect(of: tab).contains(point) {
                let controller = (tab.window.windowController as? TerminalController)
                    ?? (tab.window.delegate as? TerminalController)
                if let controller {
                    if controller.surfaceTree.contains(where: { $0.needsConfirmClose }) {
                        group?.select(tab.window)
                    }
                    controller.closeTab(self)
                } else {
                    tab.window.performClose(nil)
                }
            } else {
                group?.select(tab.window)
            }
        }

        /// Show the command-number badges while the key is held.
        func commandKeyChanged(held: Bool) {
            badgeWork?.cancel()
            guard held else {
                if showingBadges {
                    showingBadges = false
                    needsDisplay = true
                }
                return
            }
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.showingBadges = true
                self.needsDisplay = true
            }
            badgeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
    }
}
