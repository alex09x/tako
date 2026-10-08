/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Foundation

extension Tako.SurfaceView {
        // MARK: - TakoTerminalNSViewDelegate

        /// Finds an active SurfaceView by its UUID.
        static func find(for uuid: UUID) -> Tako.SurfaceView? {
            if let appDelegate = NSApp?.delegate as? TakoAppDelegate,
               let found = appDelegate.findSurface(forUUID: uuid) {
                return found
            }
            for c in TerminalController.all {
                for view in c.surfaceTree where view.id == uuid {
                    return view
                }
            }
            return nil
        }

        /// Whether interactive keyboard input is locked for this pane (C7).
        public var isInputLocked: Bool {
            get { InputOwnershipStore.shared.isLocked(for: id) }
            set {
                if newValue {
                    InputOwnershipStore.shared.lock(paneId: id)
                } else {
                    InputOwnershipStore.shared.unlock(paneId: id)
                }
            }
        }

        /// Bytes the surface produced from a keystroke, a paste, or a mouse
        /// report. This is the only path from input to the shell.
        public func terminalView(_ view: TakoTerminalNSView, sendInputData data: Data) {
            guard !isInputLocked else { return }
            writeToShell([UInt8](data))

            // Track C8: Broadcast input to other selected panes if active
            BroadcastInputStore.shared.broadcastInput(
                from: self,
                sourceId: id,
                data: data
            ) { targetId in
                guard let target = Tako.SurfaceView.find(for: targetId) else { return nil }
                return (target: target, isLocked: target.isInputLocked, write: { target.writeToShell($0) })
            }
        }

        /// The engine's own replies -- device attributes, cursor position,
        /// XTVERSION -- which the program asked for and is waiting on.
        public func terminalView(_ view: TakoTerminalNSView, sendDeviceReplyData data: Data) {
            writeToShell([UInt8](data))
        }

        /// The grid changed shape, so the process on the other end has to be
        /// told or it keeps formatting for the old size.
        public func terminalView(_ view: TakoTerminalNSView, didResizeCols cols: Int, rows: Int) {
            pty?.resize(cols: UInt16(max(cols, 1)), rows: UInt16(max(rows, 1)))
            scheduleSearchHitRefresh()
        }

        /// Reflow the terminal grid to match target size and notify the PTY.
        public func reflow(to targetSize: CGSize, forcePtyResize: Bool = false) {
            guard targetSize.width > 0, targetSize.height > 0 else { return }
            if let superview = superview, superview.bounds.size != targetSize {
                superview.setFrameSize(targetSize)
            }
            if bounds.size != targetSize {
                setFrameSize(targetSize)
            }
            let fitted = TerminalGridLayout(
                viewSize: targetSize,
                cellSize: CGSize(width: cellWidth, height: cellHeight),
                theme: theme
            )
            guard fitted.cols > 0, fitted.rows > 0 else { return }
            if forcePtyResize {
                pty?.resize(cols: UInt16(max(fitted.cols, 1)), rows: UInt16(max(fitted.rows, 1)))
            }
            if fitted.cols != cols || fitted.rows != rows {
                scheduleGridResize(cols: fitted.cols, rows: fitted.rows)
            }
        }

        /// Reflow the terminal grid to match current view or containing window bounds and notify the PTY.
        public func reflowToCurrentBounds(forcePtyResize: Bool = false) {
            if let controller = window?.windowController as? TerminalController {
                controller.reflowSurfaces(forcePtyResize: forcePtyResize)
                return
            }
            let targetSize: CGSize
            if let superviewSize = superview?.bounds.size, superviewSize.width > 0, superviewSize.height > 0 {
                targetSize = superviewSize
            } else if bounds.size.width > 0 && bounds.size.height > 0 {
                targetSize = bounds.size
            } else {
                targetSize = window?.contentView?.bounds.size ?? .zero
            }
            reflow(to: targetSize, forcePtyResize: forcePtyResize)
        }

        /// Checkpoint restored into the engine: ensure terminal reflows to current bounds and updates PTY.
        public func terminalView(_ view: TakoTerminalNSView, didRestoreCheckpoint restore: TerminalCheckpointRestore) {
            reflowToCurrentBounds(forcePtyResize: true)
            scheduleSearchHitRefresh()
        }

        /// Screen content changed or checkpoint restored: refresh search hit marks if active (debounced).
        public func terminalViewDidChangeContent(_ view: TakoTerminalNSView) {
            scheduleSearchHitRefresh()
        }

        /// A command action requested sending text to another pane.
        public func terminalView(_ view: TakoTerminalNSView, sendTextToAnotherPane text: String) {
            sendOutputToAnotherPane(text: text)
        }

        public func terminalViewPromptMark(_ view: TakoTerminalNSView) {
            crab.promptMark()
        }

        public func terminalViewCommandDidStart(_ view: TakoTerminalNSView) {
            let lastCmd = core.lastCommand(maxLines: 0, maxBytes: 0)?.command
            var payload: [String: JSON] = [:]
            if let cmdText = lastCmd?.input {
                payload["command"] = .string(cmdText)
            }
            if let cwd = lastCmd?.cwd ?? workingDirectory {
                payload["cwd"] = .string(cwd)
            }
            if let started = lastCmd?.startedAtMs {
                payload["started_at"] = .number(Double(started) / 1000.0)
            }
            publishEvent(type: "command_start", payload: payload)
        }

