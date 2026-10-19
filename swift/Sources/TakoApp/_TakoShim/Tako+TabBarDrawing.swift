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
import CoreGraphics

extension Tako.TabBarView {
    func drawLoneTitle() {
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
        let width = Tako.TabText.width(of: title, font: Fonts.loneTitle)
        let maxTitleWidth = max(0, infoRect.minX - startX - 16)
        let drawnX = max(startX, (bounds.width - min(width, maxTitleWidth)) / 2)
        if drawnX + width > infoRect.minX - 8 {
            ctx.saveGState()
            ctx.clip(to: CGRect(x: startX, y: 0, width: maxTitleWidth, height: Metrics.barHeight))
            Tako.TabText.draw(
                title,
                atX: startX,
                centeredAtY: Metrics.barHeight / 2,
                font: Fonts.loneTitle,
                color: Palette.windowTitle,
                context: ctx
            )
            ctx.restoreGState()
        } else {
            Tako.TabText.draw(
                title,
                atX: drawnX,
                centeredAtY: Metrics.barHeight / 2,
                font: Fonts.loneTitle,
                color: Palette.windowTitle,
                context: ctx
            )
        }
    }

    func pillRect(for tab: Tab) -> CGRect {
        CGRect(
            x: tab.frame.minX,
            y: Metrics.buttonY,
            width: tab.frame.width,
            height: Metrics.buttonSize
        )
    }

    func pillIndicatorColor(for tab: Tab) -> NSColor {
        let report = Tako.tabVisualStatus(for: tab.window)
        return Tako.tabStatusColor(for: report.dot)
    }

    func drawPillTab(_ tab: Tab, in ctx: CGContext) {
        let hovering = hovered == tab.index
        let baseRect = pillRect(for: tab)
        guard baseRect.width > 0 else { return }

        let state = pillSurfaceState(for: tab.window)
        let shakeDX: CGFloat = {
            guard state == .failed, !LivingAnimationState.shared.reduceMotion,
                  let t = LivingAnimationState.shared.fixedTimeOverride else { return 0 }
            return LivingAnimationState.failedShakeOffset(elapsed: t)
        }()
        let rect = baseRect.offsetBy(dx: shakeDX, dy: 0)
        let path = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)

