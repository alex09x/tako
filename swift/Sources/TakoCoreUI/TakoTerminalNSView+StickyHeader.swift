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
    /// Updates the pinned sticky command header layer based on current viewport offset and command marks.
    func updateStickyCommandHeader() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer {
            updateProgressBarLayout()
            CATransaction.commit()
        }

        guard stickyCommandHeaderEnabled, !core.modes().alternateScreen else {
            stickyHeaderLayer.isHidden = true
            activeStickyCommandHeader = nil
            return
        }

        guard let header = currentStickyCommandHeader() else {
            stickyHeaderLayer.isHidden = true
            activeStickyCommandHeader = nil
            return
        }

        activeStickyCommandHeader = header

        let layout = gridLayout
        let headerHeight = max(cellHeight, 22.0)
        let headerY = bounds.height - layout.top - headerHeight
        stickyHeaderLayer.frame = CGRect(x: 0, y: headerY, width: bounds.width, height: headerHeight)
        stickyHeaderLayer.isHidden = false
        stickyHeaderLayer.backgroundColor = stickyHeaderBackgroundColor(hovering: isHoveringStickyHeader)

        stickyHeaderSeparatorLayer.frame = CGRect(x: 0, y: 0, width: bounds.width, height: 1.0)
        stickyHeaderSeparatorLayer.backgroundColor = stickyHeaderSeparatorColor()

        let indicatorSize: CGFloat = 7.0
        let indicatorX = max(layout.left, 6.0)
        let indicatorY = (headerHeight - indicatorSize) / 2.0
        stickyHeaderIndicatorLayer.frame = CGRect(x: indicatorX, y: indicatorY, width: indicatorSize, height: indicatorSize)

        let indicatorColor: CGColor
        switch header.status {
        case 1: indicatorColor = NSColor.systemGreen.cgColor
        case 2: indicatorColor = NSColor.systemRed.cgColor
        default: indicatorColor = NSColor.systemBlue.cgColor
        }
        stickyHeaderIndicatorLayer.backgroundColor = indicatorColor

        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        stickyHeaderTextLayer.contentsScale = scale
        stickyHeaderHintLayer.contentsScale = scale

        let textX = indicatorX + indicatorSize + 8.0
        let hintWidth: CGFloat = 110.0
        let availableWidth = max(0, bounds.width - textX - hintWidth - 20.0)
        stickyHeaderTextLayer.frame = CGRect(x: textX, y: (headerHeight - 16.0) / 2.0, width: availableWidth, height: 16.0)

        let font = NSFont.monospacedSystemFont(ofSize: min(theme.fontSize, 12.0), weight: .semibold)
        stickyHeaderTextLayer.font = font
        stickyHeaderTextLayer.fontSize = font.pointSize
        stickyHeaderTextLayer.foregroundColor = stickyHeaderTextColor()
        stickyHeaderTextLayer.string = header.command

        let hintFont = NSFont.systemFont(ofSize: 10.0, weight: .regular)
        stickyHeaderHintLayer.font = hintFont
        stickyHeaderHintLayer.fontSize = hintFont.pointSize
        stickyHeaderHintLayer.foregroundColor = stickyHeaderHintColor(hovering: isHoveringStickyHeader)
        let hintX = max(textX + availableWidth, bounds.width - hintWidth - 16.0)
        stickyHeaderHintLayer.frame = CGRect(x: hintX, y: (headerHeight - 14.0) / 2.0, width: hintWidth, height: 14.0)
    }

    func updateStickyHeaderHover(_ hovering: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        stickyHeaderLayer.backgroundColor = stickyHeaderBackgroundColor(hovering: hovering)
        stickyHeaderHintLayer.foregroundColor = stickyHeaderHintColor(hovering: hovering)
    }

    var isLightTheme: Bool {
        guard let bg = NSColor(cgColor: theme.background)?.usingColorSpace(.sRGB) else {
            return false
        }
        let luminance = 0.2126 * bg.redComponent + 0.7152 * bg.greenComponent + 0.0722 * bg.blueComponent
        return luminance > 0.5
    }

    func stickyHeaderBackgroundColor(hovering: Bool) -> CGColor {
        if isLightTheme {
            let base = NSColor(cgColor: theme.background) ?? NSColor.white
            let fraction: CGFloat = hovering ? 0.14 : 0.06
            let blended = base.blended(withFraction: fraction, of: .black)
                ?? (hovering ? NSColor(white: 0.86, alpha: 0.98) : NSColor(white: 0.94, alpha: 0.96))
            return blended.withAlphaComponent(hovering ? 0.98 : 0.95).cgColor
        } else {
            let base = NSColor(cgColor: theme.background) ?? NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.14, alpha: 1.0)
            let fraction: CGFloat = hovering ? 0.16 : 0.08
            let blended = base.blended(withFraction: fraction, of: .white)
                ?? (hovering ? NSColor(calibratedRed: 0.16, green: 0.16, blue: 0.20, alpha: 0.98) : NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.14, alpha: 0.94))
            return blended.withAlphaComponent(hovering ? 0.98 : 0.94).cgColor
        }
    }

    func stickyHeaderTextColor() -> CGColor {
        theme.foreground
    }

    func stickyHeaderHintColor(hovering: Bool) -> CGColor {
        if isLightTheme {
            let fg = NSColor(cgColor: theme.foreground) ?? NSColor.black
            return fg.withAlphaComponent(hovering ? 0.85 : 0.55).cgColor
        } else {
            let fg = NSColor(cgColor: theme.foreground) ?? NSColor.white
            return fg.withAlphaComponent(hovering ? 0.85 : 0.5).cgColor
        }
    }

    func stickyHeaderSeparatorColor() -> CGColor {
        if isLightTheme {
            return NSColor.black.withAlphaComponent(0.12).cgColor
        } else {
            return NSColor.white.withAlphaComponent(0.15).cgColor
        }
    }

    /// Jumps the viewport so that the given retained prompt row is pinned at the top.
    public func jumpToPrompt(retainedRow: UInt64) {
        let totalScrollback = Int(core.scrollbackLen())
        let targetOffset = max(0, totalScrollback - Int(retainedRow))
        scrollToOffset(targetOffset)
        updateScroller()
    }
}
#endif
