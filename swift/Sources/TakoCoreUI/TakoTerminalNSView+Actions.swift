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
    // MARK: - Copy & Paste

    @objc public func copy(_ sender: Any?) {
        guard let text = core.selectedText() else { return }
        copyStringConsumer(text)
    }

    @objc public func paste(_ sender: Any?) {
        guard let string = pasteStringProvider() else { return }
        revealLiveScreenForUserInput()
        handlePaste(string)
    }

    /// Inserts input text at the prompt, stripping any trailing line endings and routing through safe paste.
    @objc open func insertInputText(_ text: String) {
        revealLiveScreenForUserInput()
        var cleanText = text
        while cleanText.hasSuffix("\n") || cleanText.hasSuffix("\r") {
            cleanText.removeLast()
        }
        guard !cleanText.isEmpty else { return }
        handlePaste(cleanText)
    }

    /// Routes pasted or inserted text through safe checks before sending to the shell.
    /// Withholds unsafe line breaks when DEC bracketed-paste mode is disabled until confirmed.
    @objc open func handlePaste(_ text: String) {
        let isMultiLine = text.contains("\n") || text.contains("\r") || core.pasteIsUnsafe(text: text)
        let isUnbracketed = !core.modes().bracketedPaste
        if isMultiLine && isUnbracketed {
            if let confirmPasteHandler {
                confirmPasteHandler(text) { [weak self] confirmed in
                    guard confirmed, let self else { return }
                    self.performPaste(text)
                }
                return
            } else if let window = self.window {
                let alert = NSAlert()
                alert.messageText = "Confirm Multiline Paste"
                alert.informativeText = "The text to be pasted contains multiple lines or line breaks, and bracketed paste mode is disabled. Pasting it may execute commands immediately without confirmation."
                alert.addButton(withTitle: "Paste")
                alert.addButton(withTitle: "Cancel")
                alert.beginSheetModal(for: window) { [weak self] response in
                    guard response == .alertFirstButtonReturn, let self else { return }
                    self.performPaste(text)
                }
                return
            } else {
                performPaste(text)
                return
            }
        }
        performPaste(text)
    }

    func performPaste(_ text: String) {
        let bytes = core.encodePaste(text: text)
        if !bytes.isEmpty {
            delegate?.terminalView(self, sendInputData: bytes)
        }
    }

    @objc override open func selectAll(_ sender: Any?) {
        core.startSelection(row: 0, col: 0, mode: .linear)
        core.extendSelection(row: UInt32(max(rows - 1, 0)), col: UInt32(max(cols - 1, 0)))
        scheduleRedraw()
    }

    // MARK: - Command Actions

    /// Returns all recorded commands currently kept in the engine's memory.
    public func recordedCommands() -> [FfiCommandInfo] {
        var commands: [FfiCommandInfo] = []
        var after: UInt64 = 0
        while let cmd = core.firstCommandAfter(after: after) {
            commands.append(cmd)
            after = cmd.id
        }
        return commands
    }

    /// Structure identifying a command within a specific engine generation epoch.
    public struct CommandTarget: Hashable, Sendable {
        public let id: UInt64
        public let epoch: UInt64

        public init(id: UInt64, epoch: UInt64) {
            self.id = id
            self.epoch = epoch
        }
    }

    /// Looks up command info for a specific command ID and optional epoch.
    public func commandInfo(for id: UInt64, epoch: UInt64? = nil) -> FfiCommandInfo? {
        guard id > 0 else { return nil }
        if let info = core.firstCommandAfter(after: id - 1), info.id == id {
            if let epoch, info.epoch != epoch {
                return nil
            }
            return info
        }
        return nil
    }

    /// Resolves the command output record including completion metadata.
    public func commandOutput(for commandId: UInt64, epoch: UInt64? = nil) -> FfiCommandOutput? {
        let currentEpoch = core.stateEpoch()
        if let epoch, epoch != currentEpoch {
            return nil
        }
        return core.commandOutput(id: commandId, epoch: epoch ?? currentEpoch, maxLines: 500_000, maxBytes: 50_000_000)
    }

    /// Resolves the output string of a recorded command, or nil if unavailable.
    public func commandOutputString(for commandId: UInt64, epoch: UInt64? = nil) -> String? {
        commandOutput(for: commandId, epoch: epoch)?.output
    }

    /// Identifies the command ID associated with a view point or the current context.
    public func commandIdForContext(at point: NSPoint? = nil) -> UInt64? {
        if let point {
            if stickyCommandHeaderEnabled && !stickyHeaderLayer.isHidden && stickyHeaderLayer.frame.contains(point) {
                if let header = activeStickyCommandHeader ?? currentStickyCommandHeader() {
                    return header.commandId
                }
            }
            let cell = cellAt(point)
            let totalScrollback = Int(core.scrollbackLen())
            let offset = Int(core.viewportOffset())
            let vpTop = totalScrollback - offset
            let firstRetainedLine = core.firstRetainedLine()
            let cellAbsLine = firstRetainedLine + UInt64(max(0, vpTop + cell.row))

            let marks = core.commandMarks().sorted(by: { $0.promptLine < $1.promptLine })
            if let mark = marks.last(where: { $0.promptLine <= cellAbsLine }) {
                return mark.commandId
            } else if let firstMark = marks.first, cellAbsLine < firstMark.promptLine {
                if firstMark.commandId > 1 {
                    return firstMark.commandId - 1
                }
            }
        }

        return activeStickyCommandHeader?.commandId
            ?? activeRunningCommandId
            ?? findRunningCommandId()
            ?? core.newestCommandId()
    }

    /// Determines the shortest code fence (at least 3 backticks) that does not occur in `text`.
    public static func markdownCodeFence(for text: String) -> String {
        var maxRun = 0
        var currentRun = 0
        for ch in text {
            if ch == "`" {
                currentRun += 1
                if currentRun > maxRun {
                    maxRun = currentRun
                }
            } else {
                currentRun = 0
            }
        }
        let fenceLen = max(3, maxRun + 1)
        return String(repeating: "`", count: fenceLen)
    }

    /// Formats a command and its output as Markdown using backtick fences safe against content collisions.
    public static func formatCommandAndOutputAsMarkdown(
        command: String,
        output: String,
        isInputTruncated: Bool = false,
        isPartial: Bool = false
    ) -> String {
        let cmdFence = markdownCodeFence(for: command)
        let cmdNote = isInputTruncated ? "\n<!-- Note: Command input was truncated to buffer limit -->" : ""
        var md = "\(cmdFence)bash\n\(command)\n\(cmdFence)\(cmdNote)"
        let trimmedOutput = output.hasSuffix("\n") ? String(output.dropLast()) : output
        if !trimmedOutput.isEmpty || isPartial {
            let outFence = markdownCodeFence(for: trimmedOutput)
            let note = isPartial ? "\n<!-- Note: Output was partially evicted or truncated from scrollback -->" : ""
            md += "\n\n\(outFence)\n\(trimmedOutput)\n\(outFence)\(note)"
        }
        return md
    }

    /// 1. Copy command to clipboard.
    public func copyCommand(id: UInt64, epoch: UInt64? = nil) {
        guard let cmd = commandInfo(for: id, epoch: epoch), let input = cmd.input else { return }
        let text = cmd.inputTruncated ? "\(input) # [truncated]" : input
        copyStringConsumer(text)
    }

    /// 2. Copy output to clipboard. Aborts if output is unavailable (e.g. evicted or wrong epoch).
    public func copyOutput(id: UInt64, epoch: UInt64? = nil) {
        guard let output = commandOutputString(for: id, epoch: epoch) else { return }
        copyStringConsumer(output)
    }

    /// 3. Copy both command and output as a Markdown block. Aborts if output is unavailable.
    public func copyBothAsMarkdown(id: UInt64, epoch: UInt64? = nil) {
        guard let cmd = commandInfo(for: id, epoch: epoch), let input = cmd.input else { return }
        guard let outRecord = commandOutput(for: id, epoch: epoch) else { return }
        let md = Self.formatCommandAndOutputAsMarkdown(
            command: input,
            output: outRecord.output,
            isInputTruncated: cmd.inputTruncated,
            isPartial: outRecord.isPartial
        )
        copyStringConsumer(md)
    }

    /// 4. Re-run command in this pane (inserted at the prompt, not executed).
    public func rerunCommand(id: UInt64, epoch: UInt64? = nil) {
        guard let cmd = commandInfo(for: id, epoch: epoch), let input = cmd.input, !cmd.inputTruncated else { return }
        guard isAtShellPrompt else { return }
        revealLiveScreenForUserInput()
        window?.makeFirstResponder(self)
        var text = input
        while text.hasSuffix("\n") || text.hasSuffix("\r") {
            text.removeLast()
        }
        guard !text.isEmpty else { return }
        insertInputText(text)
    }

    /// 5. Send output to another pane as text (inserted at the prompt, not executed). Aborts if output is unavailable.
    public func sendOutputToAnotherPane(id: UInt64, epoch: UInt64? = nil) {
        guard let output = commandOutputString(for: id, epoch: epoch) else { return }
        var cleanText = output
        while cleanText.hasSuffix("\n") || cleanText.hasSuffix("\r") {
            cleanText.removeLast()
        }
        if let sendTextToAnotherPaneHandler {
            sendTextToAnotherPaneHandler(cleanText)
        } else {
            delegate?.terminalView(self, sendTextToAnotherPane: cleanText)
        }
    }

    /// 6. Save output to a file via save panel. Aborts if output is unavailable.
    public func saveOutputToFile(id: UInt64, epoch: UInt64? = nil, completion: ((URL?) -> Void)? = nil) {
        guard let outRecord = commandOutput(for: id, epoch: epoch) else {
            completion?(nil)
            return
        }
        let output = outRecord.output
        let suffix = outRecord.isPartial ? "-partial" : ""
        let suggestedFilename = "command-\(id)-output\(suffix).txt"
        Self.saveFilePanel(output, suggestedFilename, window) { url in
            completion?(url)
        }
    }

    /// Directly save output to a file URL.
    public func saveOutput(for id: UInt64, epoch: UInt64? = nil, to url: URL) throws {
        guard let output = commandOutputString(for: id, epoch: epoch) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try output.write(to: url, atomically: true, encoding: .utf8)
    }

    /// 7. Open working directory in Finder.
    public func openWorkingDirectory(id: UInt64, epoch: UInt64? = nil) {
        guard let cmd = commandInfo(for: id, epoch: epoch), let cwd = cmd.cwd else { return }
        let url: URL
        if cwd.hasPrefix("file://") {
            url = URL(string: cwd) ?? URL(fileURLWithPath: cwd)
        } else {
            url = URL(fileURLWithPath: cwd)
        }
        Self.openURL(url)
    }
}
#endif
