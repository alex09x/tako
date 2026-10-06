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
    /// Returns true if viewport `row` is a soft-wrapped continuation of `row - 1`.
    func isViewportLineWrapped(row: Int) -> Bool {
        guard row > 0, row < Int(core.rows()) else { return false }
        let text = core.getPlainText(startRow: UInt32(row - 1), maxRows: 2)
        return !text.contains("\n")
    }

    /// Collects the full displayed text of the clicked contiguous OSC 8 hyperlink span,
    /// including any wrapped preceding and succeeding rows that continue the same span.
    func fullOsc8Text(cell: (row: Int, col: Int), uri: String) -> String {
        let cols = Int(core.cols())
        let totalRows = Int(core.rows())
        guard cols > 0, totalRows > 0 else { return "" }

        var currentStart = cell.col
        while currentStart > 0,
              core.getCell(row: UInt32(cell.row), col: UInt32(currentStart - 1))?.hyperlinkUri == uri {
            currentStart -= 1
        }
        var currentEnd = cell.col
        while currentEnd + 1 < cols,
              core.getCell(row: UInt32(cell.row), col: UInt32(currentEnd + 1))?.hyperlinkUri == uri {
            currentEnd += 1
        }

        var spans: [Int: (start: Int, end: Int)] = [cell.row: (start: currentStart, end: currentEnd)]

        var topRow = cell.row
        while topRow > 0 {
            guard isViewportLineWrapped(row: topRow) else { break }
            guard let curSpan = spans[topRow], curSpan.start == 0 else { break }
            guard core.getCell(row: UInt32(topRow - 1), col: UInt32(cols - 1))?.hyperlinkUri == uri else { break }
            var prevStart = cols - 1
            while prevStart > 0,
                  core.getCell(row: UInt32(topRow - 1), col: UInt32(prevStart - 1))?.hyperlinkUri == uri {
                prevStart -= 1
            }
            spans[topRow - 1] = (start: prevStart, end: cols - 1)
            topRow -= 1
        }

        var bottomRow = cell.row
        while bottomRow + 1 < totalRows {
            guard isViewportLineWrapped(row: bottomRow + 1) else { break }
            guard let curSpan = spans[bottomRow], curSpan.end == cols - 1 else { break }
            guard core.getCell(row: UInt32(bottomRow + 1), col: 0)?.hyperlinkUri == uri else { break }
            var nextEnd = 0
            while nextEnd + 1 < cols,
                  core.getCell(row: UInt32(bottomRow + 1), col: UInt32(nextEnd + 1))?.hyperlinkUri == uri {
                nextEnd += 1
            }
            spans[bottomRow + 1] = (start: 0, end: nextEnd)
            bottomRow += 1
        }

        var fullText = ""
        for r in topRow...bottomRow {
            guard let span = spans[r] else { continue }
            for col in span.start...span.end {
                if let c = core.getCell(row: UInt32(r), col: UInt32(col)), c.ch != 0 {
                    fullText += c.grapheme ?? TerminalRenderer.string(for: c.ch)
                }
            }
        }
        return fullText
    }

    /// `link-url` and OSC 8: the link under `cell`, if any.
    public func linkRange(at cell: (row: Int, col: Int)) -> TerminalLink? {
        if let hyperlink = core.getCell(row: UInt32(cell.row), col: UInt32(cell.col))?.hyperlinkUri,
           let url = URL(string: hyperlink) {
            var start = cell.col
            var end = cell.col
            while start > 0,
                  core.getCell(row: UInt32(cell.row), col: UInt32(start - 1))?.hyperlinkUri == hyperlink {
                start -= 1
            }
            let cols = Int(core.cols())
            while end + 1 < cols,
                  core.getCell(row: UInt32(cell.row), col: UInt32(end + 1))?.hyperlinkUri == hyperlink {
                end += 1
            }
            var rowText = ""
            for col in start...end {
                if let c = core.getCell(row: UInt32(cell.row), col: UInt32(col)), c.ch != 0 {
                    rowText += c.grapheme ?? TerminalRenderer.string(for: c.ch)
                }
            }
            let fullText = fullOsc8Text(cell: cell, uri: hyperlink)
            let displayedText = fullText.isEmpty ? rowText : fullText
            let isMismatch = Self.detectLinkMismatch(text: displayedText, targetURL: url)
            let isSafe = Self.isSafeScheme(url.scheme)
            return TerminalLink(
                url: url,
                text: displayedText,
                row: cell.row,
                colStart: start,
                colEnd: end,
                isOsc8: true,
                isMismatch: isMismatch,
                isSchemeAllowedWithoutPrompt: isSafe
            )
        }

        guard linkURLDetectionEnabled else { return nil }
        let (line, columns) = Self.rowText(core.viewportRow(row: UInt32(cell.row)))
        let text = line as NSString
        let matches = Self.urlPattern.matches(in: line, range: NSRange(location: 0, length: text.length))
        for match in matches {
            let first = match.range.location
            let last = match.range.location + match.range.length - 1
            guard columns[first] <= cell.col, cell.col <= columns[last] else {
                continue
            }
            var matched = text.substring(with: match.range)
            while let lastChar = matched.last, ".,;:!?)]}>'\"".contains(lastChar) {
                matched.removeLast()
            }
            guard !matched.isEmpty, let url = URL(string: matched) else { return nil }
            let isSafe = Self.isSafeScheme(url.scheme)
            return TerminalLink(
                url: url,
                text: matched,
                row: cell.row,
                colStart: columns[first],
                colEnd: columns[first + (matched as NSString).length - 1],
                isOsc8: false,
                isMismatch: false,
                isSchemeAllowedWithoutPrompt: isSafe
            )
        }
        return nil
    }

    /// Updates the bottom-left floating HUD pill showing hovered link destination (E8).
    func updateLinkHUD(link: TerminalLink?) {
        guard let link, bounds.width > 0, bounds.height > 0 else {
            hasPresentedMatchingPreview = false
            linkHUDLayer.isHidden = true
            return
        }
        hasPresentedMatchingPreview = true
        let text = link.tooltipText
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        let attr = [NSAttributedString.Key.font: font]
        let textSize = (text as NSString).size(withAttributes: attr)
        let paddingH: CGFloat = 8.0
        let paddingV: CGFloat = 4.0
        let hudWidth = min(textSize.width + paddingH * 2, max(bounds.width - 20, 50))
        let hudHeight = textSize.height + paddingV * 2

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        linkHUDLayer.frame = NSRect(
            x: max(gridLayout.left, 8.0),
            y: max(gridLayout.bottom(in: bounds.size), 8.0),
            width: hudWidth,
            height: hudHeight
        )
        if link.isMismatch {
            linkHUDLayer.backgroundColor = NSColor(srgbRed: 0.75, green: 0.15, blue: 0.15, alpha: 0.95).cgColor
        } else {
            linkHUDLayer.backgroundColor = NSColor(white: 0.12, alpha: 0.92).cgColor
        }
        linkHUDTextLayer.font = font
        linkHUDTextLayer.fontSize = 11.0
        linkHUDTextLayer.string = text
        linkHUDTextLayer.frame = NSRect(
            x: paddingH,
            y: paddingV,
            width: hudWidth - paddingH * 2,
            height: hudHeight - paddingV * 2
        )
        linkHUDLayer.isHidden = false
        CATransaction.commit()
    }

    public func openLink(_ link: TerminalLink, previewAlreadyPresented: Bool = false) {
        if link.isMismatch {
            let warning = LinkSecurityWarning.urlMismatch(displayedText: link.text, targetURL: link.url)
            Self.confirmOpenURL(link.url, warning, window) { confirmed in
                guard confirmed else { return }
                Self.openURL(link.url)
            }
        } else if !link.isSchemeAllowedWithoutPrompt {
            let scheme = link.url.scheme ?? "unknown"
            let warning = LinkSecurityWarning.unsafeScheme(scheme)
            Self.confirmOpenURL(link.url, warning, window) { confirmed in
                guard confirmed else { return }
                Self.openURL(link.url)
            }
        } else if !previewAlreadyPresented {
            let warning = LinkSecurityWarning.unconfirmedDestination(link.url)
            Self.confirmOpenURL(link.url, warning, window) { confirmed in
                guard confirmed else { return }
                Self.openURL(link.url)
            }
        } else {
            Self.openURL(link.url)
        }
    }

    func updateHoveredLink(commandHeld: Bool) {
        let link = commandHeld ? mouseCell.flatMap(linkRange(at:)) : nil
        let semantic = (commandHeld && link == nil && semanticPathDetectionEnabled) ? mouseCell.flatMap(semanticPath(at:)) : nil

        let linkChanged = link?.url != hoveredLink?.url || link?.colStart != hoveredLink?.colStart || link?.row != hoveredLink?.row
        let semanticChanged = semantic != hoveredSemanticPath
        guard linkChanged || semanticChanged else { return }

        hoveredLink = link
        hoveredSemanticPath = semantic

        if let link {
            let origin = cellOrigin(row: link.row, col: link.colStart)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            linkUnderlineLayer.frame = NSRect(
                x: origin.x, y: origin.y,
                width: cellWidth * CGFloat(link.colEnd - link.colStart + 1),
                height: max((cellHeight * 0.08).rounded(.up), 1)
            )
            if link.isMismatch {
                linkUnderlineLayer.backgroundColor = NSColor.systemRed.cgColor
            } else {
                linkUnderlineLayer.backgroundColor = NSColor.labelColor.cgColor
            }
            linkUnderlineLayer.isHidden = false
            CATransaction.commit()
            NSCursor.pointingHand.set()
            return
        }

        if let semantic {
            let origin = cellOrigin(row: semantic.row, col: semantic.colStart)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            linkUnderlineLayer.frame = NSRect(
                x: origin.x, y: origin.y,
                width: cellWidth * CGFloat(semantic.colEnd - semantic.colStart + 1),
                height: max((cellHeight * 0.08).rounded(.up), 1)
            )
            linkUnderlineLayer.backgroundColor = NSColor.labelColor.cgColor
            linkUnderlineLayer.isHidden = false
            CATransaction.commit()
            NSCursor.pointingHand.set()
            return
        }

        linkUnderlineLayer.isHidden = true
        NSCursor.arrow.set()
    }

    public func refreshHoveredLink(at pointOverride: NSPoint? = nil, commandHeld: Bool? = nil) {
        let point: NSPoint?
        if let override = pointOverride {
            point = bounds.contains(override) ? override : nil
        } else if let win = self.window {
            let winPoint = win.mouseLocationOutsideOfEventStream
            let localPoint = convert(winPoint, from: nil)
            point = bounds.contains(localPoint) ? localPoint : nil
        } else if let last = lastMousePoint {
            point = bounds.contains(last) ? last : nil
        } else {
            point = nil
        }

        guard let point else {
            if currentHoveredLink != nil {
                clearHoveredLink()
            }
            return
        }

        mouseCell = cellAt(point)
        let linkUnderPointer = mouseCell.flatMap(linkRange(at:))
        if linkUnderPointer != currentHoveredLink {
            currentHoveredLink = linkUnderPointer
            hoveredLinkTarget = linkUnderPointer?.url.absoluteString
            self.toolTip = linkUnderPointer?.tooltipText
            updateLinkHUD(link: linkUnderPointer)
            delegate?.terminalView(self, didHoverLink: hoveredLinkTarget)
        }
        let isCmd = commandHeld ?? (NSApp.currentEvent?.modifierFlags.contains(.command) == true || NSEvent.modifierFlags.contains(.command))
        updateHoveredLink(commandHeld: isCmd)
    }

    func clearHoveredLink() {
        hasPresentedMatchingPreview = false
        mouseCell = nil
        currentHoveredLink = nil
        hoveredSemanticPath = nil
        hoveredLinkTarget = nil
        self.toolTip = nil
        updateLinkHUD(link: nil)
        delegate?.terminalView(self, didHoverLink: nil)
        updateHoveredLink(commandHeld: false)
    }

    override open func flagsChanged(with event: NSEvent) {
        refreshHoveredLink(commandHeld: event.modifierFlags.contains(.command))
        super.flagsChanged(with: event)
    }
}
#endif
