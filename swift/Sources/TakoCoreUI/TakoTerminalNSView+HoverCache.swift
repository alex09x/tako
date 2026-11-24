// Tako — reuse URL detection while the pointer crosses an unchanged terminal row
// Copyright (c) 2026 Alexander Panasenko
// Contact: alex@prod.codes
// Author: https://prod.codes/about/
// Project: https://github.com/alex09x/tako
// SPDX-License-Identifier: MIT

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

extension TakoTerminalNSView {
    struct HoverLinkRowCache {
        var row: Int
        var cols: Int
        var detectsURLs: Bool
        var automaticLinks: [TerminalLink]
        var column: Int?
        var link: TerminalLink?
    }

    func hoverLinkRange(at cell: (row: Int, col: Int), force: Bool = false) -> TerminalLink? {
        if force || hoverLinkRowCache?.row != cell.row || hoverLinkRowCache?.cols != cols
            || hoverLinkRowCache?.detectsURLs != linkURLDetectionEnabled {
            var links: [TerminalLink] = []
            if linkURLDetectionEnabled {
                hoverLinkRowReadCount += 1
                links = detectedURLLinks(in: core.viewportRow(row: UInt32(cell.row)), row: cell.row)
            }
            hoverLinkRowCache = HoverLinkRowCache(row: cell.row, cols: cols,
                detectsURLs: linkURLDetectionEnabled, automaticLinks: links)
        }
        guard var cached = hoverLinkRowCache else { return nil }
        if cached.column == cell.col { return cached.link }
        // An OSC 8 span has already checked its cells' URI. Automatic URLs
        // still need the explicit-link probe when moving to a different cell.
        if let link = cached.link, link.isOsc8, link.colStart <= cell.col, cell.col <= link.colEnd {
            cached.column = cell.col
            hoverLinkRowCache = cached
            return link
        }
        let link = linkRange(at: cell, automaticLinks: cached.automaticLinks)
        cached.column = cell.col
        cached.link = link
        hoverLinkRowCache = cached
        return link
    }

    func refreshHoveredLinkForMouseMovement(at point: NSPoint, commandHeld: Bool) {
        guard bounds.contains(point) else {
            hoverLinkRowCache = nil
            lastFrameHoverCell = nil
            if currentHoveredLink != nil { clearHoveredLink() }
            return
        }
        let cell = cellAt(point)
        mouseCell = cell
        lastFrameHoverCell = cell
        applyHoveredLink(hoverLinkRange(at: cell), commandHeld: commandHeld)
    }

    func invalidateHoverLinkRow(changedRows: IndexSet) {
        guard let cached = hoverLinkRowCache else { return }
        // Wrapped OSC 8 tooltip/security text can include neighbouring rows.
        if cached.cols != cols || changedRows.contains(cached.row)
            || cached.link?.isOsc8 == true && !changedRows.isEmpty {
            hoverLinkRowCache = nil
            lastFrameHoverCell = nil
        }
    }

    func applyHoveredLink(_ link: TerminalLink?, commandHeld: Bool?) {
        if link != currentHoveredLink {
            currentHoveredLink = link
            hoveredLinkTarget = link?.url.absoluteString
            toolTip = link?.tooltipText
            updateLinkHUD(link: link)
            delegate?.terminalView(self, didHoverLink: hoveredLinkTarget)
        }
        let isCmd = commandHeld ?? (NSApp.currentEvent?.modifierFlags.contains(.command) == true
            || NSEvent.modifierFlags.contains(.command))
        updateHoveredLink(commandHeld: isCmd)
    }
}
#endif
