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
import Testing
@testable import Tako

@Suite(.serialized)
@MainActor
struct ProgramStatusSurfaceTests {
    private func b64(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }

    private func makeIsolatedSurface() -> Tako.SurfaceView {
        TakoTerminalNSView.isMetalDisabledForTesting = true
        var config = Tako.SurfaceConfiguration()
        config.allowsSessionPersistence = false
        config.program = ["/usr/bin/true"]
        let surface = Tako.SurfaceView(nil, baseConfig: config, uuid: UUID(), theme: nil)
        surface.onExit = nil
        surface.pty?.terminate()
        surface.pty = nil
        surface.resetTerminal()
        return surface
    }

    @Test
    func hierarchyPriorityNearestAncestorAppAndChildDoneNeverOverridesActiveWorking() {
        let surface = makeIsolatedSurface()
        surface.crab.isFocused = true

        // Parent task is working at 40% under claude-code.
        surface.feed(
            data: Data("\u{1b}]7501;state=working:id=main:app=claude-code:progress=40:msg=\(b64("Refactoring crate"))\u{1b}\\".utf8)
        )
        #expect(surface.crab.paneStatus == .working)
        #expect(surface.crab.statusText == "Refactoring crate")
        #expect(surface.progressReport == .init(state: .set, progress: 40))

        // Child subagent blocks on permission without repeating app=; inherits nearest ancestor app.
        surface.feed(
            data: Data("\u{1b}]7501;state=blocked:id=main/sub-1:kind=permission:msg=\(b64("Allow git push?"))\u{1b}\\".utf8)
        )
        #expect(surface.crab.paneStatus == .needsApproval)
        #expect(surface.crab.statusText == "Allow git push?")
        #expect(surface.programStatusSnapshot().effective?.resolvedApp == "claude-code")
        #expect(surface.progressReport == .init(state: .pause, progress: 100))

        // Child finishes (`done`), while parent `main` is still `working`: effective status MUST remain `.working`!
        surface.feed(
            data: Data("\u{1b}]7501;state=done:id=main/sub-1:msg=\(b64("Subtask done"))\u{1b}\\".utf8)
        )
        #expect(surface.crab.paneStatus == .working)
        #expect(surface.crab.statusText == "Refactoring crate")
        #expect(surface.progressReport == .init(state: .set, progress: 40))
    }

    @Test
    func blockedAuthFallbackAndOsc94CoexistenceWithHardReset() {
        let surface = makeIsolatedSurface()
        surface.crab.isFocused = true

        // blocked + kind=auth with no title/msg synthesizes "Authentication required".
        surface.feed(data: Data("\u{1b}]7501;state=blocked:kind=auth:app=Qwen\u{1b}\\".utf8))
        #expect(surface.crab.paneStatus == .waitingForInput)
        #expect(surface.crab.statusText == "Authentication required")
        #expect(surface.programStatusSnapshot().osc7501Active == true)

        // Generic OSC 9;4 progress must not overwrite OSC 7501 progress/status while osc7501Active is true.
        surface.feed(data: Data("\u{1b}]9;4;1;25\u{07}".utf8))
        #expect(surface.crab.paneStatus == .waitingForInput)
        #expect(surface.progressReport == .init(state: .pause, progress: 100))

        // Hard reset (RIS, ESC c) clears ProgramStatusTable and osc7501Active, allowing OSC 9;4 again.
        surface.feed(data: Data("\u{1b}c".utf8))
        #expect(surface.programStatusSnapshot().osc7501Active == false)
        #expect(surface.crab.osc7501StatusActive == false)
        #expect(surface.crab.paneStatus == .idle)
        #expect(surface.progressReport == nil)

        // Even when records were already emptied via state=clear, RIS must still clear host osc7501Active
        // so subsequent OSC 9;4 progress is no longer suppressed.
        surface.feed(data: Data("\u{1b}]7501;state=working:app=Codex\u{1b}\\".utf8))
        surface.feed(data: Data("\u{1b}]7501;state=clear\u{1b}\\".utf8))
        #expect(surface.crab.osc7501StatusActive == true)
        surface.feed(data: Data("\u{1b}]9;4;1;40\u{07}".utf8))
        #expect(surface.activeProgressState == .none)

        surface.feed(data: Data("\u{1b}c".utf8))
        #expect(surface.programStatusSnapshot().osc7501Active == false)
        #expect(surface.crab.osc7501StatusActive == false)
        surface.feed(data: Data("\u{1b}]9;4;1;60\u{07}".utf8))
        #expect(surface.activeProgressState == .normal)
        #expect(surface.activeProgressValue == 60)
    }

