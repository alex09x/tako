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
    /// Updates visible regex trigger highlight CALayers and evaluates notification triggers (E7).
    public func updateRegexTriggerHighlights() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        triggerHighlightsLayer.frame = bounds

        guard !regexTriggers.isEmpty else {
            triggerHighlightsLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
            return
        }

        let layout = gridLayout
        let screenRows = Int(core.rows())
        let totalScrollback = Int(core.scrollbackLen())
        let offset = Int(core.viewportOffset())
        let topVisible = totalScrollback - offset

        var highlightItems: [(rect: CGRect, color: CGColor, style: TerminalRegexTrigger.HighlightStyle)] = []

        let deadline = DispatchTime.now() + .milliseconds(8)

        for screenRow in 0..<screenRows {
            if DispatchTime.now() > deadline {
                break
            }
            let retainedRow = UInt64(max(0, topVisible + screenRow))
            let (lineText, columns) = Self.rowText(core.viewportRow(row: UInt32(screenRow)))
            guard !lineText.isEmpty, !columns.isEmpty else { continue }
            
            // Cap inspected line text to bound work on pathological outputs
            let maxInspected = min(columns.count, max(Int(core.cols()), 512))
            let nsText = lineText as NSString
            let inspectedLength = min(nsText.length, maxInspected)
            guard inspectedLength > 0 else { continue }
            let scanRange = NSRange(location: 0, length: inspectedLength)

            for trigger in regexTriggers {
                if DispatchTime.now() > deadline {
                    break
                }
                if disabledTriggerIDs.contains(trigger.id) {
                    continue
                }
                guard let regex = trigger.regex else { continue }
                
                var matchCount = 0
                let matchStart = DispatchTime.now()

                regex.enumerateMatches(in: lineText, options: [], range: scanRange) { matchResult, _, stop in
                    guard let match = matchResult, match.range.length > 0 else { return }
                    matchCount += 1
                    if matchCount >= 16 {
                        stop.pointee = true
                    }

                    let startLoc = match.range.location
                    let endLoc = match.range.location + match.range.length - 1
                    guard startLoc < columns.count, endLoc < columns.count else { return }

                    let startCol = columns[startLoc]
                    let endCol = columns[endLoc]

                    if trigger.action.highlights {
                        let cellY = bounds.height - layout.top - CGFloat(screenRow + 1) * cellHeight
                        let startX = layout.left + CGFloat(startCol) * cellWidth
                        let width = CGFloat(max(1, endCol - startCol + 1)) * cellWidth
                        let rect = CGRect(x: startX, y: cellY, width: width, height: cellHeight)
                        let color = trigger.color?.cgColor ?? NSColor.systemYellow.cgColor
                        highlightItems.append((rect: rect, color: color, style: trigger.style))
                    }

                    if trigger.action.notifies {
                        var notifiedSet = notifiedTriggerMatches[trigger.id] ?? Set<UInt64>()
                        if !notifiedSet.contains(retainedRow) {
                            notifiedSet.insert(retainedRow)
                            notifiedTriggerMatches[trigger.id] = notifiedSet
                            let matchedSubstring = nsText.substring(with: match.range)
                            onTriggerMatched?(trigger, matchedSubstring, screenRow)
                        }
                    }
                }

                let elapsedNs = DispatchTime.now().uptimeNanoseconds - matchStart.uptimeNanoseconds
                if elapsedNs > 2_000_000 { // 2ms per-match budget
                    disabledTriggerIDs.insert(trigger.id)
                }
            }
        }

        if highlightItems.isEmpty {
            triggerHighlightsLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
            return
        }

        var sublayers = triggerHighlightsLayer.sublayers ?? []
        var layerIndex = 0

        for item in highlightItems {
            let layer: CALayer
            if layerIndex < sublayers.count {
                layer = sublayers[layerIndex]
            } else {
                layer = CALayer()
                triggerHighlightsLayer.addSublayer(layer)
                sublayers.append(layer)
            }
            layerIndex += 1

            switch item.style {
            case .background:
                layer.frame = item.rect
                layer.backgroundColor = NSColor(cgColor: item.color)?.withAlphaComponent(0.35).cgColor ?? item.color
                layer.cornerRadius = 2.0
                layer.borderWidth = 0.0
                layer.borderColor = nil
            case .underline:
                let underlineHeight: CGFloat = 2.0
                layer.frame = CGRect(x: item.rect.origin.x, y: item.rect.origin.y + 1.0, width: item.rect.width, height: underlineHeight)
                layer.backgroundColor = item.color
                layer.cornerRadius = 1.0
                layer.borderWidth = 0.0
                layer.borderColor = nil
            case .box:
                layer.frame = item.rect
                layer.backgroundColor = NSColor(cgColor: item.color)?.withAlphaComponent(0.12).cgColor ?? item.color
                layer.cornerRadius = 2.0
                layer.borderWidth = 1.5
                layer.borderColor = item.color
            case .bold:
                layer.frame = item.rect
                layer.backgroundColor = NSColor(cgColor: item.color)?.withAlphaComponent(0.28).cgColor ?? item.color
                layer.cornerRadius = 2.0
                layer.borderWidth = 1.0
                layer.borderColor = NSColor(cgColor: item.color)?.withAlphaComponent(0.7).cgColor ?? item.color
            }
        }

        while sublayers.count > layerIndex {
            sublayers.removeLast().removeFromSuperlayer()
        }
    }
}
#endif
