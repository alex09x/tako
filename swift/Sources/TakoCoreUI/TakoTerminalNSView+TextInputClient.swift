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

extension TakoTerminalNSView: NSTextInputClient {
    // MARK: - NSTextInputClient & NSUserInterfaceValidations

    public func hasMarkedText() -> Bool {
        markedText != nil
    }

    public func markedRange() -> NSRange {
        guard let markedText, !markedText.isEmpty else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: 0, length: (markedText as NSString).length)
    }

    public func selectedRange() -> NSRange {
        guard let text = core.selectedText() else { return NSRange(location: 0, length: 0) }
        return NSRange(location: 0, length: (text as NSString).length)
    }

    public func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let v as NSAttributedString: markedText = v.string.isEmpty ? nil : v.string
        case let v as String: markedText = v.isEmpty ? nil : v
        default: return
        }
        scheduleRedraw()
    }

    public func unmarkText() {
        guard markedText != nil else { return }
        markedText = nil
        scheduleRedraw()
    }

    public func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    public func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard range.length > 0, let text = core.selectedText() else { return nil }
        return NSAttributedString(string: text)
    }

    public func characterIndex(for point: NSPoint) -> Int {
        0
    }

    public static func inputMethodViewRect(
        cursorCol: Int,
        cursorRow: Int,
        cols: Int,
        rows: Int,
        cellSize: CGSize,
        viewHeight: CGFloat,
        range: NSRange,
        gridOrigin: CGPoint = .zero
    ) -> NSRect {
        let safeCols = max(cols, 0)
        let safeRows = max(rows, 0)
        let safeCursorCol = min(max(cursorCol, 0), max(safeCols - 1, 0))
        var gridRow = min(max(cursorRow, 0), max(safeRows - 1, 0))
        var x = CGFloat(safeCursorCol) * cellSize.width
        var width = cellSize.width

        if range.length == 0, width > 0 {
            width = 0
            let location = range.location == NSNotFound ? 0 : range.location
            if safeCols > 0, safeRows > 0 {
                let linearCol = safeCursorCol + max(location, 0)
                let logicalRow = gridRow + linearCol / safeCols
                if logicalRow >= safeRows {
                    gridRow = safeRows - 1
                    x = CGFloat(safeCols) * cellSize.width
                } else {
                    gridRow = logicalRow
                    x = CGFloat(linearCol % safeCols) * cellSize.width
                }
            } else {
                x = 0
            }
        }

        return NSRect(
            x: gridOrigin.x + x,
            y: viewHeight - gridOrigin.y - CGFloat(gridRow + 1) * cellSize.height,
            width: width,
            height: cellSize.height
        )
    }

    public static func shouldSuppressComposingControlInput(
        _ text: String?,
        composing: Bool
    ) -> Bool {
        guard composing, let text else { return false }
        let scalars = text.unicodeScalars
        guard let scalar = scalars.first,
              scalars.index(after: scalars.startIndex) == scalars.endIndex else {
            return false
        }
        return scalar.value < 0x20
    }

    public func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        let viewRect = Self.inputMethodViewRect(
            cursorCol: Int(core.cursorCol()),
            cursorRow: Int(core.cursorRow()),
            cols: cols,
            rows: rows,
            cellSize: CGSize(width: cellWidth, height: cellHeight),
            viewHeight: bounds.height,
            range: range,
            gridOrigin: CGPoint(x: gridLayout.left, y: gridLayout.top)
        )
        let winRect = convert(viewRect, to: nil)
        guard let window else { return winRect }
        return window.convertToScreen(winRect)
    }

    public func insertText(_ string: Any, replacementRange: NSRange) {
        let chars: String
        switch string {
        case let v as NSAttributedString: chars = v.string
        case let v as String: chars = v
        default: return
        }

        unmarkText()

        if keyTextAccumulator != nil {
            keyTextAccumulator! += chars
            return
        }

        guard !chars.isEmpty else { return }
        revealLiveScreenForUserInput()

        let bytes: Data
        if chars == "\n" || chars == "\r" {
            bytes = core.encodeKey(event: FfiKeyEvent(
                key: .enter,
                text: "\r",
                physicalText: "",
                unshiftedText: "",
                shift: false, alt: false, ctrl: false, superKey: false,
                press: true, repeat: false, composing: false
            ))
        } else if chars.count == 1, let ch = chars.first {
            bytes = core.encodeKey(event: FfiKeyEvent(
                key: .character,
                text: String(ch),
                physicalText: String(ch),
                unshiftedText: String(ch),
                shift: false, alt: false, ctrl: false, superKey: false,
                press: true, repeat: false, composing: false
            ))
        } else {
            bytes = core.encodePaste(text: chars)
        }

        if !bytes.isEmpty {
            delegate?.terminalView(self, sendInputData: bytes)
        }
        scheduleRedraw()
    }

    override open func doCommand(by selector: Selector) {}

    public func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) {
            return core.hasSelection()
        }
        if item.action == #selector(paste(_:)) {
            return pasteStringProvider() != nil
        }
        if item.action == #selector(selectAll(_:)) {
            return true
        }
        if item.action == #selector(jumpToPreviousPrompt(_:)) ||
           item.action == #selector(jumpToNextPrompt(_:)) ||
           item.action == #selector(selectCommandOutput(_:)) {
            return true
        }
        if item.action == #selector(copyCommandContextAction(_:)) {
            if let target = commandTarget(from: item), let cmd = commandInfo(for: target.id, epoch: target.epoch) {
                return cmd.input != nil
            }
            return false
        }
        if item.action == #selector(rerunCommandContextAction(_:)) {
            if let target = commandTarget(from: item), let cmd = commandInfo(for: target.id, epoch: target.epoch) {
                return cmd.input != nil && !cmd.inputTruncated && isAtShellPrompt
            }
            return false
        }
        if item.action == #selector(copyOutputContextAction(_:)) ||
           item.action == #selector(sendOutputToAnotherPaneContextAction(_:)) ||
           item.action == #selector(saveOutputToFileContextAction(_:)) {
            if let target = commandTarget(from: item) {
                return commandOutput(for: target.id, epoch: target.epoch) != nil
            }
            return false
        }
        if item.action == #selector(copyBothAsMarkdownContextAction(_:)) {
            if let target = commandTarget(from: item), let cmd = commandInfo(for: target.id, epoch: target.epoch) {
                return cmd.input != nil && commandOutput(for: target.id, epoch: target.epoch) != nil
            }
            return false
        }
        if item.action == #selector(openWorkingDirectoryContextAction(_:)) {
            if let target = commandTarget(from: item), let cmd = commandInfo(for: target.id, epoch: target.epoch) {
                return cmd.cwd != nil
            }
            return false
        }
        if item.action == #selector(openLinkContextAction(_:)) ||
           item.action == #selector(copyLinkContextAction(_:)) {
            return (item as? NSMenuItem)?.representedObject is TerminalLink
        }
        return false
    }
}

public extension FfiCommandOutput {
    /// True when any part of the command's original output was evicted, overwritten, or truncated.
    var isPartial: Bool {
        incomplete || more || truncated
    }
}
#endif