    @Test
    func quietTuiAgentCommandEndedPreservesUnreadDoneFromOsc7501() {
        var now = Date(timeIntervalSince1970: 10_000)
        let tracker = Tako.CrabTracker(clock: { now })
        tracker.isFocused = false

        // Simulate interactive/TUI agent command that runs as `.quiet` (like Claude Code / Codex TUI).
        tracker.commandStarted(kind: .quiet, probe: .init(
            takeOutputLines: { 0 },
            isAlternateScreen: { true },
            program: "claude",
            detail: nil
        ))
        now = now.addingTimeInterval(5)
        #expect(tracker.signalStatus == .idle)

        // Agent emits OSC 7501 `blocked` (keeping startedAt non-nil) and `done` while unfocused, then exits cleanly with exitCode 0.
        let blockedRecord = TerminalProgramStatusRecord(
            id: "default",
            state: .blocked,
            kind: .permission,
            app: "Claude Code",
            resolvedApp: "Claude Code",
            msg: "Allow tool?",
            revision: 1
        )
        tracker.applyProgramStatusSnapshot(
            TerminalProgramStatusSnapshot(revision: 1, osc7501Active: true, effective: blockedRecord, records: [blockedRecord])
        )
        #expect(tracker.paneStatus == .needsApproval)
        #expect(tracker.unread == true)
        tracker.commandEnded(exitCode: 0)
        #expect(tracker.paneStatus == .needsApproval)
        #expect(tracker.unread == true)

        tracker.commandStarted(kind: .quiet)
        let doneRecord = TerminalProgramStatusRecord(
            id: "default",
            state: .done,
            app: "Claude Code",
            resolvedApp: "Claude Code",
            title: "Finished",
            msg: "Updated 4 files",
            revision: 2
        )
        tracker.applyProgramStatusSnapshot(
            TerminalProgramStatusSnapshot(revision: 2, osc7501Active: true, effective: doneRecord, records: [doneRecord])
        )
        #expect(tracker.paneStatus == .done)
        #expect(tracker.unread == true)

        tracker.commandEnded(exitCode: 0)
        #expect(tracker.paneStatus == .done)
        #expect(tracker.unread == true, "Quiet TUI command exit must not wipe OSC 7501 unread outcome")
    }

    @Test
    func userInterruptAndFocusOrFadeAcknowledgmentUpdateEngineTable() {
        let surface = makeIsolatedSurface()
        surface.crab.isFocused = false

        // Interrupt drops working/blocked records.
        surface.feed(data: Data("\u{1b}]7501;state=working:app=Muse:msg=\(b64("Thinking"))\u{1b}\\".utf8))
        #expect(surface.crab.paneStatus == .working)
        surface.notifyProgramStatusInterrupted()
        surface.crab.userInterrupted()
        #expect(surface.programStatusSnapshot().effective == nil)
        #expect(surface.crab.paneStatus == .idle)

        // Unfocused error sets unread and acknowledges on focus.
        surface.feed(data: Data("\u{1b}]7501;state=error:app=Muse:msg=\(b64("Build failed"))\u{1b}\\".utf8))
        #expect(surface.crab.paneStatus == .error)
        #expect(surface.crab.unread == true)

        surface.crab.focused()
        #expect(surface.programStatusSnapshot().effective == nil)
        #expect(surface.crab.paneStatus == .idle)
        #expect(surface.crab.unread == false)

        // Focused done acknowledges when seen outcome fades.
        surface.feed(data: Data("\u{1b}]7501;state=done:app=Muse:msg=\(b64("Shipped"))\u{1b}\\".utf8))
        #expect(surface.crab.paneStatus == .done)
        surface.crab.fadeSeenOutcome()
        #expect(surface.programStatusSnapshot().effective == nil)
        #expect(surface.crab.paneStatus == .idle)
    }

