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
    /// Text layout for the drawn tab strip.
    ///
    /// `NSString.size(withAttributes:)` asks CoreText to discover fallback
    /// fonts. On macOS 15 that path can raise an Objective-C exception when a
    /// rapidly changing OSC title contains a glyph missing from SF Mono (the
    /// braille spinner used by several CLI tools is one example). Objective-C
    /// exceptions cannot be caught by Swift, so one title used to terminate
    /// the whole application.
    ///
    /// Resolve unsupported graphemes ourselves, then measure and draw glyphs
    /// directly. This avoids both the fallback-font dictionary and repeated
    /// attributed-string layout in every title-bar draw pass.
    @MainActor
    enum TabText {
        static let replacement = "?"

        static func displayText(_ text: String, font: NSFont) -> String {
            var result = ""
            text.enumerateSubstrings(
                in: text.startIndex..<text.endIndex,
                options: .byComposedCharacterSequences
            ) { substring, _, _, _ in
                guard let substring else { return }
                result += hasGlyphs(for: substring, font: font) ? substring : replacement
            }
            return result
        }

        static func width(of text: String, font: NSFont) -> CGFloat {
            glyphRun(for: text, font: font).width
        }

        static func height(for font: NSFont) -> CGFloat {
            ceil(font.ascender - font.descender + font.leading)
        }

        static func truncate(_ text: String, to maxWidth: CGFloat, font: NSFont) -> String {
            guard maxWidth > 0 else { return "" }
            let safe = displayText(text, font: font)
            guard width(of: safe, font: font) > maxWidth else { return safe }

            let ellipsis = hasGlyphs(for: "\u{2026}", font: font) ? "\u{2026}" : "..."
            let ellipsisWidth = width(of: ellipsis, font: font)
            guard ellipsisWidth <= maxWidth else { return "" }

            var result = ""
            for character in safe {
                let candidate = result + String(character)
                if width(of: candidate, font: font) + ellipsisWidth > maxWidth { break }
                result = candidate
            }
            return result + ellipsis
        }

        @discardableResult
        static func draw(
            _ text: String,
            atX x: CGFloat,
            centeredAtY centerY: CGFloat,
            font: NSFont,
            color: NSColor,
            context: CGContext
        ) -> CGFloat {
            let run = glyphRun(for: text, font: font)
            guard !run.glyphs.isEmpty else { return 0 }

            let baseline = centerY - (font.ascender + font.descender) / 2
            var positions: [CGPoint] = []
            positions.reserveCapacity(run.glyphs.count)
            var cursor = x
            for advance in run.advances {
                positions.append(CGPoint(x: cursor, y: baseline))
                cursor += advance.width
            }

            context.saveGState()
            context.textMatrix = .identity
            context.setFillColor(color.cgColor)
            CTFontDrawGlyphs(font as CTFont, run.glyphs, positions, run.glyphs.count, context)
            context.restoreGState()
            return run.width
        }

        private struct GlyphRun {
            let glyphs: [CGGlyph]
            let advances: [CGSize]
            let width: CGFloat
        }

        private static func hasGlyphs(for text: String, font: NSFont) -> Bool {
            let characters = Array(text.utf16)
            guard !characters.isEmpty else { return true }
            var glyphs = [CGGlyph](repeating: 0, count: characters.count)
            return characters.withUnsafeBufferPointer { chars in
                glyphs.withUnsafeMutableBufferPointer { output in
                    CTFontGetGlyphsForCharacters(
                        font as CTFont,
                        chars.baseAddress!,
                        output.baseAddress!,
                        characters.count
                    )
                }
            } && !glyphs.contains(0)
        }

        private static func glyphRun(for text: String, font: NSFont) -> GlyphRun {
            let safe = displayText(text, font: font)
            let characters = Array(safe.utf16)
            guard !characters.isEmpty else {
                return GlyphRun(glyphs: [], advances: [], width: 0)
            }

            var glyphs = [CGGlyph](repeating: 0, count: characters.count)
            characters.withUnsafeBufferPointer { chars in
                glyphs.withUnsafeMutableBufferPointer { output in
                    _ = CTFontGetGlyphsForCharacters(
                        font as CTFont,
                        chars.baseAddress!,
                        output.baseAddress!,
                        characters.count
                    )
                }
            }

            // `displayText` guarantees this should not be needed. Keep the
            // direct drawing path total even if a font changes under us.
            if glyphs.contains(0) {
                let fallback = Array(replacement.utf16)
                var fallbackGlyph = [CGGlyph](repeating: 0, count: fallback.count)
                fallback.withUnsafeBufferPointer { chars in
                    fallbackGlyph.withUnsafeMutableBufferPointer { output in
                        _ = CTFontGetGlyphsForCharacters(
                            font as CTFont,
                            chars.baseAddress!,
                            output.baseAddress!,
                            fallback.count
                        )
                    }
                }
                let replacementGlyph = fallbackGlyph.first ?? 0
                glyphs = glyphs.map { $0 == 0 ? replacementGlyph : $0 }
            }

            var advances = [CGSize](repeating: .zero, count: glyphs.count)
            glyphs.withUnsafeBufferPointer { input in
                advances.withUnsafeMutableBufferPointer { output in
                    _ = CTFontGetAdvancesForGlyphs(
                        font as CTFont,
                        .horizontal,
                        input.baseAddress!,
                        output.baseAddress!,
                        glyphs.count
                    )
                }
            }
            let measured = advances.reduce(CGFloat.zero) { $0 + $1.width }
            return GlyphRun(glyphs: glyphs, advances: advances, width: measured)
        }
    }

    @MainActor
    final class TabBarView: NSView {
        /// Every number here is read from the spec doc's own CSS (Terminal
        /// UI.dc.html, "ТАБ-БАР — СПЕКА ДО ПИКСЕЛЯ"), not eyeballed off the
        /// rendered mockup -- e.g. the first-tab position is an explicit
        /// `margin-left:90px`, distinct from the traffic-light zone's own
        /// 78px width (a first pass conflated the two); tab padding is
        /// `0 8px 0 10px` (10 left, 8 right), not a symmetric 8.
        private enum Metrics {
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

        private enum Palette {
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

        private enum Fonts {
            static let title = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            static let activeTitle = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
            static let timer = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
            static let badge = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
            static let loneTitle = NSFont.systemFont(ofSize: 13, weight: .semibold)
        }

        /// One drawn tab and the window behind it.
        private struct Tab {
            let window: NSWindow
            let frame: CGRect
            let isActive: Bool
            let index: Int
        }

        private var tabs: [Tab] = []
        /// How many tabs the strip last laid out (0 in single-window mode).
        var laidOutTabCount: Int { tabs.count }
        /// Where tabs are drawn and clicked; ones scrolled past it are not.
        private var stripRect: CGRect = .zero
        private var hovered: Int?
        private var hoveredClose = false
        private var plusHovered = false
        private var splitHovered = false
        private var infoHovered = false
        /// Command-number badges show only while the key is actually held,
        /// after a beat, so they do not flash during ordinary shortcuts.
        private var showingBadges = false
        private var badgeWork: DispatchWorkItem?
        private var tracking: NSTrackingArea?

        override var isFlipped: Bool { false }

        private var group: CustomTabGroup? { window.map { Tako.CustomTabGroup.group(for: $0) } }
        private var windows: [NSWindow] { group?.visibleWindows ?? [] }
        /// A single window shows no strip -- just its title, centred. There
        /// is no such thing as an empty bar.
        private var showsStrip: Bool { windows.count > 1 }

        private var workspaceHovered = false
        private var showsWorkspacePill: Bool {
            WorkspaceStore.shared.workspaces.count > 1 || WorkspaceStore.shared.activeWorkspace.name != "Default"
        }

        private var workspacePillRect: CGRect {
            guard showsWorkspacePill else { return .zero }
            let ws = WorkspaceStore.shared.activeWorkspace
            let title = ws.name
            let titleWidth = TabText.width(of: title, font: Fonts.badge)
            let attention = WorkspaceStore.shared.attentionCount(for: ws)
            let pillWidth = min(140, max(54, 8 + 8 + 6 + titleWidth + (attention > 0 ? 20 : 0) + 8))
            return CGRect(x: 84, y: Metrics.buttonY, width: pillWidth, height: Metrics.buttonSize)
        }

        private var effectiveFirstTabX: CGFloat {
            showsWorkspacePill ? workspacePillRect.maxX + 8 : Metrics.firstTabX
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
            for tab in tabs where tab.frame.intersects(stripRect) { draw(tab, in: ctx) }
            ctx.restoreGState()
            if let w = window {
                let style = progressStyle(for: w)
                if style.showsInWindow && !style.showsInTab, let prog = aggregateProgress(for: w) {
                    drawProgressBar(in: bounds, progress: prog, context: ctx)
                }
            }
            drawButtons(in: ctx)
        }

        private func drawLoneTitle() {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            if let w = window {
                let style = progressStyle(for: w)
                if style.showsInWindow, let prog = aggregateProgress(for: w) {
                    drawProgressBar(in: bounds, progress: prog, context: ctx)
                }
            }
            let title = window?.title ?? ""
            guard !title.isEmpty else { return }
            let startX = effectiveFirstTabX
            let width = TabText.width(of: title, font: Fonts.loneTitle)
            let maxTitleWidth = max(0, infoRect.minX - startX - 16)
            let drawnX = max(startX, (bounds.width - min(width, maxTitleWidth)) / 2)
            if drawnX + width > infoRect.minX - 8 {
                ctx.saveGState()
                ctx.clip(to: CGRect(x: startX, y: 0, width: maxTitleWidth, height: Metrics.barHeight))
                TabText.draw(
                    title,
                    atX: startX,
                    centeredAtY: Metrics.barHeight / 2,
                    font: Fonts.loneTitle,
                    color: Palette.windowTitle,
                    context: ctx
                )
                ctx.restoreGState()
            } else {
                TabText.draw(
                    title,
                    atX: drawnX,
                    centeredAtY: Metrics.barHeight / 2,
                    font: Fonts.loneTitle,
                    color: Palette.windowTitle,
                    context: ctx
                )
            }
        }

        private func draw(_ tab: Tab, in ctx: CGContext) {
            let hovering = hovered == tab.index

            if tab.isActive || hovering {
                // Rounded on top only: a tab sits on the bar, it does not
                // float in it.
                ctx.addPath(topRoundedPath(tab.frame, radius: Metrics.cornerRadius))
                ctx.setFillColor((tab.isActive ? Palette.activeTab : Palette.hoverTab).cgColor)
                ctx.fillPath()
            } else if tab.index > 0, !tabs[tab.index - 1].isActive {
                // A hairline between two inactive tabs; none beside the
                // active one, whose own fill already separates it.
                ctx.setFillColor(Palette.hairline.cgColor)
                ctx.fill(CGRect(x: tab.frame.minX, y: tab.frame.midY - 6, width: 1, height: 12))
            }

            let style = progressStyle(for: tab.window)
            if style.showsInTab, let prog = aggregateProgress(for: tab.window) {
                drawProgressBar(in: tab.frame, progress: prog, context: ctx)
            } else if tab.isActive {
                ctx.setFillColor(Brand.ember.cgColor)
                ctx.fill(CGRect(x: tab.frame.minX, y: tab.frame.minY,
                                width: tab.frame.width, height: Metrics.activeBarHeight))
            }

            let crabRect = CGRect(
                x: (tab.frame.minX + Metrics.tabPaddingLeft).rounded(),
                y: (tab.frame.midY - Metrics.crabSize / 2).rounded(),
                width: Metrics.crabSize, height: Metrics.crabSize)
            drawCrab(for: tab, in: crabRect, ctx: ctx)

            // "✕ — только на ховере и на активной": the close glyph shows on
            // whichever tab is hovered, plus always on the active tab (not
            // just on hover of the active tab specifically).
            // A tab too narrow for both keeps the crab and drops the close.
            let showsClose = (hovering || tab.isActive) && tab.frame.width >= Metrics.compactTabWidth
            let textX = crabRect.maxX + Metrics.contentGap
            let closeWidth = showsClose ? Metrics.closeSize + Metrics.contentGap : 0
            let textWidth = tab.frame.maxX - Metrics.tabPaddingRight - closeWidth - textX
            if textWidth > 8 {
                drawLabel(for: tab, x: textX, width: textWidth)
            }
            if showsClose {
                drawClose(in: CGRect(x: tab.frame.maxX - Metrics.tabPaddingRight - Metrics.closeSize,
                                     y: tab.frame.midY - Metrics.closeSize / 2,
                                     width: Metrics.closeSize, height: Metrics.closeSize),
                          ctx: ctx)
            }
        }

        private func drawLabel(for tab: Tab, x: CGFloat, width: CGFloat) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            let titleFont = tab.isActive ? Fonts.activeTitle : Fonts.title
            let titleColor = tab.isActive ? Palette.activeText : Palette.inactiveText
            let timer = elapsedFor(tab.window)
            let timerWidth = timer.map {
                TabText.width(of: $0, font: Fonts.timer) + Metrics.contentGap
            } ?? 0

            let title = TabText.truncate(
                titleFor(tab.window),
                to: width - timerWidth,
                font: titleFont
            )
            let titleWidth = TabText.draw(
                title,
                atX: x,
                centeredAtY: tab.frame.midY,
                font: titleFont,
                color: titleColor,
                context: ctx
            )
            if let timer {
                TabText.draw(
                    timer,
                    atX: x + titleWidth + Metrics.contentGap,
                    centeredAtY: tab.frame.midY,
                    font: Fonts.timer,
                    color: Palette.dim,
                    context: ctx
                )
            }
        }

        /// The badge sits over the crab, so it costs no width.
        private func drawCrab(for tab: Tab, in rect: CGRect, ctx: CGContext) {
            guard !(showingBadges && tab.index < 9) else {
                ctx.setFillColor(Palette.badge.cgColor)
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4,
                                   transform: nil))
                ctx.fillPath()
                let label = "\(tab.index + 1)"
                let width = TabText.width(of: label, font: Fonts.badge)
                TabText.draw(
                    label,
                    atX: rect.midX - width / 2,
                    centeredAtY: rect.midY,
                    font: Fonts.badge,
                    color: Palette.activeText,
                    context: ctx
                )
                return
            }
            let unread = surfaces(in: tab.window).contains(where: {
                !$0.isAttentionMuted && ($0.crab.unread || NotificationStore.shared.unreadCount(for: $0.id) > 0)
            })
            CrabPainter.draw(in: rect, color: crabColor(for: tab.window), unread: unread, context: ctx)
        }

        private func drawClose(in rect: CGRect, ctx: CGContext) {
            ctx.setStrokeColor((hoveredClose ? Palette.activeText : Palette.dim).cgColor)
            ctx.setLineWidth(1.5)
            let inset: CGFloat = 4
            ctx.move(to: CGPoint(x: rect.minX + inset, y: rect.minY + inset))
            ctx.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY - inset))
            ctx.move(to: CGPoint(x: rect.maxX - inset, y: rect.minY + inset))
            ctx.addLine(to: CGPoint(x: rect.minX + inset, y: rect.maxY - inset))
            ctx.strokePath()
        }

        /// "кнопки справа 28×28, gap 4, отступ 8": + is rightmost (window
        /// edge minus the 8px margin), ◫ sits 4px to its left, ⓘ sits 4px to the left of ◫.
        private var plusRect: CGRect {
            CGRect(x: bounds.width - Metrics.buttonMarginRight - Metrics.buttonSize,
                   y: Metrics.buttonY, width: Metrics.buttonSize, height: Metrics.buttonSize)
        }

        private var splitRect: CGRect {
            CGRect(x: plusRect.minX - Metrics.buttonGap - Metrics.buttonSize,
                   y: Metrics.buttonY, width: Metrics.buttonSize, height: Metrics.buttonSize)
        }

        private var infoRect: CGRect {
            CGRect(x: splitRect.minX - Metrics.buttonGap - Metrics.buttonSize,
                   y: Metrics.buttonY, width: Metrics.buttonSize, height: Metrics.buttonSize)
        }

        private func drawButton(_ rect: CGRect, hovered: Bool, in ctx: CGContext, draw glyph: (CGContext, CGRect) -> Void) {
            if hovered {
                ctx.setFillColor(Palette.activeTab.cgColor)
                ctx.addPath(CGPath(roundedRect: rect, cornerWidth: Metrics.buttonRadius, cornerHeight: Metrics.buttonRadius, transform: nil))
                ctx.fillPath()
            }
            glyph(ctx, rect)
        }

        private func drawButtons(in ctx: CGContext) {
            drawButton(infoRect, hovered: infoHovered, in: ctx) { ctx, rect in
                let r: CGFloat = Metrics.infoGlyphSize / 2
                let circleRect = CGRect(x: rect.midX - r, y: rect.midY - r, width: r * 2, height: r * 2)
                ctx.setStrokeColor(Palette.dim.cgColor)
                ctx.setLineWidth(1.2)
                ctx.strokeEllipse(in: circleRect)

                // Info dot (at top)
                let dotRadius: CGFloat = 1.0
                let dotCenterY = rect.midY + 2.5
                ctx.setFillColor(Palette.dim.cgColor)
                ctx.fillEllipse(in: CGRect(x: rect.midX - dotRadius, y: dotCenterY - dotRadius,
                                           width: dotRadius * 2, height: dotRadius * 2))

                // Info stem (downwards)
                ctx.setLineWidth(1.3)
                ctx.move(to: CGPoint(x: rect.midX, y: rect.midY + 0.5))
                ctx.addLine(to: CGPoint(x: rect.midX, y: rect.midY - 3.5))
                ctx.strokePath()
            }
            drawButton(splitRect, hovered: splitHovered, in: ctx) { ctx, rect in
                // rectangle.split.2x1: two cells side by side, 13pt optical.
                let glyphSize: CGFloat = Metrics.splitGlyphSize
                let glyphRect = CGRect(x: rect.midX - glyphSize / 2, y: rect.midY - glyphSize * 0.7 / 2, width: glyphSize, height: glyphSize * 0.7)
                ctx.setStrokeColor(Palette.dim.cgColor)
                ctx.setLineWidth(1.2)
                ctx.stroke(glyphRect)
                ctx.move(to: CGPoint(x: glyphRect.midX, y: glyphRect.minY))
                ctx.addLine(to: CGPoint(x: glyphRect.midX, y: glyphRect.maxY))
                ctx.strokePath()
            }
            drawButton(plusRect, hovered: plusHovered, in: ctx) { ctx, rect in
                let half: CGFloat = Metrics.plusGlyphSize / 2
                ctx.setStrokeColor(Palette.dim.cgColor)
                ctx.setLineWidth(1.5)
                ctx.move(to: CGPoint(x: rect.midX - half, y: rect.midY))
                ctx.addLine(to: CGPoint(x: rect.midX + half, y: rect.midY))
                ctx.move(to: CGPoint(x: rect.midX, y: rect.midY - half))
                ctx.addLine(to: CGPoint(x: rect.midX, y: rect.midY + half))
                ctx.strokePath()
            }
        }

        private func topRoundedPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
            path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.maxY),
                              control: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - radius),
                              control: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.closeSubpath()
            return path
        }

        // MARK: - Workspace Pill & Menu (C1)

        private func drawWorkspacePill(in ctx: CGContext) {
            guard showsWorkspacePill else { return }
            let rect = workspacePillRect
            let ws = WorkspaceStore.shared.activeWorkspace
            let attention = WorkspaceStore.shared.attentionCount(for: ws)

            // Background pill
            ctx.setFillColor(workspaceHovered ? Palette.hoverTab.cgColor : Palette.badge.cgColor)
            let path = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
            ctx.addPath(path)
            ctx.fillPath()

            // Color dot
            let dotColor: NSColor
            switch ws.color?.lowercased() {
            case "red": dotColor = Brand.error
            case "green": dotColor = Brand.ok
            case "orange": dotColor = Brand.ember
            case "purple": dotColor = NSColor.systemPurple
            case "yellow": dotColor = NSColor.systemYellow
            default: dotColor = NSColor.systemBlue
            }
            ctx.setFillColor(dotColor.cgColor)
            let dotRect = CGRect(x: rect.minX + 8, y: rect.midY - 3.5, width: 7, height: 7)
            ctx.fillEllipse(in: dotRect)

            // Workspace title
            let maxTitleWidth = rect.width - 24 - (attention > 0 ? 20 : 0)
            let title = TabText.truncate(ws.name, to: maxTitleWidth, font: Fonts.badge)
            let textColor = workspaceHovered ? Palette.activeText : Palette.inactiveText
            TabText.draw(title, atX: dotRect.maxX + 6, centeredAtY: rect.midY,
                         font: Fonts.badge, color: textColor, context: ctx)

            // Attention badge if > 0
            if attention > 0 {
                let badgeRect = CGRect(x: rect.maxX - 18, y: rect.midY - 6, width: 14, height: 12)
                ctx.setFillColor(Brand.ember.cgColor)
                ctx.addPath(CGPath(roundedRect: badgeRect, cornerWidth: 4, cornerHeight: 4, transform: nil))
                ctx.fillPath()
                let countStr = attention > 9 ? "9+" : "\(attention)"
                TabText.draw(countStr, atX: badgeRect.minX + 3, centeredAtY: badgeRect.midY,
                             font: Fonts.timer, color: Palette.bar, context: ctx)
            }
        }

        private func showWorkspaceMenu(at point: CGPoint) {
            let menu = NSMenu()
            let store = WorkspaceStore.shared
            for ws in store.workspaces {
                let attention = store.attentionCount(for: ws)
                let title = attention > 0 ? "\(ws.name) (\(attention))" : ws.name
                let item = NSMenuItem(title: title, action: #selector(handleWorkspaceSelected(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = ws.id
                if ws.id == store.activeWorkspaceId {
                    item.state = .on
                }
                menu.addItem(item)
            }
            menu.addItem(NSMenuItem.separator())
            let nextItem = NSMenuItem(title: "Next Workspace", action: #selector(handleNextWorkspace), keyEquivalent: "]")
            nextItem.keyEquivalentModifierMask = [.control, .option]
            nextItem.target = self
            menu.addItem(nextItem)

            let prevItem = NSMenuItem(title: "Previous Workspace", action: #selector(handlePreviousWorkspace), keyEquivalent: "[")
            prevItem.keyEquivalentModifierMask = [.control, .option]
            prevItem.target = self
            menu.addItem(prevItem)

            menu.addItem(NSMenuItem.separator())
            let newItem = NSMenuItem(title: "New Workspace...", action: #selector(handleNewWorkspace), keyEquivalent: "")
            newItem.target = self
            menu.addItem(newItem)

            menu.popUp(positioning: nil, at: point, in: self)
        }

        @objc private func handleWorkspaceSelected(_ sender: NSMenuItem) {
            if let id = sender.representedObject as? UUID {
                WorkspaceStore.shared.switchWorkspace(to: id)
            }
        }

        @objc private func handleNextWorkspace() {
            WorkspaceStore.shared.nextWorkspace()
        }

        @objc private func handlePreviousWorkspace() {
            WorkspaceStore.shared.previousWorkspace()
        }

        @objc private func handleNewWorkspace() {
            let alert = NSAlert()
            alert.messageText = "New Project Workspace"
            alert.informativeText = "Enter a name for the new workspace:"
            alert.alertStyle = .informational
            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
            input.placeholderString = "e.g. backend, docs, tako"
            alert.accessoryView = input
            alert.addButton(withTitle: "Create")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    let ws = WorkspaceStore.shared.createWorkspace(name: name)
                    WorkspaceStore.shared.switchWorkspace(to: ws.id)
                }
            }
        }

        // MARK: What each tab says

        private func surface(in window: NSWindow) -> SurfaceView? {
            func find(_ view: NSView) -> SurfaceView? {
                if let surface = view as? SurfaceView { return surface }
                for sub in view.subviews {
                    if let found = find(sub) { return found }
                }
                return nil
            }
            return window.contentView.flatMap(find)
        }

        private func titleFor(_ window: NSWindow) -> String {
            let raw = surface(in: window)?.title ?? window.title
            guard !raw.isEmpty else { return "~" }
            // A path is shown by its last component; a bare slash says
            // nothing in a tab strip, so it reads as home.
            if raw.hasPrefix("/") || raw.hasPrefix("~") {
                return Tako.titleForDirectory(raw)
            }
            return raw
        }

        private func surfaces(in window: NSWindow) -> [SurfaceView] {
            func collect(_ view: NSView, into list: inout [SurfaceView]) {
                if let surface = view as? SurfaceView {
                    list.append(surface)
                }
                for sub in view.subviews {
                    collect(sub, into: &list)
                }
            }
            var list: [SurfaceView] = []
            if let content = window.contentView {
                collect(content, into: &list)
            }
            return list
        }

        private func aggregateCrab(for window: NSWindow) -> CrabTracker? {
            let all = surfaces(in: window)
            guard !all.isEmpty else { return nil }
            return all.max(by: { $0.crab.paneStatus.priority < $1.crab.paneStatus.priority })?.crab
        }

        private func elapsedFor(_ window: NSWindow) -> String? {
            aggregateCrab(for: window)?.elapsedLabel
        }

        private func crabColor(for window: NSWindow) -> NSColor {
            aggregateCrab(for: window)?.state.color ?? Brand.ember
        }

        private func progressStyle(for window: NSWindow) -> Tako.Config.ProgressStyle {
            if let app = (NSApp?.delegate as? AppDelegate)?.tako {
                return app.config.progressStyle
            }
            return Tako.Config.ProgressStyle.all
        }

        private func aggregateProgress(for window: NSWindow) -> (state: ProgressState, progress: Int?)? {
            let all = surfaces(in: window)
            guard !all.isEmpty else { return nil }
            return CrabTabBinding.aggregateProgress(for: all)
        }

        private func drawProgressBar(in rect: CGRect, progress: (state: ProgressState, progress: Int?), context ctx: CGContext) {
            let barHeight: CGFloat = 2.5
            let widthFraction: CGFloat
            let color: NSColor
            switch progress.state {
            case .none:
                return
            case .normal:
                widthFraction = CGFloat(min(100, max(0, progress.progress ?? 0))) / 100.0
                color = Brand.ok
            case .error:
                widthFraction = CGFloat(min(100, max(0, progress.progress ?? 100))) / 100.0
                color = Brand.error
            case .paused:
                widthFraction = CGFloat(min(100, max(0, progress.progress ?? 100))) / 100.0
                color = NSColor.systemOrange
            case .indeterminate:
                widthFraction = 0.35
                color = Brand.ember
            }
            if widthFraction > 0 {
                let fillWidth = max(2.0, rect.width * widthFraction)
                let fillX = progress.state == .indeterminate ? rect.minX + (rect.width - fillWidth) / 2 : rect.minX
                ctx.setFillColor(color.cgColor)
                ctx.fill(CGRect(x: fillX, y: rect.minY, width: fillWidth, height: barHeight))
            }
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

    /// The brand mark at any size, from the grid the app icons use.
    enum CrabPainter {
        static let rows = [
            "CC......CC",
            "C........C",
            ".#......#.",
            "..######..",
            "..#o##o#..",
            "..######..",
            ".#.#..#.#.",
        ]

        /// Whole-pixel cells only: the mark is a pixel grid and a fractional
        /// cell turns it to mush.
        static func draw(in rect: CGRect, color: NSColor, unread: Bool = false, context ctx: CGContext) {
            let step = min(rect.width / 10, rect.height / 7).rounded(.down)
            guard step >= 1 else { return }
            let cell = max(step - 1, 1)
            let originX = (rect.midX - step * 5).rounded()
            let topY = (rect.midY + step * 3.5).rounded()

            func fill(_ predicate: (Character) -> Bool) {
                for (r, row) in rows.enumerated() {
                    for (c, ch) in row.enumerated() where predicate(ch) {
                        ctx.fill(CGRect(x: originX + CGFloat(c) * step,
                                        y: topY - CGFloat(r + 1) * step,
                                        width: cell, height: cell))
                    }
                }
            }

            ctx.setFillColor(color.cgColor)
            fill { $0 != "." && $0 != "o" }
            // The eyes are holes, so the tab behind shows through.
            ctx.setBlendMode(.clear)
            fill { $0 == "o" }
            ctx.setBlendMode(.normal)

            if unread {
                ctx.setFillColor(Brand.claw.cgColor)
                ctx.fillEllipse(in: CGRect(x: rect.maxX - 3, y: rect.maxY - 3, width: 3, height: 3))
            }
        }
    }
}
