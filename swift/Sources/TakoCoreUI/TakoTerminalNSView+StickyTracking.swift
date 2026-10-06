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
    func computeStartOutputAbsLine(
        promptLine: UInt64?,
        cmdText: String,
        firstRetainedLine: UInt64,
        totalScrollback: Int
    ) -> UInt64 {
        guard let pLine = promptLine else {
            return firstRetainedLine
        }

        var promptContinuations: UInt64 = 0
        if pLine >= firstRetainedLine {
            var r = pLine - firstRetainedLine + 1
            let totalRetained = UInt64(totalScrollback + Int(core.rows()))
            while r < totalRetained && core.retainedSemanticPrompt(row: r) == 2 {
                promptContinuations += 1
                r += 1
            }
        }

        let terminalCols = max(1, Int(core.cols()))
        let lines = cmdText.split(separator: "\n", omittingEmptySubsequences: false)
        var wrappedInputRows: UInt64 = 0
        for line in lines {
            let rowsForLine = max(1, (line.count + terminalCols - 1) / terminalCols)
            wrappedInputRows += UInt64(rowsForLine)
        }

        let inputRows = max(wrappedInputRows, promptContinuations + 1)
        return max(firstRetainedLine, pLine + inputRows)
    }

    /// Computes the sticky command header for the current viewport state, or nil if unpinned.
    public func currentStickyCommandHeader() -> StickyCommandHeader? {
        guard stickyCommandHeaderEnabled, !core.modes().alternateScreen else {
            return nil
        }

        let currentEpoch = core.stateEpoch()
        if trackedCommandsEpoch != currentEpoch {
            trackedCommands.removeAll()
            trackedCommandsEpoch = currentEpoch
            activeRunningCommandId = findRunningCommandId()
        }

        let totalScrollback = Int(core.scrollbackLen())
        let offset = Int(core.viewportOffset())
        let vpTop = totalScrollback - offset
        guard vpTop >= 0 else { return nil }

        let firstRetainedLine = core.firstRetainedLine()
        let vpTopAbsLine = firstRetainedLine + UInt64(vpTop)
        let currentBottom = firstRetainedLine + UInt64(totalScrollback) + UInt64(core.cursorRow())

        // Refresh/prune existing tracked commands for evicted outputs or removed history
        if let oldestRecord = core.firstCommandAfter(after: 0) {
            let oldestId = oldestRecord.id
            for (id, cmd) in trackedCommands {
                if cmd.status != 0 && !cmd.hasNoOutput && cmd.lastOutputAbsLine < firstRetainedLine {
                    trackedCommands[id]?.hasNoOutput = true
                }
            }
            trackedCommands = trackedCommands.filter { id, _ in
                id >= oldestId
            }
        } else {
            trackedCommands.removeAll()
        }

        // Bound memory: if tracked cache grows, prune distant records
        if trackedCommands.count > 128 {
            let sortedKeys = trackedCommands.keys.sorted()
            let pruneCount = trackedCommands.count - 64
            for id in sortedKeys.prefix(pruneCount) {
                if id != activeRunningCommandId {
                    trackedCommands.removeValue(forKey: id)
                }
            }
        }

        let marks = core.commandMarks().sorted(by: { $0.promptLine < $1.promptLine })

        // Find candidate command that intersects or precedes vpTopAbsLine
        let candidateId: UInt64?
        if let precedingMark = marks.last(where: { $0.promptLine <= vpTopAbsLine }) {
            candidateId = precedingMark.commandId
        } else if let firstMark = marks.first {
            // All retained prompt marks start below vpTopAbsLine.
            // If an earlier command's output extends into the retained buffer, its prompt was evicted.
            candidateId = firstMark.commandId > 1 ? firstMark.commandId - 1 : nil
        } else {
            // No prompt marks retained in scrollback (prompt evicted or running command)
            candidateId = activeRunningCommandId ?? findRunningCommandId() ?? core.newestCommandId()
        }

        guard let targetId = candidateId else {
            return nil
        }

        let resolvedCmd: TrackedCommandOutput?
        if let existing = trackedCommands[targetId] {
            if existing.status == 0 {
                // Refresh bounds for running command
                var runningCmd = existing
                runningCmd.lastOutputAbsLine = max(runningCmd.lastOutputAbsLine, currentBottom)
                if runningCmd.startOutputAbsLine <= (existing.promptLine ?? 0) {
                    runningCmd.startOutputAbsLine = computeStartOutputAbsLine(
                        promptLine: existing.promptLine,
                        cmdText: existing.command,
                        firstRetainedLine: firstRetainedLine,
                        totalScrollback: totalScrollback
                    )
                }
                // Check if running command has finished
                if let info = core.firstCommandAfter(after: targetId - 1), info.id == targetId, !info.running {
                    let promptLine = existing.promptLine ?? marks.first(where: { $0.commandId == targetId })?.promptLine
                    let status: UInt8 = (info.exitCode == 0 ? 1 : 2)
                    let out = core.commandOutput(id: targetId, epoch: info.epoch, maxLines: 100_000, maxBytes: 10_000_000)
                    let lines = UInt64(out?.lines ?? 0)
                    let isNoOutput = (lines == 0)
                    let startLine = computeStartOutputAbsLine(
                        promptLine: promptLine,
                        cmdText: existing.command,
                        firstRetainedLine: firstRetainedLine,
                        totalScrollback: totalScrollback
                    )
                    let lastLine: UInt64
                    if isNoOutput {
                        lastLine = promptLine ?? 0
                    } else {
                        lastLine = max(startLine, startLine + (lines > 0 ? lines - 1 : 0))
                    }
                    runningCmd = TrackedCommandOutput(
                        commandId: targetId,
                        command: existing.command,
                        promptLine: promptLine,
                        startOutputAbsLine: startLine,
                        startCursorCol: existing.startCursorCol,
                        lastOutputAbsLine: lastLine,
                        status: status,
                        exitCode: info.exitCode,
                        hasNoOutput: isNoOutput,
                        outputResolved: true
                    )
                    if activeRunningCommandId == targetId {
                        activeRunningCommandId = nil
                    }
                }
                trackedCommands[targetId] = runningCmd
                resolvedCmd = runningCmd
            } else if !existing.outputResolved {
                // Completed command whose output bounds have not been resolved yet
                let promptLine = existing.promptLine ?? marks.first(where: { $0.commandId == targetId })?.promptLine
                let epoch = core.stateEpoch()
                let out = core.commandOutput(id: targetId, epoch: epoch, maxLines: 100_000, maxBytes: 10_000_000)
                let lines = UInt64(out?.lines ?? 0)
                let isNoOutput = (lines == 0)
                let startLine = computeStartOutputAbsLine(
                    promptLine: promptLine,
                    cmdText: existing.command,
                    firstRetainedLine: firstRetainedLine,
                    totalScrollback: totalScrollback
                )
                let lastLine: UInt64
                if isNoOutput {
                    lastLine = promptLine ?? 0
                } else {
                    lastLine = max(startLine, startLine + (lines > 0 ? lines - 1 : 0))
                }
                var tracked = existing
                tracked.promptLine = promptLine
                tracked.startOutputAbsLine = startLine
                tracked.lastOutputAbsLine = lastLine
                tracked.hasNoOutput = isNoOutput
                tracked.outputResolved = true
                trackedCommands[targetId] = tracked
                resolvedCmd = tracked
            } else {
                var tracked = existing
                if tracked.startOutputAbsLine <= (tracked.promptLine ?? 0) {
                    let startLine = computeStartOutputAbsLine(
                        promptLine: tracked.promptLine,
                        cmdText: tracked.command,
                        firstRetainedLine: firstRetainedLine,
                        totalScrollback: totalScrollback
                    )
                    if !tracked.hasNoOutput {
                        let diff = startLine > tracked.startOutputAbsLine ? (startLine - tracked.startOutputAbsLine) : 0
                        tracked.lastOutputAbsLine += diff
                    }
                    tracked.startOutputAbsLine = startLine
                    trackedCommands[targetId] = tracked
                }
                resolvedCmd = tracked
            }
        } else {
            // Not in cache: query only this single candidate command
            if let info = core.firstCommandAfter(after: targetId - 1), info.id == targetId {
                if info.running && activeRunningCommandId == nil {
                    activeRunningCommandId = info.id
                }
                guard let rawInput = info.input?.trimmingCharacters(in: .whitespacesAndNewlines), !rawInput.isEmpty else {
                    return nil
                }
                let mark = marks.first(where: { $0.commandId == info.id })
                let promptLine = mark?.promptLine

                let startLine = computeStartOutputAbsLine(
                    promptLine: promptLine,
                    cmdText: rawInput,
                    firstRetainedLine: firstRetainedLine,
                    totalScrollback: totalScrollback
                )

                let status: UInt8
                let isNoOutput: Bool
                let lastLine: UInt64

                if info.running {
                    status = 0
                    isNoOutput = false
                    lastLine = max(currentBottom, startLine)
                } else {
                    status = (info.finished ? (info.exitCode == 0 ? 1 : 2) : 2)
                    let out = core.commandOutput(id: info.id, epoch: info.epoch, maxLines: 100_000, maxBytes: 10_000_000)
                    let lines = UInt64(out?.lines ?? 0)
                    isNoOutput = (lines == 0)
                    if isNoOutput {
                        lastLine = promptLine ?? 0
                    } else {
                        lastLine = max(startLine, startLine + (lines > 0 ? lines - 1 : 0))
                    }
                }

                let tracked = TrackedCommandOutput(
                    commandId: info.id,
                    command: rawInput,
                    promptLine: promptLine,
                    startOutputAbsLine: startLine,
                    startCursorCol: 0,
                    lastOutputAbsLine: lastLine,
                    status: status,
                    exitCode: info.exitCode,
                    hasNoOutput: isNoOutput,
                    outputResolved: !info.running
                )
                trackedCommands[info.id] = tracked
                resolvedCmd = tracked
            } else {
                resolvedCmd = nil
            }
        }

        guard let cmd = resolvedCmd, !cmd.hasNoOutput, !cmd.command.isEmpty else {
            return nil
        }

        // Check if prompt is visible on screen
        if let pLine = cmd.promptLine, pLine >= firstRetainedLine {
            let pRow = Int(pLine - firstRetainedLine)
            if pRow >= vpTop {
                // Prompt line is visible on screen or below vpTop
                return nil
            }
        }

        // Check if prompt or prompt continuation mark is at the top of the viewport
        let semPrompt = core.retainedSemanticPrompt(row: UInt64(vpTop))
        if semPrompt != 0 {
            return nil
        }

        // Zero-output completed command has no output on screen
        if cmd.status != 0 && cmd.lastOutputAbsLine <= (cmd.promptLine ?? 0) {
            return nil
        }

        // Check if vpTopAbsLine is within this command's output bounds (both lower and upper bounds)
        if vpTopAbsLine < cmd.startOutputAbsLine || vpTopAbsLine > cmd.lastOutputAbsLine {
            return nil
        }

        let promptRetainedRow: UInt64
        if let pLine = cmd.promptLine, pLine >= firstRetainedLine {
            promptRetainedRow = pLine - firstRetainedLine
        } else {
            promptRetainedRow = 0
        }

        return StickyCommandHeader(
            commandId: cmd.commandId,
            command: cmd.command,
            promptRetainedRow: promptRetainedRow,
            status: cmd.status,
            exitCode: cmd.exitCode
        )
    }
}
#endif