    @Test
    func unfocusedNotificationsDeduplicateProgressTicksAndSuppressCheckpointRestore() throws {
        NotificationStore.shared.clear()
        NotificationCoalescer.shared.reset()
        defer {
            NotificationStore.shared.clear()
            NotificationCoalescer.shared.reset()
        }

        let surface = makeIsolatedSurface()
        surface.crab.isFocused = false

        // Live transition into blocked posts one notification; progress ticks with identical state/kind/title/msg do not duplicate.
        let msg = b64("Approve deployment?")
        surface.feed(
            data: Data("\u{1b}]7501;state=blocked:id=deploy:kind=permission:app=Codex:progress=20:msg=\(msg)\u{1b}\\".utf8)
        )
        surface.feed(
            data: Data("\u{1b}]7501;state=blocked:id=deploy:kind=permission:app=Codex:progress=60:msg=\(msg)\u{1b}\\".utf8)
        )
        let recordsForSurface = NotificationStore.shared.records.filter { $0.surfaceId == surface.id }
        #expect(recordsForSurface.count == 1)
        #expect(recordsForSurface.first?.title == "Codex needs permission")
        #expect(recordsForSurface.first?.body == "Approve deployment?")

        // Restoring a checkpoint with `done` must populate status without firing a new notification.
        let checkpoint = try surface.core.checkpointExport(flags: 0, maxBytes: 4 * 1024 * 1024)
        let restoredSurface = makeIsolatedSurface()
        restoredSurface.crab.isFocused = false
        NotificationStore.shared.clear()
        NotificationCoalescer.shared.reset()

        restoredSurface.showSnapshot(SessionSnapshot(savedAt: Date(), checkpoint: checkpoint))
        #expect(restoredSurface.crab.paneStatus == .needsApproval)
        #expect(NotificationStore.shared.records.filter { $0.surfaceId == restoredSurface.id }.isEmpty)
    }

    @Test func nativeProgramStatusNotificationsWithdrawOnlyScopedOsc7501IdsOnFocusAckAndResolve() {
        let surface = makeIsolatedSurface()
        surface.crab.isFocused = false
        NotificationStore.shared.clear()
        NotificationCoalescer.shared.reset()

        let origPosted = Tako.onNotificationPosted
        let origRemoved = Tako.onNotificationRemoved
        defer {
            Tako.onNotificationPosted = origPosted
            Tako.onNotificationRemoved = origRemoved
        }

        var postedIds: [String] = []
        var removedBatches: [[String]] = []
        Tako.onNotificationPosted = { postedIds.append($0.identifier) }
        Tako.onNotificationRemoved = { removedBatches.append($0) }

        // Post an unrelated OSC 99 / structured notification alongside an unfocused OSC 7501 blocked report.
        surface.postStructuredNotification(
            id: "foreign-1",
            title: "Build",
            body: "Foreign notification",
            appName: "Runner",
            urgency: 1,
            actions: [],
            reportActivation: false,
            focus: true,
            reportClose: false,
            timeoutMs: nil,
            onlyWhenUnfocused: false
        )
        surface.feed(
            data: Data("\u{1b}]7501;state=blocked:id=gate:kind=permission:app=Claude:msg=\(b64("Approve edit?"))\u{1b}\\".utf8)
        )

        let foreignReqId = "tako-notif-\(surface.id.uuidString)-foreign-1"
        let nativeReqId = "tako-notif-\(surface.id.uuidString)-osc7501-\(surface.id.uuidString)-gate"
        #expect(postedIds.contains(foreignReqId))
        #expect(postedIds.contains(nativeReqId))

        // Focusing the pane withdraws the native osc7501 banner, preserves foreign-1, AND keeps blocked state intact!
        surface.didGainSurfaceFocus(flushTitle: false)
        let flatAfterFocus = removedBatches.flatMap { $0 }
        #expect(flatAfterFocus.contains(nativeReqId))
        #expect(!flatAfterFocus.contains(foreignReqId))
        #expect(surface.programStatusSnapshot().effective?.state == .blocked)

        // Unfocus again, post a new done outcome, then resolve/clear it -> withdraws its banner too.
        removedBatches.removeAll()
        surface.crab.isFocused = false
        surface.feed(data: Data("\u{1b}]7501;state=done:id=gate:app=Claude:msg=\(b64("Finished"))\u{1b}\\".utf8))
        surface.feed(data: Data("\u{1b}]7501;state=working:id=gate:app=Claude:msg=\(b64("Next turn"))\u{1b}\\".utf8))
        let flatAfterResolve = removedBatches.flatMap { $0 }
        #expect(flatAfterResolve.contains(nativeReqId))
        #expect(!flatAfterResolve.contains(foreignReqId))
    }