        public func terminalView(_ view: TakoTerminalNSView, commandDidEnd exitCode: Int32?) {
            let lastCmd = core.lastCommand(maxLines: 0, maxBytes: 0)?.command
            let cmdId = lastCmd?.id ?? 0
            let dur = view.commandDuration(id: cmdId, epoch: lastCmd?.epoch)
            let started = view.commandStartedAt(id: cmdId)

            var payload: [String: JSON] = [:]
            if let exitCode {
                payload["exit_code"] = .number(Double(exitCode))
            } else {
                payload["exit_code"] = .null
            }
            if let dur {
                payload["duration"] = .number(dur)
                payload["duration_ms"] = .number((dur * 1000.0).rounded())
            }
            if let started {
                payload["started_at"] = .number(started.timeIntervalSince1970)
            }
            let isSecure = self.isSecureInput || SecureInput.shared.isSecure(for: self)
            let rawCmdText = lastCmd?.input ?? ""
            let cmdText = isSecure ? "" : rawCmdText
            payload["command"] = .string(cmdText)
            if let cwd = lastCmd?.cwd ?? workingDirectory {
                payload["cwd"] = .string(cwd)
            }
            publishEvent(type: "command_end", payload: payload)

            // E9: Record finished command into history across sessions, obeying secure-input privacy (G5)
            if !isSecure {
                CommandHistoryStore.shared.record(
                    command: rawCmdText,
                    cwd: lastCmd?.cwd ?? workingDirectory,
                    startedAt: started ?? Date(),
                    duration: dur,
                    exitCode: exitCode,
                    paneId: self.id,
                    isSecure: false
                )
            }
        }

        func publishEvent(type: String, payload: [String: JSON] = [:]) {
            let (windowID, tabID, workspaceID) = ControlCommands.surfaceContext(self)
            TerminalEventHub.shared.publish(
                type: type,
                pane: id.uuidString.lowercased(),
                tab: tabID,
                window: windowID,
                workspace: workspaceID,
                payload: payload
            )
        }

        public func terminalView(_ view: TakoTerminalNSView, didReportStatus status: String, text: String?) {
            crab.setStatus(status, text: text)
            publishEvent(
                type: "status",
                payload: [
                    "status": .string(crab.paneStatus.rawValue),
                    "status_text": text.map(JSON.string) ?? .null,
                    "unread": .bool(crab.unread)
                ]
            )
        }

        public func terminalViewDidClearStatus(_ view: TakoTerminalNSView) {
            crab.clearStatus()
            publishEvent(
                type: "status",
                payload: [
                    "status": .string(crab.paneStatus.rawValue),
                    "status_text": .null,
                    "unread": .bool(crab.unread)
                ]
            )
        }

        public func setStatus(_ status: String, text: String? = nil, ttl: TimeInterval? = nil) {
            crab.setStatus(status, text: text, ttl: ttl)
            publishEvent(
                type: "status",
                payload: [
                    "status": .string(crab.paneStatus.rawValue),
                    "status_text": text.map(JSON.string) ?? .null,
                    "unread": .bool(crab.unread)
                ]
            )
        }

        public func clearStatus() {
            crab.clearStatus()
            publishEvent(
                type: "status",
                payload: [
                    "status": .string(crab.paneStatus.rawValue),
                    "status_text": .null,
                    "unread": .bool(crab.unread)
                ]
            )
        }

        func sendOutputToAnotherPane(text: String) {
            if let controller = TerminalController.all.first(where: { $0.surfaceTree.contains(self) }) {
                if let target = controller.surfaceTree.first(where: { $0 !== self && $0.isAtShellPrompt }) {
                    controller.focusSurface(target)
                    controller.focusedSurface = target
                    target.window?.makeFirstResponder(target)
                    target.insertInputText(text)
                    return
                }
                if let newSurface = controller.newSplit(at: self, direction: .right) {
                    controller.focusSurface(newSurface)
                    controller.focusedSurface = newSurface
                    newSurface.window?.makeFirstResponder(newSurface)
                    newSurface.insertInputText(text)
                    return
                }
            }
            for controller in TerminalController.all {
                if let target = controller.surfaceTree.first(where: { $0 !== self && $0.isAtShellPrompt }) {
                    controller.focusSurface(target)
                    controller.focusedSurface = target
                    target.window?.makeFirstResponder(target)
                    target.insertInputText(text)
                    return
                }
            }
        }

        public func insertInputText(_ text: String, isBroadcastRecipient: Bool) {
            guard !isInputLocked else { return }
            revealLiveScreenForUserInput()
            var cleanText = text
            while cleanText.hasSuffix("\n") || cleanText.hasSuffix("\r") {
                cleanText.removeLast()
            }
            guard !cleanText.isEmpty else { return }

            let isMultiLine = cleanText.contains("\n") || cleanText.contains("\r") || core.pasteIsUnsafe(text: cleanText)
            let isUnbracketed = !core.modes().bracketedPaste
            if isMultiLine && (safePaste || isUnbracketed) {
                NotificationCenter.default.post(
                    name: Tako.Notification.confirmClipboard,
                    object: self,
                    userInfo: [
                        Tako.Notification.ConfirmClipboardStrKey: cleanText,
                        Tako.Notification.ConfirmClipboardRequestKey: Tako.ClipboardRequest.paste,
                    ]
                )
                return
            }
            handlePaste(cleanText)

            if !isBroadcastRecipient {
                // Track C8: Broadcast text to other selected panes if active
                BroadcastInputStore.shared.broadcastText(
                    from: self,
                    sourceId: id,
                    text: cleanText
                ) { targetId in
                    guard let target = Tako.SurfaceView.find(for: targetId) else { return nil }
                    return (target: target, isLocked: target.isInputLocked, insertText: { target.insertInputText($0, isBroadcastRecipient: true) })
                }
            }
        }

        /// Cancels any scheduled debounced search hit refresh and resets the burst timer.
}
