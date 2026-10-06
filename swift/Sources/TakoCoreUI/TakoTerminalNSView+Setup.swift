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
    func setupView() {
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.addSublayer(linkUnderlineLayer)
        if NSApp != nil {
            registerForDraggedTypes([.fileURL, .string])
        }

        triggerHighlightsLayer.zPosition = 8500
        triggerHighlightsLayer.masksToBounds = true
        self.layer?.addSublayer(triggerHighlightsLayer)

        gutterMarksLayer.zPosition = 9000
        gutterMarksLayer.masksToBounds = true
        self.layer?.addSublayer(gutterMarksLayer)

        stickyHeaderLayer.zPosition = 9500
        stickyHeaderLayer.masksToBounds = true
        stickyHeaderLayer.isHidden = true
        stickyHeaderLayer.backgroundColor = stickyHeaderBackgroundColor(hovering: false)

        stickyHeaderSeparatorLayer.backgroundColor = stickyHeaderSeparatorColor()
        stickyHeaderLayer.addSublayer(stickyHeaderSeparatorLayer)

        stickyHeaderIndicatorLayer.cornerRadius = 3.5
        stickyHeaderIndicatorLayer.masksToBounds = true
        stickyHeaderLayer.addSublayer(stickyHeaderIndicatorLayer)

        stickyHeaderTextLayer.truncationMode = .end
        stickyHeaderTextLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        stickyHeaderLayer.addSublayer(stickyHeaderTextLayer)

        stickyHeaderHintLayer.string = "Jump to prompt ↑"
        stickyHeaderHintLayer.alignmentMode = .right
        stickyHeaderHintLayer.foregroundColor = stickyHeaderHintColor(hovering: false)
        stickyHeaderHintLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        stickyHeaderLayer.addSublayer(stickyHeaderHintLayer)

        self.layer?.addSublayer(stickyHeaderLayer)

        paneProgressBarLayer.zPosition = 9500
        paneProgressBarLayer.masksToBounds = true
        paneProgressBarLayer.isHidden = true
        self.layer?.addSublayer(paneProgressBarLayer)

        contextTintLayer.zPosition = 8000
        contextTintLayer.masksToBounds = true
        contextTintLayer.isHidden = true
        self.layer?.addSublayer(contextTintLayer)

        contextBreadcrumbsLayer.zPosition = 9600
        contextBreadcrumbsLayer.masksToBounds = true
        contextBreadcrumbsLayer.cornerRadius = 4.0
        contextBreadcrumbsLayer.borderWidth = 0.5
        contextBreadcrumbsLayer.borderColor = NSColor(white: 1.0, alpha: 0.15).cgColor
        contextBreadcrumbsLayer.backgroundColor = NSColor.black.withAlphaComponent(0.65).cgColor
        contextBreadcrumbsTextLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        contextBreadcrumbsTextLayer.alignmentMode = .center
        contextBreadcrumbsTextLayer.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
        contextBreadcrumbsTextLayer.fontSize = 10
        contextBreadcrumbsTextLayer.foregroundColor = NSColor(white: 0.9, alpha: 1.0).cgColor
        contextBreadcrumbsLayer.addSublayer(contextBreadcrumbsTextLayer)
        contextBreadcrumbsLayer.isHidden = true
        self.layer?.addSublayer(contextBreadcrumbsLayer)

        linkHUDLayer.addSublayer(linkHUDTextLayer)
        self.layer?.addSublayer(linkHUDLayer)

        scrollbarLayer.zPosition = 9999
        scrollbarLayer.backgroundColor = NSColor(white: 0.05, alpha: 0.3).cgColor
        scrollbarLayer.cornerRadius = 5.0
        scrollbarLayer.masksToBounds = true
        scrollbarMarksLayer.zPosition = 10
        scrollbarMarksLayer.masksToBounds = true
        scrollbarLayer.addSublayer(scrollbarMarksLayer)
        scrollbarKnob.zPosition = 20
        scrollbarKnob.cornerRadius = 3.5
        scrollbarKnob.backgroundColor = NSColor.white.withAlphaComponent(0.4).cgColor
        scrollbarLayer.addSublayer(scrollbarKnob)
        scrollbarLayer.opacity = 1.0
        self.layer?.addSublayer(scrollbarLayer)

        parserCoordinator.setMainApplicationHandler { [weak self] outcomes in
            MainActor.assumeIsolated { self?.apply(outcomes) }
        }
        parserCoordinator.setCheckpointRestoreHandler { [weak self] restore in
            MainActor.assumeIsolated { self?.applyCheckpointRestore(restore) }
        }
        parserCoordinator.setResizeHandler { [weak self] cols, rows in
            MainActor.assumeIsolated { self?.applyOrderedResize(cols: cols, rows: rows) }
        }
        rebuildMetalRenderer()
        setupAccessibility()
        startBlinkTimer()
    }

    func setupAccessibility() {
        setAccessibilityIdentifier("terminal")
    }
}
#endif
