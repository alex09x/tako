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
            /// "кнопки справа 28×28, gap 4, отступ 8" -- two buttons (◫
            /// split, + new tab), not one.
            static let buttonSize: CGFloat = 28
            static let buttonRadius: CGFloat = 7
            static let buttonGap: CGFloat = 4
            static let buttonMarginRight: CGFloat = 8
            static let buttonY: CGFloat = (barHeight - buttonSize) / 2
            static let splitGlyphSize: CGFloat = 13
            static let plusGlyphSize: CGFloat = 15
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
        private var hovered: Int?
        private var hoveredClose = false
        private var plusHovered = false
        private var splitHovered = false
        /// Command-number badges show only while the key is actually held,
        /// after a beat, so they do not flash during ordinary shortcuts.
        private var showingBadges = false
        private var badgeWork: DispatchWorkItem?
        private var tracking: NSTrackingArea?

        override var isFlipped: Bool { false }

        private var group: CustomTabGroup? { window.map { Tako.CustomTabGroup.group(for: $0) } }
        private var windows: [NSWindow] { group?.windows ?? [] }
        /// A single window shows no strip -- just its title, centred. There
        /// is no such thing as an empty bar.
        private var showsStrip: Bool { windows.count > 1 }

        func refresh() {
            needsDisplay = true
        }

        // MARK: Layout

        /// Right edge reserved for the ◫/+ pair: two 28px buttons, a 4px
        /// gap between them, and an 8px margin from the window edge.
        private var buttonsReservedWidth: CGFloat {
            Metrics.buttonSize * 2 + Metrics.buttonGap + Metrics.buttonMarginRight
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
            let available = bounds.width - Metrics.firstTabX - buttonsReservedWidth
            let natural = all.map(naturalWidth(for:))

            // Only when the natural widths genuinely don't fit do tabs give
            // up room evenly (down to the 120px floor) rather than each
            // keeping its own content width -- see "тесно: равномерно
            // жмутся до 120" in the spec. A real overflow menu ("+N ▾") for
            // what still doesn't fit past that isn't built yet.
            let totalNatural = natural.reduce(0, +)
            let widths: [CGFloat]
            if totalNatural <= available || all.isEmpty {
                widths = natural
            } else {
                let shrunk = max(Metrics.minTabWidth, available / CGFloat(all.count))
                widths = all.map { _ in shrunk }
            }

            var x = Metrics.firstTabX
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

        // MARK: Drawing

        override func draw(_ dirtyRect: NSRect) {
            if let window { Tako.TabBarController.clearTitlebarBackground(in: window) }
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            ctx.setFillColor(Palette.bar.cgColor)
            ctx.fill(bounds)
            ctx.setFillColor(Palette.hairline.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: bounds.width, height: 1))

            guard showsStrip else {
                drawLoneTitle()
                return
            }
            layoutTabs()
            for tab in tabs { draw(tab, in: ctx) }
            drawButtons(in: ctx)
        }

        private func drawLoneTitle() {
            let title = window?.title ?? ""
            guard !title.isEmpty else { return }
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            let width = TabText.width(of: title, font: Fonts.loneTitle)
            TabText.draw(
                title,
                atX: (bounds.width - width) / 2,
                centeredAtY: Metrics.barHeight / 2,
                font: Fonts.loneTitle,
                color: Palette.windowTitle,
                context: ctx
            )
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

            if tab.isActive {
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
            let showsClose = hovering || tab.isActive
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
            CrabPainter.draw(in: rect, color: crabColor(for: tab.window), context: ctx)
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
        /// edge minus the 8px margin), ◫ sits 4px to its left.
        private var plusRect: CGRect {
            CGRect(x: bounds.width - Metrics.buttonMarginRight - Metrics.buttonSize,
                   y: Metrics.buttonY, width: Metrics.buttonSize, height: Metrics.buttonSize)
        }

        private var splitRect: CGRect {
            CGRect(x: plusRect.minX - Metrics.buttonGap - Metrics.buttonSize,
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

        private func elapsedFor(_ window: NSWindow) -> String? {
            surface(in: window)?.crab.elapsedLabel
        }

        private func crabColor(for window: NSWindow) -> NSColor {
            surface(in: window)?.crab.state.color ?? Brand.ember
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
            hovered = tabs.first { $0.frame.contains(point) }?.index
            hoveredClose = hovered.map { closeRect(of: tabs[$0]).contains(point) } ?? false
            plusHovered = plusRect.contains(point)
            splitHovered = splitRect.contains(point)
            if hovered != previousTab || plusHovered != previousPlus || splitHovered != previousSplit {
                needsDisplay = true
            }
        }

        override func mouseExited(with event: NSEvent) {
            hovered = nil
            plusHovered = false
            splitHovered = false
            needsDisplay = true
        }

        /// The close button's hit area is larger than the glyph.
        private func closeRect(of tab: Tab) -> CGRect {
            let inset = (Metrics.closeHitSize - Metrics.closeSize) / 2
            return CGRect(x: tab.frame.maxX - Metrics.tabPaddingRight - Metrics.closeSize - inset,
                          y: tab.frame.midY - Metrics.closeHitSize / 2,
                          width: Metrics.closeHitSize, height: Metrics.closeHitSize)
        }

        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            // Same as mouseMoved: use the cached tabs from the last draw() pass.
            if plusRect.contains(point) {
                NSApp.sendAction(#selector(TerminalController.newTab(_:)), to: nil, from: self)
                return
            }
            if splitRect.contains(point) {
                NSApp.sendAction(#selector(BaseTerminalController.splitRight(_:)), to: nil, from: self)
                return
            }
            guard let tab = tabs.first(where: { $0.frame.contains(point) }) else {
                // Empty bar: drag the window, or zoom it on a double click.
                if event.clickCount == 2 {
                    window?.performZoom(nil)
                } else {
                    window?.performDrag(with: event)
                }
                return
            }
            if closeRect(of: tab).contains(point) {
                tab.window.performClose(nil)
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
        static func draw(in rect: CGRect, color: NSColor, context ctx: CGContext) {
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
        }
    }
}