        // Background (§4): inactive transparent, hover #1F1915, progress #1A1512, active #241C16 + 1px #2A211B inset border
        if tab.isActive {
            ctx.addPath(path)
            ctx.setFillColor(Palette.activeTab.cgColor)
            ctx.fillPath()

            if state != .waiting {
                let insetPath = CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 6, cornerHeight: 6, transform: nil)
                ctx.addPath(insetPath)
                ctx.setStrokeColor(Palette.hairline.cgColor)
                ctx.setLineWidth(1)
                ctx.strokePath()
            }
        } else if hovering {
            ctx.addPath(path)
            ctx.setFillColor(Palette.hoverTab.cgColor)
            ctx.fillPath()
        } else if case .progress = state {
            ctx.addPath(path)
            ctx.setFillColor(Tako.LivingTokens.chrome.cgColor)
            ctx.fillPath()
        }

        // Status Ring S=14 via TabStatusLayer or Command-number badge when Command is held
        let showNumberBadge = showingBadges && tab.index < 9 && windows.count > 1
        let dotColor = pillIndicatorColor(for: tab)
        let tabKey = ObjectIdentifier(tab.window)
        paintedPillDots[tabKey] = Tako.Brand.hexString(for: dotColor)
        paintedRingStates[tabKey] = state
        updateStatusLayer(for: tab.window, rect: baseRect, state: state, hideRing: showNumberBadge)

        let borderInset: CGFloat = (state == .working || state == .offline) ? 1.0 : 0.0

        if showNumberBadge {
            let badgeRect = CGRect(x: rect.minX + 8 + borderInset, y: rect.midY - 7, width: 14, height: 14)
            ctx.setFillColor(Palette.badge.cgColor)
            ctx.addPath(CGPath(roundedRect: badgeRect, cornerWidth: 4, cornerHeight: 4, transform: nil))
            ctx.fillPath()
            let label = "\(tab.index + 1)"
            let width = Tako.TabText.width(of: label, font: Fonts.badge)
            Tako.TabText.draw(
                label,
                atX: badgeRect.midX - width / 2,
                centeredAtY: badgeRect.midY,
                font: Fonts.badge,
                color: Palette.activeText,
                context: ctx
            )
        }

        // Right-side affordance: ✕ on active/hovered tab, or Ø5 Claw unread dot on background tabs with unread notifications
        let showsClose = (tab.isActive || hovering) && rect.width >= Metrics.pillCloseMinWidth
        let metaStyle = pillMetaStyle(for: tab.window)
        // A failure that shows its exit code needs no dot to be noticed.
        let showsUnreadDot = !showsClose
            && (hasUnreadInWindow(tab.window) || (state == .failed && !tab.isActive && metaStyle != .exitCode))
        let rightExtra: CGFloat = showsClose ? (7 + 6) : (showsUnreadDot ? (7 + 5) : 0)

        let titleFont = tab.isActive ? Fonts.pillActiveTitle : Fonts.pillTitle
        let rawTitle = titleFor(tab.window)
        let fullTitleWidth = Tako.TabText.width(of: rawTitle, font: titleFont)
        let metaText = pillMetaText(for: tab.window)
        let metaWidth = metaText.map { pillMetaWidth($0, style: metaStyle) } ?? 0
        let titleStartX = rect.minX + 29 + borderInset // (8 + border) + 14 (ring S) + 7 (gap)
        let availableForTitleAndMeta = rect.width - (29 + borderInset) - (9 + borderInset) - rightExtra
        let includesMeta = metaText != nil && (availableForTitleAndMeta - (metaWidth + 7) >= fullTitleWidth - 1.5)
        let maxTitleWidth = availableForTitleAndMeta - (includesMeta ? (metaWidth + 7) : 0)

        if maxTitleWidth > 8 {
            let title = Tako.TabText.truncate(rawTitle, to: maxTitleWidth, font: titleFont)
            let titleColor: NSColor
            if state == .offline {
                titleColor = Tako.LivingTokens.faint
            } else if tab.isActive || hovering {
                titleColor = Palette.activeText
            } else {
                titleColor = Palette.inactiveText
            }
            _ = Tako.TabText.draw(
                title,
                atX: titleStartX,
                centeredAtY: rect.midY,
                font: titleFont,
                color: titleColor,
                context: ctx
            )
        }

        if includesMeta, let metaText {
            let metaX = rect.maxX - 9 - rightExtra - metaWidth
            drawPillMeta(metaText, style: metaStyle, atX: metaX, centeredAtY: rect.midY, in: ctx)
        }

        if showsClose {
            let closeFont = Tako.LivingTokens.monoFont(size: 10)
            let closeW = Tako.TabText.width(of: "✕", font: closeFont)
            let closeColor = (hoveredClose && hovering) ? Palette.activeText : Palette.dim
            Tako.TabText.draw("✕", atX: rect.maxX - 9 - closeW, centeredAtY: rect.midY, font: closeFont, color: closeColor, context: ctx)
        } else if showsUnreadDot {
            let unreadRect = CGRect(x: rect.maxX - 9 - 5, y: rect.midY - 2.5, width: 5, height: 5)
            ctx.setFillColor(Tako.LivingTokens.claw.cgColor)
            ctx.fillEllipse(in: unreadRect)
        }
    }

    func drawTab(_ tab: Tab, in ctx: CGContext) {
        if effectiveTabStyle == .pill {
            drawPillTab(tab, in: ctx)
            return
        }

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
        }

        if tab.isActive {
            ctx.setFillColor(Tako.Brand.ember.cgColor)
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

    func drawLabel(for tab: Tab, x: CGFloat, width: CGFloat) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let titleFont = tab.isActive ? Fonts.activeTitle : Fonts.title
        let titleColor = tab.isActive ? Palette.activeText : Palette.inactiveText
        let title = Tako.TabText.truncate(titleFor(tab.window), to: width, font: titleFont)
        Tako.TabText.draw(title, atX: x, centeredAtY: tab.frame.midY, font: titleFont, color: titleColor, context: ctx)
    }

    /// The badge sits over the crab, so it costs no width.
    func drawCrab(for tab: Tab, in rect: CGRect, ctx: CGContext) {
        guard !(showingBadges && tab.index < 9 && windows.count > 1) else {
            ctx.setFillColor(Palette.badge.cgColor)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil))
            ctx.fillPath()
            let label = "\(tab.index + 1)"
            let width = Tako.TabText.width(of: label, font: Fonts.badge)
            Tako.TabText.draw(label, atX: rect.midX - width / 2, centeredAtY: rect.midY, font: Fonts.badge, color: Palette.activeText, context: ctx)
            return
        }
        let unread = surfaces(in: tab.window).contains(where: {
            !$0.isAttentionMuted && ($0.crab.unread || NotificationStore.shared.unreadCount(for: $0.id) > 0)
        })
        Tako.CrabPainter.draw(in: rect, color: crabColor(for: tab.window), unread: unread, context: ctx)
    }

    func drawClose(in rect: CGRect, color: NSColor? = nil, ctx: CGContext) {
        let strokeColor = color ?? (hoveredClose ? Palette.activeText : Palette.dim)
        ctx.setStrokeColor(strokeColor.cgColor)
        ctx.setLineWidth(1.3)
        let inset: CGFloat = max(1.5, min(rect.width, rect.height) * 0.2)
        ctx.move(to: CGPoint(x: rect.minX + inset, y: rect.minY + inset))
        ctx.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY - inset))
        ctx.move(to: CGPoint(x: rect.maxX - inset, y: rect.minY + inset))
        ctx.addLine(to: CGPoint(x: rect.minX + inset, y: rect.maxY - inset))
        ctx.strokePath()
    }

    func drawButton(_ rect: CGRect, hovered: Bool, in ctx: CGContext, draw glyph: (CGContext, CGRect) -> Void) {
        if hovered {
            ctx.setFillColor(Palette.activeTab.cgColor)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: Metrics.buttonRadius, cornerHeight: Metrics.buttonRadius, transform: nil))
            ctx.fillPath()
        }
        glyph(ctx, rect)
    }

    func drawButtons(in ctx: CGContext) {
        if infoRect.width > 0 {
            drawButton(infoRect, hovered: infoHovered, in: ctx) { ctx, rect in
                let r: CGFloat = Metrics.infoGlyphSize / 2
                ctx.setStrokeColor(Palette.dim.cgColor)
                ctx.setLineWidth(1.2)
                ctx.strokeEllipse(in: CGRect(x: rect.midX - r, y: rect.midY - r, width: r * 2, height: r * 2))
                ctx.setFillColor(Palette.dim.cgColor)
                ctx.fillEllipse(in: CGRect(x: rect.midX - 1.0, y: rect.midY + 1.5, width: 2.0, height: 2.0))
                ctx.setLineWidth(1.3)
                ctx.move(to: CGPoint(x: rect.midX, y: rect.midY + 0.5))
                ctx.addLine(to: CGPoint(x: rect.midX, y: rect.midY - 3.5))
                ctx.strokePath()
            }
        }
        drawButton(splitRect, hovered: splitHovered, in: ctx) { ctx, rect in
            let font = Tako.LivingTokens.monoFont(size: 15)
            let w = Tako.TabText.width(of: "◫", font: font)
            Tako.TabText.draw("◫", atX: rect.midX - w / 2, centeredAtY: rect.midY, font: font, color: Palette.dim, context: ctx)
        }
        drawButton(plusRect, hovered: plusHovered, in: ctx) { ctx, rect in
            let font = Tako.LivingTokens.monoFont(size: 15)
            let w = Tako.TabText.width(of: "+", font: font)
            Tako.TabText.draw("+", atX: rect.midX - w / 2, centeredAtY: rect.midY, font: font, color: Palette.dim, context: ctx)
        }
    }

    func topRoundedPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.maxY), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY - radius), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }

    func drawProgressBar(in rect: CGRect, progress: (state: ProgressState, progress: Int?), context ctx: CGContext) {
        let barHeight: CGFloat = 2.5
        let widthFraction: CGFloat
        let color: NSColor
        switch progress.state {
        case .none:
            return
        case .normal:
            widthFraction = CGFloat(min(100, max(0, progress.progress ?? 0))) / 100.0
            color = Tako.Brand.ok
        case .error:
            widthFraction = CGFloat(min(100, max(0, progress.progress ?? 100))) / 100.0
            color = Tako.Brand.error
        case .paused:
            widthFraction = CGFloat(min(100, max(0, progress.progress ?? 100))) / 100.0
            color = NSColor.systemOrange
        case .indeterminate:
            widthFraction = 0.35
            color = Tako.Brand.ember
        }
        if widthFraction > 0 {
            let fillWidth = max(2.0, rect.width * widthFraction)
            let fillX = progress.state == .indeterminate ? rect.minX + (rect.width - fillWidth) / 2 : rect.minX
            ctx.setFillColor(color.cgColor)
            ctx.fill(CGRect(x: fillX, y: rect.minY, width: fillWidth, height: barHeight))
        }
    }
}
