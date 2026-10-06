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

extension TakoTerminalNSView {
    /// Reset terminal state.
    public func reset() {
        trackedCommands.removeAll()
        trackedCommandsEpoch = core.stateEpoch()
        activeRunningCommandId = nil
        parserCoordinator.feedSynchronously(Data("\u{001B}c".utf8))
        scheduleRedraw()
    }

    /// Clear screen.
    public func clearScreen() {
        feed(data: Data("\u{1b}[2J\u{1b}[H".utf8))
        scheduleRedraw()
    }

    /// Everything the terminal holds as plain text.
    public var bufferText: String {
        core.bufferText()
    }

    /// Where the viewport sits, 0 (oldest retained line) to 1 (live screen).
    public var scrollPosition: Double {
        get { core.scrollPosition() }
        set {
            core.setScrollPosition(position: newValue)
            notifyScrollPositionIfChanged()
            scheduleRedraw()
        }
    }

    /// Query scroll offset.
    public var viewportOffset: Int {
        Int(core.viewportOffset())
    }

    /// Query total scrollback length in lines.
    public var scrollbackLength: Int {
        Int(core.scrollbackLen())
    }

    /// Scroll viewport up by lines.
    public func scrollViewportUp(lines: Int = 1) {
        if isOutputFilterActive {
            let maxOffset = max(0, outputFilterMatchingLines.count - Int(core.rows()))
            outputFilterScrollOffset = min(maxOffset, outputFilterScrollOffset + max(lines, 1))
            updateScroller()
            scheduleRedraw()
            return
        }
        core.scrollViewportUp(lines: UInt32(max(lines, 1)))
        notifyScrollPositionIfChanged()
        scheduleRedraw()
    }

    /// Scroll viewport down by lines.
    public func scrollViewportDown(lines: Int = 1) {
        if isOutputFilterActive {
            outputFilterScrollOffset = max(0, outputFilterScrollOffset - max(lines, 1))
            updateScroller()
            scheduleRedraw()
            return
        }
        core.scrollViewportDown(lines: UInt32(max(lines, 1)))
        notifyScrollPositionIfChanged()
        scheduleRedraw()
    }

    /// Snap scroll to bottom (live screen).
    public func scrollViewportToBottom() {
        if isOutputFilterActive {
            outputFilterScrollOffset = 0
            updateScroller()
            scheduleRedraw()
            return
        }
        core.scrollViewportBottom()
        notifyScrollPositionIfChanged()
        scheduleRedraw()
    }

    /// Scroll to specific viewport offset.
    public func scrollToOffset(_ offset: Int) {
        if isOutputFilterActive {
            let maxOffset = max(0, outputFilterMatchingLines.count - Int(core.rows()))
            outputFilterScrollOffset = max(0, min(offset, maxOffset))
            updateScroller()
            scheduleRedraw()
            return
        }
        core.scrollViewportBottom()
        if offset > 0 {
            core.scrollViewportUp(lines: UInt32(offset))
        }
        notifyScrollPositionIfChanged()
        scheduleRedraw()
    }

    /// Jump viewport to previous verified prompt marker, or fall back to scrolling up one page.
    @discardableResult
    @objc open func jumpToPreviousPrompt(_ sender: Any? = nil) -> Bool {
        if core.scrollToPreviousPrompt() {
            notifyScrollPositionIfChanged()
            scheduleRedraw()
            return true
        }
        scrollViewportUp(lines: max(1, Int(core.rows())))
        return false
    }

    /// Jump viewport to next verified prompt marker, or fall back to scrolling down one page.
    @discardableResult
    @objc open func jumpToNextPrompt(_ sender: Any? = nil) -> Bool {
        if core.scrollToNextPrompt() {
            notifyScrollPositionIfChanged()
            scheduleRedraw()
            return true
        }
        scrollViewportDown(lines: max(1, Int(core.rows())))
        return false
    }

    /// Select the exact output of the current or previous command cleanly bounded by prompt marks.
    @discardableResult
    @objc open func selectCommandOutput(_ sender: Any? = nil) -> Bool {
        if core.selectCommandOutput() {
            notifyScrollPositionIfChanged()
            scheduleRedraw()
            return true
        }
        return false
    }

    /// Obtain bounded plain text starting at startRow for maxRows lines.
    public func plainText(startRow: Int = 0, maxRows: Int = 100) -> String {
        if isOutputFilterActive {
            let totalMatches = outputFilterMatchingLines.count
            guard totalMatches > 0 else { return "" }
            let totalRows = Int(core.rows())
            let maxOffset = max(0, totalMatches - totalRows)
            let clampedOffset = max(0, min(outputFilterScrollOffset, maxOffset))
            let startIndex = max(0, totalMatches - totalRows - clampedOffset)
            let endIndex = min(totalMatches, startIndex + totalRows)
            let slice = Array(outputFilterMatchingLines[startIndex..<endIndex])
            let effectiveStart = min(startRow, slice.count)
            let effectiveCount = min(maxRows, slice.count - effectiveStart)
            guard effectiveCount > 0 else { return "" }
            return slice[effectiveStart..<(effectiveStart + effectiveCount)].map(\.text).joined(separator: "\n")
        }
        let totalRows = Int(core.rows())
        let start = max(startRow, 0)
        guard start < totalRows else { return "" }
        let maxR = max(maxRows, 1)
        return core.getPlainText(startRow: UInt32(start), maxRows: UInt32(maxR))
    }

    /// Current selection text.
    public var selectedText: String? {
        core.selectedText()
    }
}
#endif
