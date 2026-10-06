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

        /// When the running command started, from its shell-integration
        /// mark, in seconds of system uptime: a monotonic clock, so setting
        /// the time while a command runs does not change how long it ran.

        func commandStarted(at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
            commandStartedAt = time
        }

        /// The program `takoctl run` started in this pane in place of a shell.
        /// The line Tako wrote below the program's output when it ended, as
        /// written -- so an answer leaves out exactly that line and no line
        /// of the program's that happens to look like it.

        /// Whether a command the shell marked (OSC 133) is running now.
        var isCommandRunning: Bool { commandStartedAt != nil }


        /// Whether the user is looking at this terminal right now.
        public var isBeingLookedAt: Bool {
            NSApp.isActive && window?.isKeyWindow == true && isFirstResponderSurface
        }

        /// `notify-on-command-finish`: ring the bell and/or post a system
        /// notification when a long command ends. The tab's crab shows the
        /// outcome either way; this is for when the user is not watching.
        func commandEnded(exitCode: Int32?, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
            let ran = commandStartedAt.map { now - $0 }
            commandStartedAt = nil
            guard let config = owningApp?.config,
                  Tako.commandFinishShouldSignal(
                    mode: config.notifyOnCommandFinish, ran: ran,
                    after: config.notifyOnCommandFinishAfter, focused: isBeingLookedAt),
                  let ran
            else { return }
            let actions = config.notifyOnCommandFinishAction
            if actions.contains(Tako.NotifyOnCommandFinishAction.bell) {
                NSSound.beep()
                crab.bellRang()
            }
            if actions.contains(Tako.NotifyOnCommandFinishAction.notify) {
                let content = Tako.commandFinishContent(exitCode: exitCode, ran: ran, title: title)
                content.userInfo = [
                    Tako.notificationSurfaceKey: id.uuidString,
                    Tako.notificationPaneTitleKey: title,
                    Tako.notificationProjectKey: Tako.projectFromWorkingDirectory(pwd, fallbackTitle: title)
                ]
                let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
                AppDelegate.notificationCenterProvider()?.add(request)
                Tako.onNotificationPosted?(request)
            }
            commandFinishSignals += 1
        }

        /// The active command currently running, as reported by OSC 133 or shell integration.

        /// Test hook for intercepting replies written to PTY.

        func startProcess(workingDir: String?, program: [String]? = nil,
                          environment: [String: String] = [:], removing: [String] = [],
                          sessionPreamble: String? = nil) {
            // The session runtime's client opens with its own preamble (see
            // SessionClientPreamble); with `sessionPreamble` set to the
            // session's name it is taken off the start of the output.
            var preamble = sessionPreamble.map(SessionClientPreamble.init(sessionName:))
            // Where takoctl reaches this app and which pane it runs in. Set
            // last, over anything passed in: a pane is never told it is
            // another one.
            var environment = environment
            environment["TAKO_SURFACE_ID"] = id.uuidString.lowercased()
            // Empty when this copy serves no socket: never one inherited
            // from, or owned by, another copy of Tako.
            environment["TAKO_SOCKET"] = ControlCommands.socketPath
            environment["TAKO_CONTROL_TOKEN"] = ControlGrantStore.shared.primaryToken
            pty = PTY(cols: UInt16(cols), rows: UInt16(rows), workingDirectory: workingDir, config: owningApp?.config,
                      program: program, environment: environment, removing: removing)
            let started = pty
            currentProcess = started
            pty?.readLoop(targetQueue: parserQueue, onData: { [weak self] data in
                guard let self else { return }
                // Output still draining from a process that has been
                // replaced (a reattach check's client) is not this
                // terminal's any more.
                guard self.currentProcess === started else { return }
                var data = data
                if preamble != nil {
                    data = preamble!.consume(data)
                    if preamble!.done { preamble = nil }
                    if data.isEmpty { return }
                }
                TakoLog.feed.debug("pty \(data.count)B")
                if data.count <= 200 {
                    let hex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
                    let printable = String(data.map { ($0 >= 0x20 && $0 < 0x7f) ? Character(UnicodeScalar($0)) : "." })
                    TakoLog.feed.debug("pty hex: \(hex)  [\(printable)]")
                }
                let outcome = self.core.feedWithOutcome(bytes: data)
                // The engine has no clock: a command's start time is when its
                // start reached us, stamped against the engine it belongs to.
                for case .commandStart(let id?) in outcome.events {
                    let now = UInt64(Date().timeIntervalSince1970 * 1000)
                    _ = self.core.setCommandTime(epoch: outcome.epoch, id: id, unixMs: now)
                }
                // After the parse, never before: a save that reads the new
                // count must also find the bytes in the engine.
                self.generationLock.withLock { self.contentGeneration &+= 1 }
                if !outcome.output.isEmpty {
                    TakoLog.feed.debug("reply \(outcome.output.count)B")
                }
                if Tako.MetalTerminalHost.requiresSynchronousMainApplication(
                    output: outcome.output,
                    events: outcome.events
                ) {
                    DispatchQueue.main.sync {
                        // Replies go to the process that asked; effects only
                        // while it is still this terminal's process.
                        if !outcome.output.isEmpty { started?.write(outcome.output) }
                        guard self.currentProcess === started else { return }
                        for event in outcome.events {
                            switch event {
                            case .bell:
                                NSSound.beep()
                                self.crab.bellRang()
                            case .pwdChanged(let url):
                                self.pwd = URL(string: url)?.path ?? url
                                // A shell that never sets a title still gets one,
                                // the way upstream titles a window by its directory.
                                if let pwd = self.pwd {
                                    self.title = Tako.titleForDirectory(pwd)
                                }
                                self.publishEvent(type: "cwd", payload: ["cwd": .string(self.pwd ?? url)])
                            case .titleChanged(let title):
                                self.title = title
                                self.onTitleChange?(self)
                                self.publishEvent(type: "title", payload: ["title": .string(title)])
                            case .clipboardSet(let text):
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(text, forType: .string)
                            case .notification(let title, let body):
                                self.postStructuredNotification(
                                    id: nil,
                                    title: title,
                                    body: body,
                                    appName: nil,
                                    urgency: 1,
                                    actions: [],
                                    reportActivation: false,
                                    focus: true,
                                    reportClose: false,
                                    timeoutMs: nil,
                                    onlyWhenUnfocused: false
                                )
                            case let .structuredNotification(
                                id, title, body, appName, urgency, actions,
                                reportActivation, focus, reportClose, timeoutMs, onlyWhenUnfocused
                            ):
                                self.postStructuredNotification(
                                    id: id,
                                    title: title,
                                    body: body,
                                    appName: appName,
                                    urgency: urgency,
                                    actions: actions,
                                    reportActivation: reportActivation,
                                    focus: focus,
                                    reportClose: reportClose,
                                    timeoutMs: timeoutMs,
                                    onlyWhenUnfocused: onlyWhenUnfocused
                                )
                            case let .notificationClose(id, reportClose):
                                self.closeStructuredNotification(id: id, reportClose: reportClose)
                            case .progress(let state, let value):
                                self.crab.progressReported(state: state, value: value)
                                self.progressReport = state == 0 ? nil : .init(
                                    state: state == 2 ? .error : (state == 3 ? .indeterminate : (state == 4 ? .pause : .set)),
                                    progress: value)
                                self.updateProgressBar(state: self.crab.progressState, progress: self.crab.progress)
                                (NSApp.delegate as? AppDelegate)?.setDockBadge()
                                Tako.TabBarController.refreshAll()
                                self.publishEvent(
                                    type: "progress",
                                    payload: [
                                        "state": .string(self.crab.progressState.rawValue),
                                        "progress": value.map { JSON.number(Double($0)) } ?? .null
                                    ]
                                )
                            case .commandStart:
                                self.crab.isFocused = self.isBeingLookedAt
                                self.crab.commandStarted()
                                self.commandStarted()
                                var cmdText = ""
                                var cmdRef = ""
                                if let id = self.core.newestCommandId(),
                                   let info = self.core.firstCommandAfter(after: id > 0 ? id - 1 : 0) {
                                    self.activeRunningCommandText = info.input
                                    cmdText = info.input ?? ""
                                    cmdRef = "\(info.id)@\(info.epoch)"
                                }
                                self.publishEvent(
                                    type: "command_start",
                                    payload: [
                                        "command": .string(cmdRef),
                                        "ref": .string(cmdRef),
                                        "line": .string(cmdText)
                                    ]
                                )
                            case .commandEnd(let exitCode):
                                var cmdRef = ""
                                if let id = self.core.newestCommandId(),
                                   let info = self.core.firstCommandAfter(after: id > 0 ? id - 1 : 0) {
                                    cmdRef = "\(info.id)@\(info.epoch)"
                                }
                                self.activeRunningCommandText = nil
                                self.crab.isFocused = self.isBeingLookedAt
                                self.crab.commandEnded(exitCode: exitCode)
                                self.progressReport = nil
                                self.updateProgressBar(state: .none, progress: nil)
                                (NSApp.delegate as? AppDelegate)?.setDockBadge()
                                Tako.TabBarController.refreshAll()
                                self.commandEnded(exitCode: exitCode)
                                var payload: [String: JSON] = [
                                    "command": .string(cmdRef),
                                    "ref": .string(cmdRef),
                                ]
                                if let exitCode {
                                    payload["exit_status"] = .number(Double(exitCode))
                                } else {
                                    payload["exit_status"] = .null
                                }
                                self.publishEvent(type: "command_end", payload: payload)
                            case .promptMark:
                                self.crab.promptMark()
                            case .statusSet(let status, let text):
                                self.crab.setStatus(status, text: text)
                                self.publishEvent(
                                    type: "status",
                                    payload: [
                                        "status": .string(self.crab.paneStatus.rawValue),
                                        "status_text": text.map(JSON.string) ?? .null,
                                        "unread": .bool(self.crab.unread)
                                    ]
                                )
                            case .statusClear:
                                self.crab.clearStatus()
                                self.publishEvent(
                                    type: "status",
                                    payload: [
                                        "status": .string(self.crab.paneStatus.rawValue),
                                        "status_text": .null,
                                        "unread": .bool(self.crab.unread)
                                    ]
                                )
                            case .clipboardQuery:
                                guard self.owningApp?.config.clipboardRead ?? false else { break }
                                let text = NSPasteboard.general.string(forType: .string) ?? ""
                                let replyOutcome = self.core.feedWithOutcome(bytes: Data("\u{1b}]52;c;\(Data(text.utf8).base64EncodedString())\u{07}".utf8))
                                if !replyOutcome.output.isEmpty { self.pty?.write(replyOutcome.output) }
                            case .contextPush, .contextPop, .contextClear:
                                self.updateContextState()
                                self.publishEvent(type: "context", payload: self.currentContextPayload())
                            }
                        }
                    }
                }
                // The watchdog is main-thread state, so its decision is made
                // there. The redraw request stays on the parser queue, where
                // it coalesces a burst instead of hopping to Main per batch.
                let syncActive = outcome.synchronizedOutputActive
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.applyWatchdogAction(
                        Tako.MetalTerminalHost.watchdogAction(
                            isSynchronizedOutputActive: syncActive,
                            watchdogArmed: self.syncOutputTimeoutItem != nil
                        )
                    )
                }
                if !syncActive && outcome.hasDamage {
                    self.requestPtyRedraw()
                }
            }, onExit: { [weak self] in
                DispatchQueue.main.sync {
                    guard let self else { return }
                    let exitCode = self.pty?.exitStatus
                    var payload: [String: JSON] = [:]
                    if let exitCode {
                        payload["exit_status"] = .number(Double(exitCode))
                    } else {
                        payload["exit_status"] = .null
                    }
                    self.publishEvent(type: "process_exit", payload: payload)
                    self.childDidExit(started)
                }
            })
        }

        private func currentContextPayload() -> [String: JSON] {
            let frames: [JSON] = core.contextStack().map { frame in
                .object([
                    "kind": .string(frame.kind),
                    "name": .string(frame.name),
                    "is_elevated": .bool(frame.isElevated),
                    "tint": frame.tint.map(JSON.string) ?? .null,
                ])
            }
            return [
                "stack": .array(frames),
                "is_elevated": .bool(core.isElevated()),
                "active_tint": core.activeTint().map(JSON.string) ?? .null,
            ]
        }

        /// Paints a saved screen, then the line that says where it ends.

        func afterPendingOutput(_ work: @escaping () -> Void) {
            parserQueue.async(execute: work)
        }

        /// Encoded with the surface: whether its shell lived in a persistent
        /// session, so a restored terminal with no record of one is known to
        /// have lost it rather than never had it.
        /// What Return does while the terminal waits on its session.

        /// Set as soon as the terminal's shell is meant to live in a session
        /// -- and kept when reaching it fails, so the saved window still says so.

        public func close() {
            BroadcastInputStore.shared.paneClosed(id)
            InputOwnershipStore.shared.remove(paneId: id)
            SecureInput.shared.removeScoped(ObjectIdentifier(self))
            pty?.terminate()
        }

}