    @Test func persistentSessionClientExitPreservesLiveOsc7501WhileConfirmedProcessExitClearsWorkingAndBlocked() throws {
        let root = URL(fileURLWithPath: "/tmp/tkx-ps75-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let runtimeID = "0.8.1-cc9574e03dfb2480"
        let namespace = try SessionNamespace.open(runtimeID: runtimeID, home: root)
        let records = SessionRecordStore(directory: root.appendingPathComponent("records"))
        let runtime = root.appendingPathComponent("zmx")
        try Data("#!/bin/sh\nprintf 'session_name=abc\\tpid=12345\\n'\n".utf8).write(to: runtime)
        chmod(runtime.path, 0o755)

        TakoTerminalNSView.isMetalDisabledForTesting = true
        var config = Tako.SurfaceConfiguration()
        config.allowsSessionPersistence = false
        config.program = ["/usr/bin/true"]
        let surface = Tako.SurfaceView(nil, baseConfig: config, uuid: UUID(), theme: nil)
        surface.onExit = nil
        let attachedPty = surface.pty
        attachedPty?.terminate()
        surface.resetTerminal()

        let record = SessionRecord(id: surface.id, runtimeID: runtimeID, generation: "g", state: .attached, createdAt: Date())
        try records.write(record)
        let session = SurfaceSession(
            runtime: runtime,
            guardedRuntime: runtime,
            namespace: namespace,
            name: "abc",
            owner: try SessionOwnerLock(namespace: namespace, name: "abc"),
            records: records,
            record: record
        )
        surface.persistence = session

        let previousDetaching = SurfaceSession.appIsDetaching
        SurfaceSession.appIsDetaching = true
        defer {
            SurfaceSession.appIsDetaching = previousDetaching
            session.ended = true
            surface.pty = nil
        }

        surface.feed(data: Data("\u{1b}]7501;state=working:id=main:app=Codex:msg=\(b64("Still alive in zmx"))\u{1b}\\".utf8))
        surface.feed(data: Data("\u{1b}]7501;state=blocked:id=gate:kind=permission:app=Codex:msg=\(b64("Approve"))\u{1b}\\".utf8))
        #expect(surface.programStatusSnapshot().records.count == 2)

        surface.childDidExit(attachedPty)

        // Persistent session is still alive during attach-client exit: live working + blocked records MUST survive!
        #expect(surface.programStatusSnapshot().records.count == 2)
        #expect(surface.programStatusSnapshot().effective?.state == .blocked)

        // Non-persistent surface exit (persistence == nil) clears working + blocked while retaining done.
        SurfaceSession.appIsDetaching = false
        let plainSurface = Tako.SurfaceView(nil, baseConfig: config, uuid: UUID(), theme: nil)
        plainSurface.onExit = nil
        let plainPty = plainSurface.pty
        plainPty?.terminate()
        plainSurface.resetTerminal()
        defer { plainSurface.pty = nil }

        plainSurface.feed(data: Data("\u{1b}]7501;state=working:id=w1:app=Codex\u{1b}\\".utf8))
        plainSurface.feed(data: Data("\u{1b}]7501;state=blocked:id=b1:kind=question:app=Codex\u{1b}\\".utf8))
        plainSurface.feed(data: Data("\u{1b}]7501;state=done:id=d1:app=Codex:msg=\(b64("Done"))\u{1b}\\".utf8))
        plainSurface.childDidExit(plainPty)
        #expect(plainSurface.programStatusSnapshot().records.map(\.id) == ["d1"])
    }
}
