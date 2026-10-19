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

/// What a pill shows right of its title: progress, a live program's rate
/// or name, or a failure's exit code (Sessions UI 5a). Never a timer: how
/// long something has run says nothing the ring does not.
extension Tako.TabBarView {
    /// A quiet program's activity in this tab (Sessions UI 5a): of several
    /// panes, one whose output is arriving.
    func liveActivity(for window: NSWindow) -> Tako.LiveActivity? {
        let lives = surfaces(in: window).compactMap { $0.crab.live }
        return lives.first(where: \.isFlowing) ?? lives.first
    }

    /// How the text right of a pill's title is drawn.
    enum PillMetaStyle: Equatable {
        case dim
        /// A live program's rate: "38/s".
        case ember
        /// A failure's exit code: "exit 1" in a red chip.
        case exitCode
    }

    func pillMetaText(for window: NSWindow) -> String? {
        let state = pillSurfaceState(for: window)
        switch state {
        case .progress(let p):
            return "\(Int((p * 100).rounded()))%"
        case .failed:
            if case .failed(let code?) = aggregateCrab(for: window)?.state { return "exit \(code)" }
        case .live:
            return liveActivity(for: window)?.metaLabel
        default:
            break
        }
        return nil
    }

    func pillMetaStyle(for window: NSWindow) -> PillMetaStyle {
        switch pillSurfaceState(for: window) {
        case .failed:
            if case .failed(_?) = aggregateCrab(for: window)?.state { return .exitCode }
        case .live:
            if liveActivity(for: window)?.rateLabel != nil { return .ember }
        default:
            break
        }
        return .dim
    }

    // MARK: - Pill meta (Sessions UI 5a)

    static let exitChipFont = Tako.LivingTokens.monoFont(size: 9.5, weight: .semibold)
    static let exitChipPadding: CGFloat = 5

    func pillMetaWidth(_ text: String, style: PillMetaStyle) -> CGFloat {
        guard style == .exitCode else { return Tako.TabText.width(of: text, font: Fonts.timer) }
        return Tako.TabText.width(of: text, font: Self.exitChipFont) + 2 * Self.exitChipPadding
    }

    /// Progress, a live program's rate or name, or a failure's exit code
    /// in a red chip: 9.5pt semibold on Error at 12%, a 30% hairline, r4.
    func drawPillMeta(_ text: String, style: PillMetaStyle, atX x: CGFloat, centeredAtY midY: CGFloat, in ctx: CGContext) {
        switch style {
        case .dim, .ember:
            Tako.TabText.draw(text, atX: x, centeredAtY: midY, font: Fonts.timer,
                              color: style == .ember ? Tako.LivingTokens.ember : Palette.dim, context: ctx)
        case .exitCode:
            let error = Tako.LivingTokens.error
            let chip = CGRect(x: x, y: midY - 7, width: pillMetaWidth(text, style: .exitCode), height: 14)
            let path = CGPath(roundedRect: chip.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 4, cornerHeight: 4, transform: nil)
            ctx.addPath(path)
            ctx.setFillColor(error.withAlphaComponent(0.12).cgColor)
            ctx.fillPath()
            ctx.addPath(path)
            ctx.setStrokeColor(error.withAlphaComponent(0.3).cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()
            Tako.TabText.draw(text, atX: x + Self.exitChipPadding, centeredAtY: midY,
                              font: Self.exitChipFont, color: error, context: ctx)
        }
    }
}
