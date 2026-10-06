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
    public func updateProgressBar(state: ProgressState, progress: Int?) {
        activeProgressState = state
        activeProgressValue = progress
        updateProgressBarLayout()
    }

    /// Positions and styles the pane progress bar according to current state and geometry.
    public func updateProgressBarLayout() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard paneProgressBarEnabled, activeProgressState != .none else {
            paneProgressBarLayer.isHidden = true
            return
        }

        let barHeight: CGFloat = 2.0
        let topY: CGFloat
        if stickyCommandHeaderEnabled && !stickyHeaderLayer.isHidden {
            topY = stickyHeaderLayer.frame.minY - barHeight
        } else {
            topY = bounds.height - barHeight
        }

        let fullWidth = bounds.width
        let barWidth: CGFloat
        let barX: CGFloat
        let barColor: CGColor

        switch activeProgressState {
        case .none:
            paneProgressBarLayer.isHidden = true
            return
        case .normal:
            let pct = CGFloat(min(100, max(0, activeProgressValue ?? 0))) / 100.0
            barWidth = max(2.0, fullWidth * pct)
            barX = 0
            barColor = NSColor(srgbRed: 0x7B / 255, green: 0xD8 / 255, blue: 0x8F / 255, alpha: 1).cgColor
        case .error:
            let pct = CGFloat(min(100, max(0, activeProgressValue ?? 100))) / 100.0
            barWidth = max(2.0, fullWidth * pct)
            barX = 0
            barColor = NSColor(srgbRed: 0xD5 / 255, green: 0x4E / 255, blue: 0x53 / 255, alpha: 1).cgColor
        case .paused:
            let pct = CGFloat(min(100, max(0, activeProgressValue ?? 100))) / 100.0
            barWidth = max(2.0, fullWidth * pct)
            barX = 0
            barColor = NSColor.systemOrange.cgColor
        case .indeterminate:
            barWidth = fullWidth * 0.35
            barX = (fullWidth - barWidth) / 2
            barColor = NSColor(srgbRed: 0xF4 / 255, green: 0x58 / 255, blue: 0x1C / 255, alpha: 1).cgColor
        }

        paneProgressBarLayer.isHidden = false
        paneProgressBarLayer.frame = CGRect(x: barX, y: max(0, topY), width: barWidth, height: barHeight)
        paneProgressBarLayer.backgroundColor = barColor
    }
}
#endif
