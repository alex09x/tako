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
import OSLog

#if canImport(UIKit)
import UIKit

extension TakoTerminalView {
    func applyCheckpointRestore(_ restore: TerminalCheckpointRestore) {
        pendingResizeWorkItem?.cancel()
        pendingResizeWorkItem = nil
        pendingGridSize = nil

        cancelKineticScroll()

        cols = restore.cols
        rows = restore.rows
        lastReportedScrollPosition = core.scrollPosition()
        TakoLog.resize.info("checkpoint restored \(restore.cols)×\(restore.rows)")
        delegate?.terminalView(self, didRestoreCheckpoint: restore)
        delegate?.terminalViewDidChangeContent(self)
        setNeedsDisplay()
    }

    func sendQueuedReplies() {
        let queued = core.takeOutput()
        if !queued.isEmpty {
            delegate?.terminalView(self, sendDeviceReplyData: queued)
        }
    }

    func apply(_ outcomes: [FfiFeedOutcome]) {
        var totalDamage = false
        for outcome in outcomes {
            if !outcome.output.isEmpty {
                delegate?.terminalView(self, sendDeviceReplyData: outcome.output)
            }

            for event in outcome.events {
                switch event {
                case .titleChanged(let title):
                    TakoLog.feed.info("title → \"\(title)\"")
                    delegate?.terminalView(self, didChangeTitle: title)
                case .bell:
                    TakoLog.feed.debug("bell")
                    delegate?.terminalViewDidBell(self)
                case .commandStart:
                    delegate?.terminalViewCommandDidStart(self)
                case .commandEnd(let exitCode):
                    delegate?.terminalView(self, commandDidEnd: exitCode)
                case .clipboardSet(let text):
                    TakoLog.feed.info("OSC 52 → clipboard (\(text.count) chars)")
                    delegate?.terminalView(self, didRequestClipboardCopy: text)
                case .pwdChanged(let url):
                    delegate?.terminalView(self, didChangeWorkingDirectory: url)
                default:
                    break
                }
            }

            if outcome.hasDamage && !outcome.synchronizedOutputActive {
                totalDamage = true
                setNeedsDisplay()
            }
        }
        if isKineticScrolling, let initialModes = kineticInitialModes {
            let currentModes = core.modes()
            if currentModes.alternateScreen != initialModes.alternateScreen
                || currentModes.mouseTracking != initialModes.mouseTracking
                || currentModes.alternateScroll != initialModes.alternateScroll
                || currentModes.cursorKeyAppMode != initialModes.cursorKeyAppMode
                || core.isSynchronizedOutputActive() {
                cancelKineticScroll()
            }
        }
        if redrawHeldBySynchronizedOutput && !core.isSynchronizedOutputActive() {
            redrawHeldBySynchronizedOutput = false
            setNeedsDisplay()
        }
        if totalDamage {
            TakoLog.render.debug("damage → setNeedsDisplay (\(outcomes.count) outcomes)")
            delegate?.terminalViewDidChangeContent(self)
            notifyScrollPositionIfChanged()
        }
    }

    func notifyScrollPositionIfChanged() {
        let position = core.scrollPosition()
        guard abs(position - lastReportedScrollPosition) > 0.0001 else { return }
        lastReportedScrollPosition = position
        delegate?.terminalView(self, didScrollTo: position)
    }
}
#endif
