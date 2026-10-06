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
import OSLog

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

extension TakoTerminalNSView {
    // MARK: - Core Host Operations

    /// Feed raw bytes received from the PTY host connection synchronously.
    public func feed(data: Data) {
        parserCoordinator.feedSynchronously(data)
    }

    /// Hand bulk PTY output to the parser without waiting for it.
    public func enqueue(data: Data) {
        parserCoordinator.enqueue(data)
    }

    /// Replace the terminal from a checkpoint, ordered against the parser.
    @discardableResult
    public func importCheckpoint(_ blob: Data) throws -> TerminalCheckpointRestore {
        try parserCoordinator.importCheckpoint(blob)
    }

    /// What a checkpoint declares, without importing it -- so a host can
    /// negotiate before committing.
    public func inspectCheckpoint(_ blob: Data) throws -> FfiCheckpointInfo {
        try core.checkpointInspect(blob: blob)
    }

    /// The container version this build writes.
    public var checkpointVersion: UInt32 { core.checkpointVersion() }

    /// Whether this build can import that container version.
    public func supportsCheckpointVersion(_ version: UInt32) -> Bool {
        core.checkpointSupports(version: version)
    }

    /// Export the terminal as a checkpoint, bounded by a caller-supplied cap.
    public func exportCheckpoint(maxBytes: UInt64 = 64 * 1024 * 1024) throws -> Data {
        try core.checkpointExport(flags: 0, maxBytes: maxBytes)
    }

    /// Adopt a completed restore on Main, in parser order.
    func applyCheckpointRestore(_ restore: TerminalCheckpointRestore) {
        pendingResizeWorkItem?.cancel()
        pendingResizeWorkItem = nil
        pendingGridSize = nil

        subCellScroll.clear()

        cols = restore.cols
        rows = restore.rows
        lastReportedScrollPosition = core.scrollPosition()
        trackedCommands.removeAll()
        trackedCommandsEpoch = core.stateEpoch()
        if stickyCommandHeaderEnabled {
            activeRunningCommandId = findRunningCommandId()
            if let runningId = activeRunningCommandId {
                let firstLine = core.firstRetainedLine()
                let totalScrollback = Int(core.scrollbackLen())
                let cmdText = core.firstCommandAfter(after: runningId - 1)?.input?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let promptLine = core.commandMarks().first(where: { $0.commandId == runningId })?.promptLine
                let startLine = computeStartOutputAbsLine(
                    promptLine: promptLine,
                    cmdText: cmdText,
                    firstRetainedLine: firstLine,
                    totalScrollback: totalScrollback
                )
                let absLine = firstLine + UInt64(totalScrollback) + UInt64(core.cursorRow())
                trackedCommands[runningId] = TrackedCommandOutput(
                    commandId: runningId,
                    command: cmdText,
                    promptLine: promptLine,
                    startOutputAbsLine: startLine,
                    startCursorCol: core.cursorCol(),
                    lastOutputAbsLine: max(absLine, startLine),
                    status: 0,
                    exitCode: nil,
                    hasNoOutput: false,
                    outputResolved: false
                )
            }
        } else {
            activeRunningCommandId = nil
        }
        TakoLog.resize.info("checkpoint restored \(restore.cols)×\(restore.rows)")
        updateScroller()
        delegate?.terminalView(self, didRestoreCheckpoint: restore)

        delegate?.terminalViewDidChangeContent(self)
        scheduleRedraw()
    }

    /// Replies the engine queued outside a parse -- a colour-scheme change
    /// told to a program that set mode 2031 -- sent now, not with whatever
    /// the program prints next.
    func sendQueuedReplies() {
        let queued = core.takeOutput()
        if !queued.isEmpty {
            delegate?.terminalView(self, sendDeviceReplyData: queued)
        }
    }

