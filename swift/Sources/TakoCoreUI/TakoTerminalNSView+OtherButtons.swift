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

/// The right and middle buttons. A program that asked for mouse reports
/// gets them, as it does the left button; otherwise the right button opens
/// the context menu. These went missing when this view was split into
/// files, so every right click opened the menu, even in htop or vim, and the
/// middle button reached no program at all.
extension TakoTerminalNSView {
    /// Shows a context menu. A seam for tests: a real one runs a modal menu
    /// loop that waits for someone to close it.
    nonisolated(unsafe) public static var presentContextMenu: (NSMenu, NSEvent, NSView) -> Void = { menu, event, view in
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    override open func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let loc = convert(event.locationInWindow, from: nil)
        let onStickyHeader = stickyCommandHeaderEnabled && !stickyHeaderLayer.isHidden
            && stickyHeaderLayer.frame.contains(loc)
        if !onStickyHeader {
            let report = mouseReportBytes(button: .right, action: .press, cell: cellAt(loc), event: event)
            if !report.isEmpty {
                delegate?.terminalView(self, sendInputData: report)
                return
            }
        }
        if let menu = menu(for: event) {
            Self.presentContextMenu(menu, event, self)
        } else {
            super.rightMouseDown(with: event)
        }
    }

    override open func rightMouseUp(with event: NSEvent) {
        let cell = cellAt(convert(event.locationInWindow, from: nil))
        let report = mouseReportBytes(button: .right, action: .release, cell: cell, event: event)
        if !report.isEmpty {
            delegate?.terminalView(self, sendInputData: report)
        } else {
            super.rightMouseUp(with: event)
        }
    }

    override open func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let cell = cellAt(convert(event.locationInWindow, from: nil))
        let report = mouseReportBytes(button: .middle, action: .press, cell: cell, event: event)
        if !report.isEmpty {
            delegate?.terminalView(self, sendInputData: report)
        } else {
            super.otherMouseDown(with: event)
        }
    }

    override open func otherMouseUp(with event: NSEvent) {
        let cell = cellAt(convert(event.locationInWindow, from: nil))
        let report = mouseReportBytes(button: .middle, action: .release, cell: cell, event: event)
        if !report.isEmpty {
            delegate?.terminalView(self, sendInputData: report)
        } else {
            super.otherMouseUp(with: event)
        }
    }
}
#endif
