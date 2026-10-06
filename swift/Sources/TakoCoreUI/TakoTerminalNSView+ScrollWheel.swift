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
    override open func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        lastMousePoint = point
        mouseCell = cellAt(point)
        if scrollbarLayer.frame.contains(point) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            scrollbarKnob.backgroundColor = NSColor.white.withAlphaComponent(0.65).cgColor
            CATransaction.commit()
        } else if !isDraggingScrollbar {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            scrollbarKnob.backgroundColor = scrollbackLength == 0
                ? NSColor.white.withAlphaComponent(0.15).cgColor
                : NSColor.white.withAlphaComponent(0.45).cgColor
            CATransaction.commit()
        }
        if stickyCommandHeaderEnabled && !stickyHeaderLayer.isHidden && stickyHeaderLayer.frame.contains(point) {
            if !isHoveringStickyHeader {
                isHoveringStickyHeader = true
                updateStickyHeaderHover(true)
            }
            NSCursor.pointingHand.set()
            return
        } else if isHoveringStickyHeader {
            isHoveringStickyHeader = false
            updateStickyHeaderHover(false)
            NSCursor.arrow.set()
        }
        refreshHoveredLink(commandHeld: event.modifierFlags.contains(.command))
        if point.x < gridLayout.left, let cell = mouseCell, let markInfo = gutterCommandMarksByRow[cell.row] {
            var tooltipLines: [String] = []
            let statusStr: String = {
                switch markInfo.status {
                case 0: return "running"
                case 1: return "exit 0"
                case 2:
                    if let code = markInfo.exitCode {
                        return "exit \(code)"
                    }
                    return "failed"
                default: return "unknown"
                }
            }()
            tooltipLines.append("Command #\(markInfo.commandId): \(statusStr)")
            if let dur = markInfo.duration {
                tooltipLines.append("Duration: \(Self.formatDuration(dur))")
            } else if markInfo.status == 0, let started = markInfo.startedAt {
                tooltipLines.append("Duration: \(Self.formatDuration(Date().timeIntervalSince(started))) (running)")
            }
            if let started = markInfo.startedAt {
                tooltipLines.append("Started: \(Self.formatStartTime(started))")
            }
            self.toolTip = tooltipLines.joined(separator: "\n")
        }
        if let cell = mouseCell {
            let report = mouseReportBytes(button: .none, action: .motion, cell: cell, event: event)
            if !report.isEmpty {
                delegate?.terminalView(self, sendInputData: report)
                return
            }
        }
        super.mouseMoved(with: event)
    }

    override open func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
    }

    override open func mouseExited(with event: NSEvent) {
        if isHoveringStickyHeader {
            isHoveringStickyHeader = false
            updateStickyHeaderHover(false)
        }
        lastMousePoint = nil
        clearHoveredLink()
        super.mouseExited(with: event)
    }

    var presentedSubCellRows: CGFloat { subCellScroll.presentedRows }

    public var presentedScrollRows: CGFloat {
        CGFloat(viewportOffset) + subCellScroll.presentedRows
    }

    var pendingWheelReportSteps: CGFloat { wheelReports.residualSteps }

    static let pointsPerScrolledLine: CGFloat = 3

    override open func scrollWheel(with event: NSEvent) {
        if event.phase.contains(.began) {
            subCellScroll.begin()
            wheelReports.begin()
        }

        let cell = cellAt(convert(event.locationInWindow, from: nil))

        let reportsToProgram = !mouseReportBytes(
            button: .wheelUp,
            action: .press,
            cell: cell,
            event: event
        ).isEmpty

        if reportsToProgram {
            subCellScroll.clear()
            let lines = event.hasPreciseScrollingDeltas
                ? wheelReports.accumulatePrecise(
                    deltaY: event.scrollingDeltaY,
                    pointsPerStep: Self.pointsPerScrolledLine,
                    maximumSteps: TerminalTouchScrollDecision.maxLinesPerGestureCallback)
                : wheelReports.accumulateNotched(
                    deltaY: event.scrollingDeltaY,
                    maximumSteps: TerminalTouchScrollDecision.maxLinesPerGestureCallback)
            guard lines != 0 else { return }
            let singleReport = mouseReportBytes(
                button: lines > 0 ? .wheelUp : .wheelDown,
                action: .press,
                cell: cell,
                event: event
            )
            guard !singleReport.isEmpty else { return }
            var reports = Data()
            for _ in 0..<abs(lines) { reports.append(singleReport) }
            delegate?.terminalView(self, sendInputData: reports)
            return
        }

        let modes = core.modes()
        if modes.alternateScreen && modes.alternateScroll {
            subCellScroll.clear()
            let lines = event.hasPreciseScrollingDeltas
                ? wheelReports.accumulatePrecise(
                    deltaY: event.scrollingDeltaY,
                    pointsPerStep: Self.pointsPerScrolledLine,
                    maximumSteps: TerminalTouchScrollDecision.maxLinesPerGestureCallback)
                : wheelReports.accumulateNotched(
                    deltaY: event.scrollingDeltaY,
                    maximumSteps: TerminalTouchScrollDecision.maxLinesPerGestureCallback)
            guard lines != 0 else { return }
            let key = FfiKeyEvent(
                key: lines > 0 ? .up : .down, text: "", physicalText: "", unshiftedText: "",
                shift: false, alt: false, ctrl: false, superKey: false,
                press: true, repeat: false, composing: false)
            let singleKey = core.encodeKey(event: key)
            guard !singleKey.isEmpty else { return }
            var keys = Data()
            for _ in 0..<abs(lines) { keys.append(singleKey) }
            delegate?.terminalView(self, sendInputData: keys)
            return
        }
        wheelReports.clear()

        let lines: Int
        if event.hasPreciseScrollingDeltas {
            lines = subCellScroll.accumulatePrecise(
                deltaY: event.scrollingDeltaY,
                pointsPerLine: Self.pointsPerScrolledLine
            )
        } else {
            lines = subCellScroll.accumulateNotched(deltaY: event.scrollingDeltaY)
        }

        let before = viewportOffset
        if lines > 0 {
            scrollViewportUp(lines: lines)
        } else if lines < 0 {
            scrollViewportDown(lines: -lines)
        }

        subCellScroll.settleAtBoundary(
            requestedRows: lines,
            offsetBefore: before,
            offsetAfter: viewportOffset
        )

        guard lines != 0 || presentedSubCellRows != 0 else { return }
        notifyScrollPositionIfChanged()
        scheduleRedraw()
        refreshHoveredLink()
    }
}
#endif
