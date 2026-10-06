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
    // MARK: - Semantic Path Detection (E6)

    /// Validates a raw path extracted from terminal text according to the E6 safety gate.
    /// Rejects control characters, shell metacharacters, leading hyphens, and non-existent files.
    /// Returns standardized absolute path on success, nil on failure.
    public func validateSemanticPath(rawPath: String) -> String? {
        guard !rawPath.isEmpty else { return nil }

        // Reject control characters (ASCII < 32 or 127)
        guard !rawPath.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            return nil
        }

        // Reject shell metacharacters and whitespace
        let forbidden = CharacterSet(charactersIn: ";|<>&`$!\"'*?[]{}() \t\r\n\\")
        guard rawPath.rangeOfCharacter(from: forbidden) == nil else {
            return nil
        }

        // Reject leading hyphen or path components with leading hyphen (e.g. CLI flags)
        guard !rawPath.hasPrefix("-") else { return nil }
        let components = rawPath.split(separator: "/")
        guard !components.contains(where: { $0.hasPrefix("-") }) else { return nil }

        let resolvedPath: String
        if rawPath == "~" {
            resolvedPath = FileManager.default.homeDirectoryForCurrentUser.path
        } else if rawPath.hasPrefix("~/") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            resolvedPath = (home as NSString).appendingPathComponent(String(rawPath.dropFirst(2)))
        } else if rawPath.hasPrefix("/") {
            resolvedPath = rawPath
        } else {
            let baseDir = workingDirectory ?? FileManager.default.currentDirectoryPath
            resolvedPath = (baseDir as NSString).appendingPathComponent(rawPath)
        }
        let standardized = (resolvedPath as NSString).standardizingPath

        // Safety gate: ignore non-existent files without side effects
        guard FileManager.default.fileExists(atPath: standardized) else {
            return nil
        }
        return standardized
    }

    /// Detects a validated source file path (with optional line and column) at the specified cell (E6).
    public func semanticPath(at cell: (row: Int, col: Int)) -> SemanticPathTarget? {
        guard semanticPathDetectionEnabled else { return nil }

        // Safety gate: reject disguised OSC 8 targets
        guard core.getCell(row: UInt32(cell.row), col: UInt32(cell.col))?.hyperlinkUri == nil else {
            return nil
        }

        let (lineText, columns) = Self.rowText(core.viewportRow(row: UInt32(cell.row)))
        guard !lineText.isEmpty, !columns.isEmpty else { return nil }

        let nsText = lineText as NSString
        let matches = Self.semanticPathPattern.matches(in: lineText, range: NSRange(location: 0, length: nsText.length))

        for match in matches {
            guard match.numberOfRanges >= 2 else { continue }
            let fullRange = match.range
            let first = fullRange.location
            let last = fullRange.location + fullRange.length - 1
            guard first < columns.count, last < columns.count else { continue }

            let colStart = columns[first]
            let colEnd = columns[last]

            guard colStart <= cell.col, cell.col <= colEnd else { continue }

            let rawPath = nsText.substring(with: match.range(at: 1))
            var lineNum: Int? = nil
            if match.numberOfRanges >= 3 && match.range(at: 2).location != NSNotFound {
                lineNum = Int(nsText.substring(with: match.range(at: 2)))
            }
            var colNum: Int? = nil
            if match.numberOfRanges >= 4 && match.range(at: 3).location != NSNotFound {
                colNum = Int(nsText.substring(with: match.range(at: 3)))
            }

            guard let validated = validateSemanticPath(rawPath: rawPath) else {
                continue
            }

            return SemanticPathTarget(
                rawPath: rawPath,
                line: lineNum,
                col: colNum,
                resolvedPath: validated,
                row: cell.row,
                colStart: colStart,
                colEnd: colEnd
            )
        }

        return nil
    }

    /// Passes the validated semantic path target strictly as data arguments to configured editor or event hook (E6).
    public func openSemanticPath(_ target: SemanticPathTarget) {
        let payload = SemanticPathPayload(
            path: target.rawPath,
            line: target.line,
            col: target.col,
            cwd: workingDirectory,
            resolvedPath: target.resolvedPath
        )
        onSemanticPathClick?(payload)
        delegate?.terminalView(self, didClickSemanticPath: payload)

        let editor = configuredEditorCommand ?? ProcessInfo.processInfo.environment["EDITOR"] ?? ProcessInfo.processInfo.environment["VISUAL"] ?? "code"

        // Safety gate on editor command: reject shell metacharacters and leading hyphens
        let forbidden = CharacterSet(charactersIn: ";|<>&`$!\"'*?[]{}() \t\r\n\\")
        guard editor.rangeOfCharacter(from: forbidden) == nil, !editor.hasPrefix("-") else {
            return
        }

        let args: [String]
        let editorLower = editor.lowercased()
        if editorLower.contains("code") || editorLower.contains("cursor") {
            if let line = target.line {
                let loc = "\(target.resolvedPath):\(line)\(target.col != nil ? ":\(target.col!)" : "")"
                args = ["-g", loc]
            } else {
                args = [target.resolvedPath]
            }
        } else if editorLower.contains("vim") || editorLower.contains("vi") {
            if let line = target.line {
                args = ["+\(line)", target.resolvedPath]
            } else {
                args = [target.resolvedPath]
            }
        } else if editorLower.contains("subl") {
            if let line = target.line {
                let loc = "\(target.resolvedPath):\(line)\(target.col != nil ? ":\(target.col!)" : "")"
                args = [loc]
            } else {
                args = [target.resolvedPath]
            }
        } else if editorLower.contains("nano") {
            if let line = target.line {
                let loc = target.col != nil ? "+\(line),\(target.col!)" : "+\(line)"
                args = [loc, target.resolvedPath]
            } else {
                args = [target.resolvedPath]
            }
        } else if editorLower.contains("emacs") {
            if let line = target.line {
                args = ["+\(line)", target.resolvedPath]
            } else {
                args = [target.resolvedPath]
            }
        } else {
            if let line = target.line {
                let loc = "\(target.resolvedPath):\(line)\(target.col != nil ? ":\(target.col!)" : "")"
                args = ["-g", loc]
            } else {
                args = [target.resolvedPath]
            }
        }

        if let launcher = Self.editorLauncher {
            _ = launcher(editor, args, workingDirectory)
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [editor] + args
        if let cwd = workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }
        try? process.run()
    }

    /// Context menu presented when right-clicking on a validated source code path (E6).
    public func semanticPathContextMenu(for target: SemanticPathTarget) -> NSMenu {
        let menu = NSMenu(title: "Semantic Path")
        let editorName = configuredEditorCommand ?? ProcessInfo.processInfo.environment["EDITOR"] ?? "Editor"
        let openTitle = "Open \(target.rawPath) in \(editorName)"
        let openItem = NSMenuItem(title: openTitle, action: #selector(openSemanticPathContextAction(_:)), keyEquivalent: "")
        openItem.representedObject = target
        openItem.target = self
        menu.addItem(openItem)

        let copyItem = NSMenuItem(title: "Copy Path", action: #selector(copySemanticPathContextAction(_:)), keyEquivalent: "")
        copyItem.representedObject = target
        copyItem.target = self
        menu.addItem(copyItem)

        menu.addItem(NSMenuItem.separator())
        if core.hasSelection() {
            let copySelectionItem = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
            copySelectionItem.target = self
            menu.addItem(copySelectionItem)
        }
        let pasteItem = NSMenuItem(title: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        pasteItem.target = self
        menu.addItem(pasteItem)
        menu.addItem(NSMenuItem.separator())
        let selectAllItem = NSMenuItem(title: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "")
        selectAllItem.target = self
        menu.addItem(selectAllItem)
        return menu
    }

    @objc func openSemanticPathContextAction(_ sender: Any?) {
        guard let target = (sender as? NSMenuItem)?.representedObject as? SemanticPathTarget else { return }
        openSemanticPath(target)
    }

    @objc func copySemanticPathContextAction(_ sender: Any?) {
        guard let target = (sender as? NSMenuItem)?.representedObject as? SemanticPathTarget else { return }
        copyStringConsumer(target.resolvedPath)
    }
}
#endif
