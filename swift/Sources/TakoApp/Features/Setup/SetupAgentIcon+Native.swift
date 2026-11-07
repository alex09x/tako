/*
 * tako — Native agent fallback artwork
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit

extension SetupAgentIconResolver {
    /// Original small Q and M artwork; these are not vendor logos.
    nonisolated static func drawNativeGlyph(provider: SetupAgentProvider, in rect: CGRect, context: CGContext) {
        let w = rect.width
        let h = rect.height
        context.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                               cornerWidth: w * 0.22, cornerHeight: h * 0.22, transform: nil))
        context.setFillColor(provider == .qwen
            ? CGColor(red: 0.45, green: 0.25, blue: 0.8, alpha: 1)
            : CGColor(red: 0.05, green: 0.5, blue: 0.6, alpha: 1))
        context.fillPath()
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(w * 0.12)
        if provider == .qwen {
            context.strokeEllipse(in: rect.insetBy(dx: w * 0.25, dy: h * 0.25))
            context.move(to: CGPoint(x: w * 0.55, y: h * 0.45))
            context.addLine(to: CGPoint(x: w * 0.8, y: h * 0.2))
        } else {
            context.move(to: CGPoint(x: w * 0.22, y: h * 0.25))
            for (x, y) in [(0.22, 0.75), (0.5, 0.45), (0.78, 0.75), (0.78, 0.25)] {
                context.addLine(to: CGPoint(x: w * x, y: h * y))
            }
        }
        context.strokePath()
    }
}
