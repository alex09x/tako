/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import QuartzCore

extension TakoTerminalNSView {
    func parseHexColor(_ hex: String) -> NSColor? {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let rgb = UInt64(s, radix: 16) else { return nil }
        let r = CGFloat((rgb >> 16) & 0xFF) / 255.0
        let g = CGFloat((rgb >> 8) & 0xFF) / 255.0
        let b = CGFloat(rgb & 0xFF) / 255.0
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }

    public func refreshContextVisuals() {
        updateContextState()
    }

    public func updateContextState() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let frames = core.contextStack()
        if frames.isEmpty {
            contextBreadcrumbsLayer.isHidden = true
        } else {
            contextBreadcrumbsLayer.isHidden = false
            let breadcrumbs = frames.map { frame in
                if frame.kind.isEmpty { return frame.name }
                return "\(frame.kind):\(frame.name)"
            }.joined(separator: " › ")

            contextBreadcrumbsTextLayer.string = breadcrumbs

            let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
            let attrStr = NSAttributedString(string: breadcrumbs, attributes: [.font: font])
            let textSize = attrStr.size()
            let paddingX: CGFloat = 8
            let paddingY: CGFloat = 4
            let pillWidth = ceil(textSize.width) + paddingX * 2
            let pillHeight = ceil(textSize.height) + paddingY * 2

            let topMargin: CGFloat = 8
            let rightMargin: CGFloat = (paneProgressBarEnabled && activeProgressState != .none ? 14 : 10)
            let x = max(8, bounds.width - pillWidth - rightMargin)
            let y = bounds.height - pillHeight - topMargin

            contextBreadcrumbsLayer.frame = CGRect(x: x, y: max(0, y), width: pillWidth, height: pillHeight)
            contextBreadcrumbsTextLayer.frame = CGRect(x: paddingX, y: paddingY, width: pillWidth - paddingX * 2, height: textSize.height)

            if core.isElevated() {
                contextBreadcrumbsLayer.borderColor = NSColor(srgbRed: 0xEA / 255, green: 0x58 / 255, blue: 0x0C / 255, alpha: 0.7).cgColor
                contextBreadcrumbsTextLayer.foregroundColor = NSColor(srgbRed: 0xFF / 255, green: 0x8C / 255, blue: 0x42 / 255, alpha: 1.0).cgColor
            } else {
                contextBreadcrumbsLayer.borderColor = NSColor(white: 1.0, alpha: 0.15).cgColor
                contextBreadcrumbsTextLayer.foregroundColor = NSColor(white: 0.9, alpha: 1.0).cgColor
            }
        }

        let isElevated = core.isElevated()
        let activeTintHex = core.activeTint()
        if isElevated || activeTintHex != nil {
            let tintColor: NSColor = {
                if let hex = activeTintHex, let parsed = parseHexColor(hex) {
                    return parsed
                }
                return NSColor(srgbRed: 0xEA / 255, green: 0x58 / 255, blue: 0x0C / 255, alpha: 1.0)
            }()
            contextTintLayer.isHidden = false
            contextTintLayer.frame = bounds
            contextTintLayer.backgroundColor = tintColor.withAlphaComponent(0.06).cgColor
            contextTintLayer.borderWidth = 1.5
            contextTintLayer.borderColor = tintColor.withAlphaComponent(0.4).cgColor
        } else {
            contextTintLayer.isHidden = true
        }
    }
}
#endif