    /// The one place a parsed batch becomes AppKit state, always on Main and
    /// always in the order the batches were parsed.
    func apply(_ outcomes: [FfiFeedOutcome]) {
        var totalDamage = false
        var commandStatusChanged = false
        for outcome in outcomes {
            if !outcome.output.isEmpty {
                delegate?.terminalView(self, sendDeviceReplyData: outcome.output)
            }

            for event in outcome.events {
                switch event {
                case .titleChanged(let title):
                    self.title = title
                    TakoLog.feed.info("title → \"\(title)\"")
                    delegate?.terminalView(self, didChangeTitle: title)
                case .bell:
                    TakoLog.feed.debug("bell")
                    delegate?.terminalViewDidBell(self)
                case .commandStart(let id):
                    commandStatusChanged = true
                    let currentEpoch = core.stateEpoch()
                    if trackedCommandsEpoch != currentEpoch {
                        trackedCommands.removeAll()
                        commandDurations.removeAll()
                        notifiedTriggerMatches.removeAll()
                        trackedCommandsEpoch = currentEpoch
                        activeRunningCommandId = nil
                    }
                    let targetId = id ?? core.newestCommandId()
                    let now = Date()
                    if let cmdId = targetId {
                        activeRunningCommandId = cmdId
                        let firstLine = core.firstRetainedLine()
                        let totalScrollback = Int(core.scrollbackLen())
                        let cmdText = core.firstCommandAfter(after: cmdId - 1)?.input?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        let promptLine = core.commandMarks().first(where: { $0.commandId == cmdId })?.promptLine
                        let startLine = computeStartOutputAbsLine(
                            promptLine: promptLine,
                            cmdText: cmdText,
                            firstRetainedLine: firstLine,
                            totalScrollback: totalScrollback
                        )
                        let absLine = firstLine + UInt64(totalScrollback) + UInt64(core.cursorRow())
                        trackedCommands[cmdId] = TrackedCommandOutput(
                            commandId: cmdId,
                            command: cmdText,
                            promptLine: promptLine,
                            startOutputAbsLine: startLine,
                            startCursorCol: core.cursorCol(),
                            lastOutputAbsLine: max(absLine, startLine),
                            status: 0,
                            exitCode: nil,
                            hasNoOutput: false,
                            outputResolved: false,
                            startedAt: now,
                            endedAt: nil,
                            duration: nil
                        )
                    }
                    delegate?.terminalViewCommandDidStart(self)
                case .commandEnd(let exitCode):
                    commandStatusChanged = true
                    let currentEpoch = core.stateEpoch()
                    if trackedCommandsEpoch != currentEpoch {
                        trackedCommands.removeAll()
                        commandDurations.removeAll()
                        trackedCommandsEpoch = currentEpoch
                        activeRunningCommandId = nil
                    }
                    let targetId = activeRunningCommandId ?? core.newestCommandId()
                    let now = Date()
                    if let cmdId = targetId {
                        let existing = trackedCommands[cmdId]
                        let promptLine = existing?.promptLine ?? core.commandMarks().first(where: { $0.commandId == cmdId })?.promptLine
                        let status: UInt8 = (exitCode == 0 ? 1 : 2)
                        let cmdText = (existing?.command.isEmpty == false)
                            ? existing!.command
                            : (core.firstCommandAfter(after: cmdId - 1)?.input?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
                        let startLine: UInt64
                        if let existingStart = existing?.startOutputAbsLine, existingStart > (promptLine ?? 0) {
                            startLine = existingStart
                        } else {
                            startLine = computeStartOutputAbsLine(
                                promptLine: promptLine,
                                cmdText: cmdText,
                                firstRetainedLine: core.firstRetainedLine(),
                                totalScrollback: Int(core.scrollbackLen())
                            )
                        }
                        let startedAt = existing?.startedAt ?? core.firstCommandAfter(after: cmdId > 0 ? cmdId - 1 : 0).flatMap { $0.startedAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000.0) } }
                        let duration = startedAt.map { max(0.0, now.timeIntervalSince($0)) }
                        if let duration {
                            commandDurations[cmdId] = duration
                        }
                        var tracked = existing ?? TrackedCommandOutput(
                            commandId: cmdId,
                            command: cmdText,
                            promptLine: promptLine,
                            startOutputAbsLine: startLine,
                            startCursorCol: 0,
                            lastOutputAbsLine: startLine,
                            status: status,
                            exitCode: exitCode,
                            hasNoOutput: false,
                            outputResolved: false,
                            startedAt: startedAt,
                            endedAt: now,
                            duration: duration
                        )
                        tracked.promptLine = promptLine
                        tracked.startOutputAbsLine = startLine
                        tracked.status = status
                        tracked.exitCode = exitCode
                        tracked.outputResolved = false
                        tracked.startedAt = startedAt
                        tracked.endedAt = now
                        tracked.duration = duration
                        if tracked.command.isEmpty, !cmdText.isEmpty {
                            tracked.command = cmdText
                        }
                        trackedCommands[cmdId] = tracked
                    }
                    activeRunningCommandId = nil
                    delegate?.terminalView(self, commandDidEnd: exitCode)
                case .clipboardSet(let text):
                    TakoLog.feed.info("OSC 52 → clipboard (\(text.count) chars)")
                    delegate?.terminalView(self, didRequestClipboardCopy: text)
                case .pwdChanged(let url):
                    let path = URL(string: url)?.path ?? url
                    self.workingDirectory = path
                    delegate?.terminalView(self, didChangeWorkingDirectory: path)
                case .promptMark:
                    delegate?.terminalViewPromptMark(self)
                case let .statusSet(status, text):
                    delegate?.terminalView(self, didReportStatus: status, text: text)
                case .statusClear:
                    delegate?.terminalViewDidClearStatus(self)
                default:
                    break
                }
            }

            if stickyCommandHeaderEnabled && outcome.hasDamage {
                if activeRunningCommandId == nil {
                    activeRunningCommandId = findRunningCommandId()
                }
                if let cmdId = activeRunningCommandId {
                    let totalScrollback = UInt64(core.scrollbackLen())
                    let cursorRow = UInt64(core.cursorRow())
                    let firstLine = core.firstRetainedLine()
                    let absLine = firstLine + totalScrollback + cursorRow
                    if var tracked = trackedCommands[cmdId] {
                        tracked.lastOutputAbsLine = max(tracked.lastOutputAbsLine, absLine)
                        if tracked.command.isEmpty, let info = core.firstCommandAfter(after: cmdId - 1), let input = info.input?.trimmingCharacters(in: .whitespacesAndNewlines) {
                            tracked.command = input
                        }
                        trackedCommands[cmdId] = tracked
                    } else {
                        let cmdText = core.firstCommandAfter(after: cmdId - 1)?.input?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        let promptLine = core.commandMarks().first(where: { $0.commandId == cmdId })?.promptLine
                        trackedCommands[cmdId] = TrackedCommandOutput(
                            commandId: cmdId,
                            command: cmdText,
                            promptLine: promptLine,
                            startOutputAbsLine: absLine,
                            startCursorCol: 0,
                            lastOutputAbsLine: absLine,
                            status: 0,
                            exitCode: nil,
                            hasNoOutput: false,
                            outputResolved: false
                        )
                    }
                }
            }

            if outcome.hasDamage && !outcome.synchronizedOutputActive {
                totalDamage = true
                updateScroller()
                scheduleRedraw()
            }
        }

        if redrawHeldBySynchronizedOutput && !core.isSynchronizedOutputActive() {
            redrawHeldBySynchronizedOutput = false
            scheduleRedraw()
        }

        if commandStatusChanged && core.isSynchronizedOutputActive() {
            commandMarksHeldBySynchronizedOutput = true
        }

        let shouldUpdateMarksForCommandStatus = (commandStatusChanged || commandMarksHeldBySynchronizedOutput)
            && !totalDamage
            && !core.isSynchronizedOutputActive()

        if shouldUpdateMarksForCommandStatus {
            commandMarksHeldBySynchronizedOutput = false
            updateScroller()
        } else if totalDamage {
            commandMarksHeldBySynchronizedOutput = false
        }

        if totalDamage {
            TakoLog.render.debug("damage → scheduleRedraw (\(outcomes.count) outcomes)")
            delegate?.terminalViewDidChangeContent(self)
            notifyScrollPositionIfChanged()
            if isOutputFilterActive {
                refreshOutputFilterMatches()
            }
        }
    }
}
#endif
