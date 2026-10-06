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

    func drawTab(_ tab: Tab, in ctx: CGContext) {
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
        let timer = elapsedFor(tab.window)
        let timerWidth = timer.map {
            Tako.TabText.width(of: $0, font: Fonts.timer) + Metrics.contentGap
        } ?? 0

        let title = Tako.TabText.truncate(
            titleFor(tab.window),
            to: width - timerWidth,
            font: titleFont
        )
        let titleWidth = Tako.TabText.draw(
            title,
            atX: x,
            centeredAtY: tab.frame.midY,
            font: titleFont,
            color: titleColor,
            context: ctx
        )
        if let timer {
            Tako.TabText.draw(
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
    func drawCrab(for tab: Tab, in rect: CGRect, ctx: CGContext) {
        guard !(showingBadges && tab.index < 9) else {
            ctx.setFillColor(Palette.badge.cgColor)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4,
                               transform: nil))
            ctx.fillPath()
            let label = "\(tab.index + 1)"
            let width = Tako.TabText.width(of: label, font: Fonts.badge)
            Tako.TabText.draw(
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
        Tako.CrabPainter.draw(in: rect, color: crabColor(for: tab.window), unread: unread, context: ctx)
    }

    func drawClose(in rect: CGRect, ctx: CGContext) {
        ctx.setStrokeColor((hoveredClose ? Palette.activeText : Palette.dim).cgColor)
        ctx.setLineWidth(1.5)
        let inset: CGFloat = 4
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

    func topRoundedPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
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
