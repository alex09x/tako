/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import CoreGraphics
import Foundation
import QuartzCore

#if canImport(UIKit)
import UIKit

extension TakoTerminalView {
    @objc func handleTap(_ gesture: UITapGestureRecognizer) {
        cancelKineticScroll()
        if autoFocusKeyboardOnTap && !isFirstResponder {
            _ = becomeFirstResponder()
        }
        if core.hasSelection() {
            core.clearSelection()
            setNeedsDisplay()
        }
    }

    @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard !isSelecting else { return }
        let translation = gesture.translation(in: self)
        let cellH = renderer.metrics.cellHeight
        let cellW = renderer.metrics.cellWidth
        guard cellH > 0, cellW > 0 else { return }

        switch gesture.state {
        case .began:
            cancelKineticScroll()
            panAccumulatedY = 0
        case .changed:
            panAccumulatedY += translation.y
            gesture.setTranslation(.zero, in: self)

            let lines = Int(abs(panAccumulatedY) / cellH)
            if lines >= 1 {
                let direction: TerminalPanDirection = panAccumulatedY > 0 ? .up : .down
                let point = gesture.location(in: self)
                let col = min(max(Int(point.x / cellW), 0), cols - 1)
                let row = min(max(Int(point.y / cellH), 0), rows - 1)

                let modes = core.modes()
                let action = TerminalTouchScrollDecision.decide(
                    lines: lines,
                    direction: direction,
                    modes: modes,
                    touchCol: col,
                    touchRow: row,
                    core: core
                )

                performTouchScrollAction(action)
                panAccumulatedY = panAccumulatedY.truncatingRemainder(dividingBy: cellH)
            }
        case .ended:
            let velocityY = gesture.velocity(in: self).y
            let point = gesture.location(in: self)
            panAccumulatedY = 0
            startKineticScroll(initialVelocityY: Double(velocityY), location: point)
        case .cancelled, .failed:
            panAccumulatedY = 0
            cancelKineticScroll()
        default:
            panAccumulatedY = 0
            cancelKineticScroll()
        }
    }

    @objc func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        let point = gesture.location(in: self)
        let cellW = renderer.metrics.cellWidth
        let cellH = renderer.metrics.cellHeight
        guard cellW > 0, cellH > 0 else { return }

        let col = min(max(Int(point.x / cellW), 0), cols - 1)
        let row = min(max(Int(point.y / cellH), 0), rows - 1)

        switch gesture.state {
        case .began:
            cancelKineticScroll()
            isSelecting = true
            core.startSelection(row: UInt32(row), col: UInt32(col), mode: .linear)
            setNeedsDisplay()
        case .changed:
            if isSelecting {
                core.extendSelection(row: UInt32(row), col: UInt32(col))
                setNeedsDisplay()
            }
        case .ended:
            isSelecting = false
            if core.hasSelection() {
                let activated = isFirstResponder || becomeFirstResponder()
                if activated {
                    showEditMenu(at: point)
                }
            }
        case .cancelled, .failed:
            isSelecting = false
        default:
            break
        }
    }

    func startKineticDisplayLink() {
        guard kineticDisplayLink == nil else { return }
        let proxy = KineticDisplayLinkProxy()
        proxy.owner = self
        let link = CADisplayLink(target: proxy, selector: #selector(KineticDisplayLinkProxy.tick(_:)))
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        kineticDisplayLink = link
    }

    func stopKineticDisplayLink() {
        kineticDisplayLink?.invalidate()
        kineticDisplayLink = nil
    }

    final class KineticDisplayLinkProxy: NSObject {
        weak var owner: TakoTerminalView?

        @objc func tick(_ link: CADisplayLink) {
            MainActor.assumeIsolated { owner?.kineticDisplayLinkFired(link) }
        }
    }

    public func startKineticScroll(initialVelocityY: Double, location: CGPoint) {
        cancelKineticScroll()
        guard window != nil || Self.allowOffscreenKineticStepForTesting else { return }
        guard !isSelecting else { return }

        let modes = core.modes()
        kineticInitialModes = modes
        kineticTouchLocation = location
        kineticDeceleration = TerminalKineticDeceleration(initialVelocity: initialVelocityY)

        if kineticDeceleration.isDecelerating {
            kineticDisplayLink?.isPaused = false
        }
    }

    public func cancelKineticScroll() {
        kineticDeceleration.cancel()
        kineticDisplayLink?.isPaused = true
        kineticInitialModes = nil
    }

    @objc func handleAppDidEnterBackground() {
        cancelKineticScroll()
    }

    func kineticDisplayLinkFired(_ link: CADisplayLink) {
        guard kineticDeceleration.isDecelerating else {
            kineticDisplayLink?.isPaused = true
            return
        }
        let dt: TimeInterval
        if link.targetTimestamp > link.timestamp {
            dt = link.targetTimestamp - link.timestamp
        } else {
            dt = 1.0 / 60.0
        }
        let clampedDt = min(max(dt, 1.0 / 120.0), 1.0 / 15.0)
        stepKineticScroll(deltaTime: clampedDt)
    }

    @discardableResult
    public func stepKineticScroll(deltaTime: TimeInterval) -> Bool {
        guard kineticDeceleration.isDecelerating else {
            cancelKineticScroll()
            return false
        }
        guard window != nil || Self.allowOffscreenKineticStepForTesting else {
            cancelKineticScroll()
            return false
        }
        guard !isSelecting else {
            cancelKineticScroll()
            return false
        }

        let cellH = renderer.metrics.cellHeight
        let cellW = renderer.metrics.cellWidth
        guard cellH > 0, cellW > 0 else {
            cancelKineticScroll()
            return false
        }

        let currentModes = core.modes()
        if let initialModes = kineticInitialModes {
            if currentModes.alternateScreen != initialModes.alternateScreen
                || currentModes.mouseTracking != initialModes.mouseTracking
                || currentModes.alternateScroll != initialModes.alternateScroll
                || currentModes.cursorKeyAppMode != initialModes.cursorKeyAppMode
                || core.isSynchronizedOutputActive() {
                cancelKineticScroll()
                return false
            }
        }

        guard let (lines, direction) = kineticDeceleration.step(deltaTime: deltaTime, cellHeight: Double(cellH)) else {
            if !kineticDeceleration.isDecelerating {
                cancelKineticScroll()
            }
            return false
        }

        let col = min(max(Int(kineticTouchLocation.x / cellW), 0), cols - 1)
        let row = min(max(Int(kineticTouchLocation.y / cellH), 0), rows - 1)

        let action = TerminalTouchScrollDecision.decide(
            lines: lines,
            direction: direction,
            modes: currentModes,
            touchCol: col,
            touchRow: row,
            core: core
        )

        let progressed = performTouchScrollAction(action)
        if !kineticDeceleration.isDecelerating {
            cancelKineticScroll()
        }
        return progressed
    }

    @discardableResult
    func performTouchScrollAction(_ action: TerminalTouchScrollAction) -> Bool {
        switch action {
        case .scrollViewportUp(let l):
            scrollViewportUp(lines: l)
            notifyScrollPositionIfChanged()
            if viewportOffset >= scrollbackLength {
                cancelKineticScroll()
                return false
            }
            return true
        case .scrollViewportDown(let l):
            scrollViewportDown(lines: l)
            notifyScrollPositionIfChanged()
            if viewportOffset <= 0 {
                cancelKineticScroll()
                return false
            }
            return true
        case .sendInput(let data):
            if !data.isEmpty {
                delegate?.terminalView(self, sendInputData: data)
                return true
            }
            return false
        case .none:
            cancelKineticScroll()
            return false
        }
    }

    func showEditMenu(at point: CGPoint) {
        let rect = CGRect(origin: point, size: CGSize(width: 1, height: 1))
        if #available(iOS 16.0, *) {
            let interaction: UIEditMenuInteraction
            if let existing = editMenuInteractionStorage as? UIEditMenuInteraction {
                interaction = existing
            } else {
                let menuDelegate = TakoTerminalViewEditMenuDelegate(terminalView: self)
                editMenuInteractionDelegateStorage = menuDelegate
                interaction = UIEditMenuInteraction(delegate: menuDelegate)
                addInteraction(interaction)
                editMenuInteractionStorage = interaction
            }
            let config = UIEditMenuConfiguration(identifier: nil, sourcePoint: point)
            interaction.presentEditMenu(with: config)
        } else {
            let menu = UIMenuController.shared
            menu.showMenu(from: self, rect: rect)
        }
    }
}
#endif
