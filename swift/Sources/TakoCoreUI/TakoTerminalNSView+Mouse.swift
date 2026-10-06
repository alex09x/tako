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
    // MARK: - Mouse Reporting

    public func mouseReportBytes(
        button: FfiMouseButton,
        action: FfiMouseAction,
        cell: (row: Int, col: Int)
    ) -> Data {
        core.encodeMouse(event: FfiMouseEvent(
            button: button,
            action: action,
            shift: false,
            alt: false,
            ctrl: false,
            col: UInt32(max(cell.col, 0)),
            row: UInt32(max(cell.row, 0))
        ))
    }

    public func mouseReportBytes(
        button: FfiMouseButton,
        action: FfiMouseAction,
        cell: (row: Int, col: Int),
        event: NSEvent
    ) -> Data {
        core.encodeMouse(event: FfiMouseEvent(
            button: button,
            action: action,
            shift: event.modifierFlags.contains(.shift),
            alt: event.modifierFlags.contains(.option),
            ctrl: event.modifierFlags.contains(.control),
            col: UInt32(cell.col),
            row: UInt32(cell.row)
        ))
    }

    // MARK: - Mouse Clicks and Dragging

    override open func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let loc = convert(event.locationInWindow, from: nil)
        if scrollbarLayer.frame.contains(loc) {
            if isOutputFilterActive {
                let matchCount = outputFilterMatchingLines.count
                let visibleLines = Int(core.rows())
                if matchCount > visibleLines {
                    isDraggingScrollbar = true
                    let locInLayer = CGPoint(x: loc.x - scrollbarLayer.frame.origin.x, y: loc.y - scrollbarLayer.frame.origin.y)
                    if scrollbarKnob.frame.contains(locInLayer) {
                        scrollbarDragStartKnobY = scrollbarKnob.frame.origin.y
                        scrollbarDragStartMouseY = loc.y
                    } else {
                        let usableHeight = scrollbarLayer.bounds.height
                        let knobHeight = scrollbarKnob.frame.height
                        let maxKnobTravel = max(0, usableHeight - knobHeight)
                        let targetKnobY = max(0, min(locInLayer.y - knobHeight / 2.0, maxKnobTravel))
                        let fraction = maxKnobTravel > 0 ? (targetKnobY / maxKnobTravel) : 0
                        let maxOffset = max(0, matchCount - visibleLines)
                        outputFilterScrollOffset = Int(round(fraction * CGFloat(maxOffset)))
                        updateScroller()
                        scheduleRedraw()
                        scrollbarDragStartKnobY = targetKnobY
                        scrollbarDragStartMouseY = loc.y
                    }
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    scrollbarKnob.backgroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
                    CATransaction.commit()
                }
                return
            }
            let maxScroll = scrollbackLength
            let modes = core.modes()
            if modes.alternateScreen && modes.alternateScroll {
                isDraggingScrollbar = true
                scrollbarDragStartMouseY = loc.y
                let key = FfiKeyEvent(
                    key: loc.y > bounds.height / 2 ? .pageUp : .pageDown, text: "", physicalText: "", unshiftedText: "",
                    shift: false, alt: false, ctrl: false, superKey: false,
                    press: true, repeat: false, composing: false)
                let singleKey = core.encodeKey(event: key)
                if !singleKey.isEmpty {
                    delegate?.terminalView(self, sendInputData: singleKey)
                }
                return
            }
            if maxScroll > 0 {
                isDraggingScrollbar = true
                let locInLayer = CGPoint(x: loc.x - scrollbarLayer.frame.origin.x, y: loc.y - scrollbarLayer.frame.origin.y)
                
                if scrollbarKnob.frame.contains(locInLayer) {
                    scrollbarDragStartKnobY = scrollbarKnob.frame.origin.y
                    scrollbarDragStartMouseY = loc.y
                } else {
                    let usableHeight = scrollbarLayer.bounds.height
                    let knobHeight = scrollbarKnob.frame.height
                    let maxKnobTravel = max(0, usableHeight - knobHeight)
                    let targetKnobY = max(0, min(locInLayer.y - knobHeight / 2.0, maxKnobTravel))
                    let newPos = maxKnobTravel > 0 ? Double(1.0 - targetKnobY / maxKnobTravel) : 1.0
                    core.setScrollPosition(position: newPos)
                    lastReportedScrollPosition = newPos
                    updateScroller()
                    scheduleRedraw()
                    
                    scrollbarDragStartKnobY = targetKnobY
                    scrollbarDragStartMouseY = loc.y
                }
                
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                scrollbarKnob.backgroundColor = NSColor.white.withAlphaComponent(0.85).cgColor
                CATransaction.commit()
            }
            return
        }
        isDraggingScrollbar = false
        if stickyCommandHeaderEnabled && !stickyHeaderLayer.isHidden && stickyHeaderLayer.frame.contains(loc) {
            if let header = activeStickyCommandHeader ?? currentStickyCommandHeader() {
                jumpToPrompt(retainedRow: header.promptRetainedRow)
                return
            }
        }
        lastMousePoint = loc
        let cell = cellAt(loc)
        if event.modifierFlags.contains(.command) {
            let cellLink = linkRange(at: cell)
            let alreadyPreviewed = (hasPresentedMatchingPreview && currentHoveredLink?.url == cellLink?.url)
            refreshHoveredLink(at: loc, commandHeld: true)
            if let link = currentHoveredLink ?? cellLink {
                openLink(link, previewAlreadyPresented: alreadyPreviewed)
                return
            }
            if let target = hoveredSemanticPath ?? semanticPath(at: cell) {
                openSemanticPath(target)
                return
            }
        }
        nativeSelectionCurrentPress = event.modifierFlags.contains(.shift)
            && !mouseShiftCapture.capturesShift(programRequest: core.mouseShiftCapture())
        let report = nativeSelectionCurrentPress
            ? Data()
            : mouseReportBytes(button: .left, action: .press, cell: cell, event: event)
        reportingCurrentPress = !nativeSelectionCurrentPress && !report.isEmpty
        guard report.isEmpty else {
            delegate?.terminalView(self, sendInputData: report)
            return
        }

        selectionAnchor = cell
        switch (event.clickCount - 1) % 3 {
        case 1:
            core.selectWord(row: UInt32(cell.row), col: UInt32(cell.col))
            expandedSelectionPress = true
            selectionAnchor = nil
        case 2:
            core.selectLine(row: UInt32(cell.row), col: UInt32(cell.col))
            expandedSelectionPress = true
            selectionAnchor = nil
        default:
            expandedSelectionPress = false
            core.startSelection(
                row: UInt32(cell.row),
                col: UInt32(cell.col),
                mode: !nativeSelectionCurrentPress && event.modifierFlags.contains(.option) ? .rectangular : .linear
            )
        }
        scheduleRedraw()
    }

    override open func mouseDragged(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        if isDraggingScrollbar {
            if isOutputFilterActive {
                let usableHeight = scrollbarLayer.bounds.height
                let matchCount = outputFilterMatchingLines.count
                let visibleLines = Int(core.rows())
                let totalLines = Double(matchCount)
                let proportion = max(0.05, min(1.0, Double(visibleLines) / totalLines))
                let knobHeight = max(usableHeight * CGFloat(proportion), 24.0)
                let maxKnobTravel = max(0, usableHeight - knobHeight)
                guard maxKnobTravel > 0 else { return }

                let dy = loc.y - scrollbarDragStartMouseY
                var newKnobY = scrollbarDragStartKnobY + dy
                newKnobY = max(0, min(newKnobY, maxKnobTravel))
                let fraction = newKnobY / maxKnobTravel
                let maxOffset = max(0, matchCount - visibleLines)
                outputFilterScrollOffset = Int(round(fraction * CGFloat(maxOffset)))
                updateScroller()
                scheduleRedraw()
                return
            }
            let maxScroll = scrollbackLength
            let modes = core.modes()
            if modes.alternateScreen && modes.alternateScroll {
                let dy = loc.y - scrollbarDragStartMouseY
                let pointsPerStep: CGFloat = 8.0
                if abs(dy) >= pointsPerStep {
                    let steps = Int(dy / pointsPerStep)
                    scrollbarDragStartMouseY += CGFloat(steps) * pointsPerStep
                    let key = FfiKeyEvent(
                        key: steps > 0 ? .up : .down, text: "", physicalText: "", unshiftedText: "",
                        shift: false, alt: false, ctrl: false, superKey: false,
                        press: true, repeat: false, composing: false)
                    let singleKey = core.encodeKey(event: key)
                    if !singleKey.isEmpty {
                        var keys = Data()
                        for _ in 0..<abs(steps) { keys.append(singleKey) }
                        delegate?.terminalView(self, sendInputData: keys)
                    }
                }
                return
            }
            
            let usableHeight = scrollbarLayer.bounds.height
            let visibleLines = Double(core.rows())
            let totalLines = Double(maxScroll) + visibleLines
            let proportion = max(0.05, min(1.0, visibleLines / totalLines))
            let knobHeight = max(usableHeight * CGFloat(proportion), 24.0)
            let maxKnobTravel = max(0, usableHeight - knobHeight)
            guard maxKnobTravel > 0 else { return }
            
            let dy = loc.y - scrollbarDragStartMouseY
            var newKnobY = scrollbarDragStartKnobY + dy
            newKnobY = max(0, min(newKnobY, maxKnobTravel))
            
            let fraction = newKnobY / maxKnobTravel
            let newPos = 1.0 - Double(fraction)
            
            core.setScrollPosition(position: newPos)
            lastReportedScrollPosition = newPos
            updateScroller()
            scheduleRedraw()
            return
        }
        let cell = cellAt(loc)
        guard !reportingCurrentPress else {
            let report = mouseReportBytes(button: .left, action: .motion, cell: cell, event: event)
            if !report.isEmpty { delegate?.terminalView(self, sendInputData: report) }
            return
        }

        guard !expandedSelectionPress else { return }
        core.extendSelection(row: UInt32(cell.row), col: UInt32(cell.col))
        scheduleRedraw()
    }

    override open func mouseUp(with event: NSEvent) {
        if isDraggingScrollbar {
            isDraggingScrollbar = false
            updateScroller()
            return
        }
        let cell = cellAt(convert(event.locationInWindow, from: nil))
        guard !reportingCurrentPress else {
            let report = mouseReportBytes(button: .left, action: .release, cell: cell, event: event)
            if !report.isEmpty { delegate?.terminalView(self, sendInputData: report) }
            reportingCurrentPress = false
            return
        }

        if let anchor = selectionAnchor, cell == anchor {
            core.clearSelection()
            _ = moveCursorForClick(cell: cell, event: event)
            scheduleRedraw()
        } else if core.hasSelection() {
            selectionDidFinish()
        }
        nativeSelectionCurrentPress = false
    }

    func moveCursorForClick(cell: (row: Int, col: Int), event: NSEvent) -> Bool {
        guard cursorClickToMove, !nativeSelectionCurrentPress, core.cursorIsAtPrompt() else { return false }
        let cursorRow = Int(core.cursorRow())
        let onPromptLine = core.rowSemanticPrompt(row: UInt32(cell.row)) != 0
        guard cell.row == cursorRow || (event.modifierFlags.contains(.option) && onPromptLine) else {
            return false
        }
        let delta = cell.col - Int(core.cursorCol())
        guard delta != 0 else { return false }
        let key: FfiKey = delta > 0 ? .right : .left
        var bytes = Data()
        for _ in 0..<abs(delta) {
            bytes.append(core.encodeKey(event: FfiKeyEvent(
                key: key, text: "", physicalText: "", unshiftedText: "",
                shift: false, alt: false, ctrl: false, superKey: false,
                press: true, repeat: false, composing: false
            )))
        }
        guard !bytes.isEmpty else { return false }
        delegate?.terminalView(self, sendInputData: bytes)
        return true
    }
}
#endif
