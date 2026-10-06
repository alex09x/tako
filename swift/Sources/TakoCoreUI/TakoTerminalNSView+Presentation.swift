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
    // MARK: - Redraw Scheduling & Display Link

    func startDisplayLink() {
        guard displayLink == nil, window != nil else { return }
        if #available(macOS 14.0, *) {
            let proxy = DisplayLinkProxy()
            proxy.owner = self
            let link = self.displayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick))
            link.isPaused = true
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    func cancelPresentationThrottle() {
        pendingPresentationThrottle?.cancel()
        pendingPresentationThrottle = nil
    }

    func armPresentationThrottle(after delay: TimeInterval) {
        guard delay > 0, delay.isFinite, !isPresentationPaused, window != nil,
              pendingPresentationThrottle == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingPresentationThrottle = nil
            self.drivePresentationIfNeeded()
        }
        pendingPresentationThrottle = work
        if let presentationThrottleSchedulerForTesting {
            presentationThrottleSchedulerForTesting(delay, work)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    /// A capped surface parks its display link between permits instead of
    /// polling every display tick.
    func drivePresentationIfNeeded() {
        guard !isDrivingPresentation else { return }
        isDrivingPresentation = true
        defer { isDrivingPresentation = false }
        guard !isPresentationPaused, redrawPending || presentationRetryPending else { return }
        if let delay = presentationRateLimiter.delayUntilPermit, delay > 0.000_000_001 {
            displayLink?.isPaused = true
            super.needsDisplay = false
            armPresentationThrottle(after: delay)
            return
        }
        if metalRenderer != nil, metalLayer != nil, let displayLink, window != nil {
            displayLink.isPaused = false
        } else {
            displayLink?.isPaused = true
            super.needsDisplay = true
        }
    }

    func claimPresentationPermit() -> Bool {
        guard presentationRateLimiter.claimPermit() else {
            redrawPending = true
            drivePresentationIfNeeded()
            return false
        }
        return true
    }

    // Deterministic scheduling seam for focused presentation tests.
    func setPresentationRateLimitClockForTesting(_ clock: @escaping () -> TimeInterval) {
        presentationRateLimiter.clock = clock
    }

    func setPresentationThrottleSchedulerForTesting(_ scheduler: @escaping (TimeInterval, DispatchWorkItem) -> Void) {
        presentationThrottleSchedulerForTesting = scheduler
    }

    var hasPresentationThrottleForTesting: Bool { pendingPresentationThrottle != nil }

    override public func setNeedsDisplay(_ invalidRect: NSRect) {
        redrawPending = true
        guard !isPresentationPaused else { return }
        super.setNeedsDisplay(invalidRect)
        drivePresentationIfNeeded()
    }

    override public var needsDisplay: Bool {
        get { super.needsDisplay }
        set {
            if newValue {
                redrawPending = true
                guard !isPresentationPaused else { return }
                super.needsDisplay = true
                drivePresentationIfNeeded()
            } else {
                super.needsDisplay = false
            }
        }
    }

    /// Ask for a frame. Public so a host driving its own PTY can mark the
    /// surface dirty without reaching into the renderer.
    public func scheduleRedraw() {
        redrawPending = true
        guard !isPresentationPaused else { return }
        drivePresentationIfNeeded()
        refreshHoveredLink()
    }

    func armPresentationRetry() {
        presentationRetryPending = true
        guard !isPresentationPaused else { return }
        drivePresentationIfNeeded()
    }

    func resumePresentationIfNeeded() {
        guard redrawPending || presentationRetryPending else { return }
        drivePresentationIfNeeded()
    }

    func displayLinkFired() {
        guard !isPresentationPaused else {
            displayLink?.isPaused = true
            return
        }
        guard redrawPending || presentationRetryPending else {
            displayLink?.isPaused = true
            return
        }
        guard metalRenderer != nil, metalLayer != nil else {
            displayLink?.isPaused = true
            super.needsDisplay = true
            return
        }
        redrawNow()
    }

    public func redrawNow() {
        guard !isPresentationPaused else { return }
        let wasRedrawPending = redrawPending
        guard !core.isSynchronizedOutputActive() else {
            redrawPending = false
            if wasRedrawPending || presentationRetryPending {
                redrawHeldBySynchronizedOutput = true
            }
            displayLink?.isPaused = true
            return
        }
        guard claimPresentationPermit() else { return }
        cancelPresentationThrottle()
        redrawPending = false
        guard let metalRenderer, let metalLayer else { return clearPresentationRetry() }
        guard bounds.width >= 1, bounds.height >= 1 else { return clearPresentationRetry() }

        metalRenderer.planner.isFocused = (window?.firstResponder === self)
        metalRenderer.planner.cursorBlinkPhaseOn = theme.cursorBlink ? blinkStateVisible : true
        let frame = currentRenderFrame()
        let layout = gridLayout
        let scale = Float(metalLayer.contentsScale)
        metalRenderer.planner.margins = TerminalMetalMargins(
            left: Float(layout.left) * scale,
            top: Float(layout.top) * scale,
            right: Float(layout.right(in: bounds.size)) * scale,
            bottom: Float(layout.bottom(in: bounds.size)) * scale,
            fill: Self.marginFill(theme.windowPaddingColor)
        )
        let stats = metalRenderer.render(
            frame: frame,
            in: metalLayer,
            overscanRows: frameOverscanRows,
            verticalPixelOffset: presentedVerticalPixelOffset + Float(layout.top) * scale,
            horizontalPixelOffset: Float(layout.left) * scale
        )
        lastFrameStatistics = stats

        if stats.presentation.leavesStalePixels {
            unpresentedFrameCount += 1
            TakoLog.render.debug("frame not presented (\(String(describing: stats.presentation))) → retry")
            armPresentationRetry()
        } else {
            clearPresentationRetry()
        }
        if customShaderKeepsAnimating {
            scheduleRedraw()
        }
        refreshHoveredLink()
    }

    /// Custom shaders are running and `custom-shader-animation` wants
    /// frames in the current focus state.
    var customShaderKeepsAnimating: Bool {
        guard metalRenderer?.customShaders.isEmpty == false else { return false }
        return theme.customShaderAnimation.keepsAnimating(isFocused: window?.firstResponder === self)
    }

    func clearPresentationRetry() {
        unpresentedFrameCount = 0
        presentationRetryPending = false
    }

    func currentRenderFrame() -> FfiRenderFrame {
        frameFetchCount += 1
        if isOutputFilterActive {
            frameOverscanRows = 0
            return filteredRenderFrame()
        }
        guard presentedSubCellRows != 0 else {
            frameOverscanRows = 0
            return core.renderFrame()
        }
        let overscan = core.renderFrameOverscan(rowsBelow: 1)
        frameOverscanRows = Int(overscan.overscanRows)
        return FfiRenderFrame(
            snapshot: overscan.snapshot,
            packedCells: overscan.packedCells,
            epoch: overscan.epoch,
            graphemes: overscan.graphemes
        )
    }

    /// The current sub-row translation, in drawable pixels, negative upward.
    var presentedVerticalPixelOffset: Float {
        guard presentedSubCellRows != 0, frameOverscanRows > 0,
              let metrics = metalRenderer?.planner.metrics else { return 0 }
        return Float(presentedSubCellRows) * metrics.pixelCellHeight
    }
}
#endif
