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
    // MARK: - Context Menu

    override open func menu(for event: NSEvent) -> NSMenu? {
        let loc = convert(event.locationInWindow, from: nil)
        let cell = cellAt(loc)
        if let link = linkRange(at: cell) {
            return linkContextMenu(for: link)
        }
        if let pathTarget = semanticPath(at: cell) {
            return semanticPathContextMenu(for: pathTarget)
        }
        if let targetId = commandIdForContext(at: loc),
           let cmd = commandInfo(for: targetId) {
            return contextMenu(for: cmd)
        }
        return defaultContextMenu()
    }

    public func contextMenu(for commandId: UInt64, epoch: UInt64? = nil) -> NSMenu? {
        guard let cmd = commandInfo(for: commandId, epoch: epoch) else { return nil }
        return contextMenu(for: cmd)
    }

    public func contextMenu(for cmd: FfiCommandInfo) -> NSMenu {
        let menu = NSMenu(title: "Command")
        let target = CommandTarget(id: cmd.id, epoch: cmd.epoch)
        let outputAvailable = commandOutput(for: cmd.id, epoch: cmd.epoch) != nil

        if core.hasSelection() {
            let copyItem = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
            copyItem.target = self
            menu.addItem(copyItem)
        }

        let pasteItem = NSMenuItem(title: "Paste", action: #selector(paste(_:)), keyEquivalent: "")
        pasteItem.target = self
        menu.addItem(pasteItem)

        menu.addItem(NSMenuItem.separator())

        // 1. Copy Command
        let copyCmdTitle = cmd.inputTruncated ? "Copy Command (Truncated)" : "Copy Command"
        let copyCmdItem = NSMenuItem(title: copyCmdTitle, action: #selector(copyCommandContextAction(_:)), keyEquivalent: "")
        copyCmdItem.representedObject = target
        copyCmdItem.target = self
        if cmd.input == nil {
            copyCmdItem.isEnabled = false
        }
        menu.addItem(copyCmdItem)

        // 2. Copy Output
        let copyOutItem = NSMenuItem(title: "Copy Output", action: #selector(copyOutputContextAction(_:)), keyEquivalent: "")
        copyOutItem.representedObject = target
        copyOutItem.target = self
        if !outputAvailable {
            copyOutItem.isEnabled = false
        }
        menu.addItem(copyOutItem)

        // 3. Copy Both as Markdown
        let copyMdTitle = cmd.inputTruncated ? "Copy Both as Markdown (Truncated Input)" : "Copy Both as Markdown"
        let copyMdItem = NSMenuItem(title: copyMdTitle, action: #selector(copyBothAsMarkdownContextAction(_:)), keyEquivalent: "")
        copyMdItem.representedObject = target
        copyMdItem.target = self
        if cmd.input == nil || !outputAvailable {
            copyMdItem.isEnabled = false
        }
        menu.addItem(copyMdItem)

        menu.addItem(NSMenuItem.separator())

        // 4. Re-run in This Pane
        let rerunTitle: String
        let rerunEnabled: Bool
        if cmd.inputTruncated {
            rerunTitle = "Re-run in This Pane (Truncated - Unavailable)"
            rerunEnabled = false
        } else if !isAtShellPrompt {
            rerunTitle = "Re-run in This Pane (Pane Busy)"
            rerunEnabled = false
        } else {
            rerunTitle = "Re-run in This Pane"
            rerunEnabled = (cmd.input != nil)
        }
        let rerunItem = NSMenuItem(title: rerunTitle, action: #selector(rerunCommandContextAction(_:)), keyEquivalent: "")
        rerunItem.representedObject = target
        rerunItem.target = self
        rerunItem.isEnabled = rerunEnabled
        menu.addItem(rerunItem)

        // 5. Send Output to Another Pane
        let sendItem = NSMenuItem(title: "Send Output to Another Pane", action: #selector(sendOutputToAnotherPaneContextAction(_:)), keyEquivalent: "")
        sendItem.representedObject = target
        sendItem.target = self
        if !outputAvailable {
            sendItem.isEnabled = false
        }
        menu.addItem(sendItem)

        // 6. Save Output to File…
        let saveItem = NSMenuItem(title: "Save Output to File…", action: #selector(saveOutputToFileContextAction(_:)), keyEquivalent: "")
        saveItem.representedObject = target
        saveItem.target = self
        if !outputAvailable {
            saveItem.isEnabled = false
        }
        menu.addItem(saveItem)

        menu.addItem(NSMenuItem.separator())

        // 7. Open Working Directory
        let openDirItem = NSMenuItem(title: "Open Working Directory", action: #selector(openWorkingDirectoryContextAction(_:)), keyEquivalent: "")
        openDirItem.representedObject = target
        openDirItem.target = self
        if cmd.cwd == nil {
            openDirItem.isEnabled = false
        }
        menu.addItem(openDirItem)

        menu.addItem(NSMenuItem.separator())

        let selectAllItem = NSMenuItem(title: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "")
        selectAllItem.target = self
        menu.addItem(selectAllItem)

        return menu
    }

    public func defaultContextMenu() -> NSMenu {
        let menu = NSMenu(title: "Terminal")
        if core.hasSelection() {
            let copyItem = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
            copyItem.target = self
            menu.addItem(copyItem)
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

    /// Context menu presented when right-clicking on a hyperlink (E8).
    public func linkContextMenu(for link: TerminalLink) -> NSMenu {
        let menu = NSMenu(title: "Link")
        let openTitle = link.isMismatch ? "Open Link (Suspicious Destination)..." : "Open \(link.url.absoluteString)"
        let openItem = NSMenuItem(title: openTitle, action: #selector(openLinkContextAction(_:)), keyEquivalent: "")
        openItem.representedObject = link
        openItem.target = self
        menu.addItem(openItem)

        let copyItem = NSMenuItem(title: "Copy Link", action: #selector(copyLinkContextAction(_:)), keyEquivalent: "")
        copyItem.representedObject = link
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

    @objc func openLinkContextAction(_ sender: Any?) {
        guard let link = (sender as? NSMenuItem)?.representedObject as? TerminalLink else { return }
        openLink(link, previewAlreadyPresented: true)
    }

    @objc func copyLinkContextAction(_ sender: Any?) {
        guard let link = (sender as? NSMenuItem)?.representedObject as? TerminalLink else { return }
        copyStringConsumer(link.url.absoluteString)
    }

    /// Resolves the target (id and epoch) from a menu item or current context.
    public func commandTarget(from sender: Any?) -> CommandTarget? {
        if let target = (sender as? NSMenuItem)?.representedObject as? CommandTarget {
            return target
        }
        if let id = (sender as? NSMenuItem)?.representedObject as? UInt64 {
            if let cmd = commandInfo(for: id) {
                return CommandTarget(id: cmd.id, epoch: cmd.epoch)
            }
        }
        if let id = commandIdForContext() {
            if let cmd = commandInfo(for: id) {
                return CommandTarget(id: cmd.id, epoch: cmd.epoch)
            }
        }
        return nil
    }

    @objc func copyCommandContextAction(_ sender: Any?) {
        guard let target = commandTarget(from: sender) else { return }
        copyCommand(id: target.id, epoch: target.epoch)
    }

    @objc func copyOutputContextAction(_ sender: Any?) {
        guard let target = commandTarget(from: sender) else { return }
        copyOutput(id: target.id, epoch: target.epoch)
    }

    @objc func copyBothAsMarkdownContextAction(_ sender: Any?) {
        guard let target = commandTarget(from: sender) else { return }
        copyBothAsMarkdown(id: target.id, epoch: target.epoch)
    }

    @objc func rerunCommandContextAction(_ sender: Any?) {
        guard let target = commandTarget(from: sender) else { return }
        rerunCommand(id: target.id, epoch: target.epoch)
    }

    @objc func sendOutputToAnotherPaneContextAction(_ sender: Any?) {
        guard let target = commandTarget(from: sender) else { return }
        sendOutputToAnotherPane(id: target.id, epoch: target.epoch)
    }

    @objc func saveOutputToFileContextAction(_ sender: Any?) {
        guard let target = commandTarget(from: sender) else { return }
        saveOutputToFile(id: target.id, epoch: target.epoch)
    }

    @objc func openWorkingDirectoryContextAction(_ sender: Any?) {
        guard let target = commandTarget(from: sender) else { return }
        openWorkingDirectory(id: target.id, epoch: target.epoch)
    }

    // MARK: - Drag and Drop

    override open func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.availableType(from: [.fileURL, .string]) != nil ? .copy : []
    }

    /// Shell-quotes a file path or string so it can be safely pasted or dropped
    /// into a POSIX shell command line without unintended expansion or word splitting.
    public static func shellQuote(_ string: String) -> String {
        guard !string.isEmpty else { return "''" }
        let isSafe = string.allSatisfy { c in
            c.isASCII && (c.isLetter || c.isNumber || "_@%+=:,./-".contains(c))
        }
        if isSafe {
            return string
        }
        return "'" + string.replacingOccurrences(of: "'", with: #"'"'"'"#) + "'"
    }

    override open func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            let text = urls.map { url -> String in
                Self.shellQuote(url.path)
            }.joined(separator: " ")
            revealLiveScreenForUserInput()
            let bytes = core.encodePaste(text: text)
            if !bytes.isEmpty { delegate?.terminalView(self, sendInputData: bytes) }
            return true
        }
        if let text = pasteboard.string(forType: .string) {
            revealLiveScreenForUserInput()
            let bytes = core.encodePaste(text: text)
            if !bytes.isEmpty { delegate?.terminalView(self, sendInputData: bytes) }
            return true
        }
        return false
    }

    // MARK: - Services Menu

    override open func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        let canSend = sendType == nil || (sendType == .string && core.hasSelection())
        let canReturn = returnType == nil || returnType == .string
        if canSend && canReturn { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    @objc public func writeSelection(
        to pboard: NSPasteboard,
        types: [NSPasteboard.PasteboardType]
    ) -> Bool {
        guard let text = core.selectedText() else { return false }
        pboard.clearContents()
        return pboard.setString(text, forType: .string)
    }

    @objc public func readSelection(from pboard: NSPasteboard) -> Bool {
        guard let text = pboard.string(forType: .string) else { return false }
        revealLiveScreenForUserInput()
        let bytes = core.encodePaste(text: text)
        if !bytes.isEmpty { delegate?.terminalView(self, sendInputData: bytes) }
        return true
    }
}
#endif
