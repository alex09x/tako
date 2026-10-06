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
    /// Internal, not private: a host that moved the viewport in the engine
    /// directly (a search selecting a hit) calls it so the scrollbar follows.
    func notifyScrollPositionIfChanged() {
        updateScroller()
        
        let position = core.scrollPosition()
        guard abs(position - lastReportedScrollPosition) > 0.0001 else { return }
        lastReportedScrollPosition = position
        delegate?.terminalView(self, didScrollTo: position)
    }

    func updateScroller() {
        updateGutterMarks()
        updateStickyCommandHeader()
        updateRegexTriggerHighlights()

        let trackHeight = bounds.height
        guard trackHeight > 0 else { return }
        
        let scrollerWidth: CGFloat = 10.0
        scrollbarLayer.frame = CGRect(x: bounds.width - scrollerWidth - 2.0, y: 2.0, width: scrollerWidth, height: trackHeight - 4.0)
        
        let maxScroll = scrollbackLength
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrollbarLayer.opacity = 1.0
        
        let usableHeight = scrollbarLayer.bounds.height
        scrollbarMarksLayer.frame = scrollbarLayer.bounds

        if isOutputFilterActive {
            scrollbarMarksLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
            let matchCount = outputFilterMatchingLines.count
            let visibleLines = Double(core.rows())
            if matchCount <= Int(visibleLines) {
                scrollbarKnob.frame = CGRect(x: 1.5, y: 1.5, width: scrollerWidth - 3.0, height: max(0, usableHeight - 3.0))
                scrollbarKnob.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
            } else {
                let totalLines = Double(matchCount)
                let proportion = max(0.05, min(1.0, visibleLines / totalLines))
                let knobHeight = max(usableHeight * CGFloat(proportion), 24.0)
                let maxKnobTravel = max(0, usableHeight - knobHeight)
                let maxOffset = max(1, matchCount - Int(visibleLines))
                let fraction = CGFloat(outputFilterScrollOffset) / CGFloat(maxOffset)
                let knobY = maxKnobTravel * fraction
                scrollbarKnob.frame = CGRect(x: 1.5, y: knobY, width: scrollerWidth - 3.0, height: knobHeight)
                scrollbarKnob.backgroundColor = isDraggingScrollbar
                    ? NSColor.white.withAlphaComponent(0.85).cgColor
                    : NSColor.white.withAlphaComponent(0.45).cgColor
            }
            CATransaction.commit()
            return
        }

        let modes = core.modes()
        if modes.alternateScreen && modes.alternateScroll {
            scrollbarMarksLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
            let knobHeight: CGFloat = 44.0
            let knobY = (usableHeight - knobHeight) / 2.0
            scrollbarKnob.frame = CGRect(x: 1.5, y: knobY, width: scrollerWidth - 3.0, height: knobHeight)
            scrollbarKnob.backgroundColor = NSColor.white.withAlphaComponent(0.5).cgColor
        } else if maxScroll == 0 {
            updateScrollbarMarks(usableHeight: usableHeight, totalLines: Double(core.rows()), scrollerWidth: scrollerWidth)
            scrollbarKnob.frame = CGRect(x: 1.5, y: 1.5, width: scrollerWidth - 3.0, height: max(0, usableHeight - 3.0))
            scrollbarKnob.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
        } else {
            let visibleLines = Double(core.rows())
            let totalLines = Double(maxScroll) + visibleLines
            updateScrollbarMarks(usableHeight: usableHeight, totalLines: totalLines, scrollerWidth: scrollerWidth)

            let proportion = max(0.05, min(1.0, visibleLines / totalLines))
            let knobHeight = max(usableHeight * CGFloat(proportion), 24.0)
            let maxKnobTravel = max(0, usableHeight - knobHeight)
            
            let pos = core.scrollPosition()
            let knobY = maxKnobTravel * CGFloat(1.0 - pos)
            
            scrollbarKnob.frame = CGRect(x: 1.5, y: knobY, width: scrollerWidth - 3.0, height: knobHeight)
            scrollbarKnob.backgroundColor = isDraggingScrollbar
                ? NSColor.white.withAlphaComponent(0.85).cgColor
                : NSColor.white.withAlphaComponent(0.45).cgColor
        }
        CATransaction.commit()
    }

    /// Renders command marks and search hits on the scrollbar track.
    func updateScrollbarMarks(usableHeight: CGFloat, totalLines: Double, scrollerWidth: CGFloat) {
        guard usableHeight > 0, totalLines > 0, !core.modes().alternateScreen else {
            scrollbarMarksLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
            return
        }

        let markWidth: CGFloat = scrollerWidth - 2.0
        let markHeight: CGFloat = 2.0
        let markX: CGFloat = 1.0

        var binnedMarks: [Int: CGColor] = [:]

        // Search hits first so command marks (success/error/running) take precedence over search marks
        if !searchHitRetainedRows.isEmpty {
            let searchColor = NSColor(red: 1.0, green: 0.78, blue: 0.1, alpha: 0.95).cgColor
            let uniqueRows = Set(searchHitRetainedRows)
            for row in uniqueRows {
                let frac = totalLines > 1 ? max(0.0, min(1.0, Double(row) / (totalLines - 1.0))) : 0.0
                let markY = max(0.0, min(usableHeight - markHeight, usableHeight * CGFloat(1.0 - frac) - markHeight / 2.0))
                binnedMarks[Int(round(markY))] = searchColor
            }
        }

        // Command marks on scrollbar
        if commandMarksEnabled {
            for cmd in core.commandMarks() {
                let color: CGColor
                switch cmd.status {
                case 1: color = NSColor.systemGreen.cgColor
                case 2: color = NSColor.systemRed.cgColor
                default: color = NSColor.systemBlue.cgColor
                }
                let frac = totalLines > 1 ? max(0.0, min(1.0, Double(cmd.retainedRow) / (totalLines - 1.0))) : 0.0
                let markY = max(0.0, min(usableHeight - markHeight, usableHeight * CGFloat(1.0 - frac) - markHeight / 2.0))
                binnedMarks[Int(round(markY))] = color
            }
        }

        if binnedMarks.isEmpty {
            scrollbarMarksLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
            return
        }

        var sublayers = scrollbarMarksLayer.sublayers ?? []
        var layerIndex = 0

        for (yInt, color) in binnedMarks.sorted(by: { $0.key < $1.key }) {
            let markY = CGFloat(yInt)
            let layer: CALayer
            if layerIndex < sublayers.count {
                layer = sublayers[layerIndex]
            } else {
                layer = CALayer()
                layer.cornerRadius = 1.0
                scrollbarMarksLayer.addSublayer(layer)
                sublayers.append(layer)
            }
            layerIndex += 1

            layer.frame = CGRect(x: markX, y: markY, width: markWidth, height: markHeight)
            layer.backgroundColor = color
        }

        while sublayers.count > layerIndex {
            sublayers.removeLast().removeFromSuperlayer()
        }
    }

    /// Returns the start time of command `id` if recorded.
    public func commandStartedAt(id: UInt64) -> Date? {
        if let tracked = trackedCommands[id], let started = tracked.startedAt {
            return started
        }
        if let info = core.firstCommandAfter(after: id > 0 ? id - 1 : 0), info.id == id, let ms = info.startedAtMs {
            return Date(timeIntervalSince1970: Double(ms) / 1000.0)
        }
        return nil
    }

    /// Returns the elapsed duration of command `id` if finished (OSC 133;D) or completed.
    public func commandDuration(id: UInt64, epoch: UInt64? = nil) -> TimeInterval? {
        if let epoch, epoch != core.stateEpoch() {
            return nil
        }
        if let dur = commandDurations[id] {
            return dur
        }
        if let tracked = trackedCommands[id], let dur = tracked.duration {
            return dur
        }
        return nil
    }

    /// Formats a time interval into a human-readable duration string.
    public static func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 0.001 {
            return "<1ms"
        }
        if seconds < 1.0 {
            return "\(Int((seconds * 1000.0).rounded()))ms"
        }
        if seconds < 10.0 {
            return String(format: "%.1fs", seconds)
        }
        if seconds < 60.0 {
            return "\(Int(seconds.rounded()))s"
        }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%dm %02ds", mins, secs)
    }

    /// Formats a Date into a start-time timestamp string (HH:mm:ss).
    public static func formatStartTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    /// Renders thin vertical marks beside each command's prompt line in the left gutter,
    /// with optional duration and start time text (E10).
    func updateGutterMarks() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        guard commandMarksEnabled, !core.modes().alternateScreen else {
            gutterMarksLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
            gutterCommandMarksByRow.removeAll()
            return
        }

        let layout = gridLayout
        let gutterWidth = layout.left
        guard gutterWidth >= 2.0 else {
            gutterMarksLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
            gutterCommandMarksByRow.removeAll()
            return
        }

        gutterMarksLayer.frame = CGRect(x: 0, y: 0, width: gutterWidth, height: bounds.height)

        let marks = core.commandMarks()
        if marks.isEmpty {
            gutterMarksLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
            gutterCommandMarksByRow.removeAll()
            return
        }

        let totalScrollback = Int(core.scrollbackLen())
        let offset = Int(core.viewportOffset())
        let topVisible = totalScrollback - offset
        let screenRows = Int(core.rows())

        let markWidth: CGFloat = 3.0
        let markX: CGFloat = max(1.0, gutterWidth - markWidth - 2.0)
        let markHeight: CGFloat = max(4.0, cellHeight - 4.0)

        gutterCommandMarksByRow.removeAll()
        var marksByScreenRow: [Int: (mark: FfiCommandMark, color: CGColor, duration: TimeInterval?, startedAt: Date?)] = [:]
        for mark in marks {
            let screenRow = Int(mark.retainedRow) - topVisible
            guard screenRow >= 0, screenRow < screenRows else { continue }

            let color: CGColor
            switch mark.status {
            case 1: color = NSColor.systemGreen.cgColor
            case 2: color = NSColor.systemRed.cgColor
            default: color = NSColor.systemBlue.cgColor
            }
            let cmdId = mark.commandId
            let started = commandStartedAt(id: cmdId)
            let dur = commandDuration(id: cmdId)
            gutterCommandMarksByRow[screenRow] = (cmdId, mark.status, mark.exitCode, dur, started)
            marksByScreenRow[screenRow] = (mark, color, dur, started)
        }

        if marksByScreenRow.isEmpty {
            gutterMarksLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
            return
        }

        var sublayers = gutterMarksLayer.sublayers ?? []
        var layerIndex = 0

        for (screenRow, markInfo) in marksByScreenRow.sorted(by: { $0.key < $1.key }) {
            let cellY = bounds.height - layout.top - CGFloat(screenRow + 1) * cellHeight
            let markY = cellY + (cellHeight - markHeight) / 2.0

            let markLayer: CALayer
            if layerIndex < sublayers.count {
                markLayer = sublayers[layerIndex]
            } else {
                markLayer = CALayer()
                markLayer.cornerRadius = markWidth / 2.0
                gutterMarksLayer.addSublayer(markLayer)
                sublayers.append(markLayer)
            }
            layerIndex += 1

            markLayer.frame = CGRect(x: markX, y: markY, width: markWidth, height: markHeight)
            markLayer.backgroundColor = markInfo.color

            // Optional duration/timestamp text label beside mark in gutter (E10)
            if (commandDurationsEnabled || commandTimestampsEnabled) && gutterWidth >= 28.0 {
                let textToDisplay: String? = {
                    if commandDurationsEnabled {
                        if let dur = markInfo.duration {
                            return Self.formatDuration(dur)
                        } else if markInfo.mark.status == 0, let started = markInfo.startedAt {
                            return Self.formatDuration(Date().timeIntervalSince(started))
                        }
                    }
                    if commandTimestampsEnabled, let started = markInfo.startedAt {
                        return Self.formatStartTime(started)
                    }
                    return nil
                }()

                if let textToDisplay {
                    let textLayer: CATextLayer
                    if layerIndex < sublayers.count && sublayers[layerIndex] is CATextLayer {
                        textLayer = sublayers[layerIndex] as! CATextLayer
                    } else {
                        textLayer = CATextLayer()
                        textLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
                        textLayer.alignmentMode = .right
                        textLayer.truncationMode = .end
                        textLayer.font = NSFont.monospacedDigitSystemFont(ofSize: min(9.0, cellHeight * 0.7), weight: .regular)
                        textLayer.fontSize = min(9.0, cellHeight * 0.7)
                        gutterMarksLayer.addSublayer(textLayer)
                        sublayers.append(textLayer)
                    }
                    layerIndex += 1

                    let availableW = max(0, markX - 4.0)
                    let textH = min(14.0, cellHeight)
                    let textY = cellY + (cellHeight - textH) / 2.0
                    textLayer.frame = CGRect(x: 2.0, y: textY, width: availableW, height: textH)
                    textLayer.string = textToDisplay
                    textLayer.foregroundColor = theme.foreground.copy(alpha: 0.65) ?? theme.foreground
                }
            }
        }

        while sublayers.count > layerIndex {
            sublayers.removeLast().removeFromSuperlayer()
        }
    }
}
#endif
