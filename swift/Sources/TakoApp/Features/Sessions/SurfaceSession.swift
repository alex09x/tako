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

/// A terminal's persistent session: which runtime and namespace it uses,
/// the owner lock that keeps every other copy of Tako away from it while
/// this one drives it, and -- while a relaunched terminal is checking
/// whether its session survived -- that check.
@MainActor
final class SurfaceSession {
    let runtime: URL
    let guardedRuntime: URL?
    let namespace: SessionNamespace
    let name: String
    let owner: SessionOwnerLock
    let records: SessionRecordStore
    var record: SessionRecord

    /// This attempt's nonce while a reattach check has not been decided.
    var attempt: String?

    /// The session's shell, as the runtime lists it, once attached.
    var shellPID: pid_t?

    /// Set once quitting is confirmed: from then on clients are detached,
    /// never their sessions ended. Read from any thread (a deinit).
    nonisolated(unsafe) private static var detachingFlag = false
    private static let detachingLock = NSLock()
    nonisolated static var appIsDetaching: Bool {
        get { detachingLock.withLock { detachingFlag } }
        set { detachingLock.withLock { detachingFlag = newValue } }
    }

    init(runtime: URL, guardedRuntime: URL? = nil, namespace: SessionNamespace, name: String, owner: SessionOwnerLock,
         records: SessionRecordStore, record: SessionRecord) {
        self.runtime = runtime
        self.guardedRuntime = guardedRuntime
        self.namespace = namespace
        self.name = name
        self.owner = owner
        self.records = records
        self.record = record
    }

    /// The terminal's process ended. Handled here (true) when that is not
    /// the terminal closing: a reattach check's client ends on its own,
    /// clients end on purpose while Tako quits, and a client that ends on
    /// its own may have left its session running -- that is found out first.
    func clientExited(_ surface: Tako.SurfaceView) -> Bool {
        if attempt != nil || Self.appIsDetaching { return true }
        let runtime = self.guardedRuntime, name = self.name, env = environment
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak surface] in
            let listed = runtime.flatMap { RuntimeCommand.isListed($0, name: name, environment: env) }
            DispatchQueue.main.async {
                guard let self, let surface, surface.persistence === self, surface.pty == nil || !(surface.pty?.alive ?? false)
                else { return }
                switch listed {
                case false:
                    // A missing list entry alone does not prove the shell is gone.
                    // Keep the record and protect its screen in either case.
                    try? self.save(.detached)
                    if let shell = self.shellPID, kill(shell, 0) == -1, errno == ESRCH {
                        self.confirmedLive = false
                        (NSApp?.delegate as? AppDelegate)?.sessionSaver.protect(id: surface.id)
                        self.ended = true
                        surface.onExit?(surface)
                    } else {
                        surface.awaitReconnect("This session is not listed and may still be running. Press Return to check again, or open a new tab.")
                    }
                case true:
                    try? self.save(.detached)
                    surface.awaitReconnect("Disconnected from this terminal's session; it is still running. Press Return to reconnect.")
                case nil:
                    surface.awaitReconnect("Could not tell whether this terminal's session is still running. Press Return to check again.")
                }
            }
        }
        return true
    }

    /// Set once ending the session is taken care of -- it is over, or an
    /// Ending owns it -- so nothing starts a second one.
    var ended = false

    /// A placeholder that never connected must never end a live session when closed.
    var confirmedLive = false

    /// Every session object alive in this process, including those of
    /// closed terminals still held for undo. Weak: it keeps nothing alive.
    private static let live = NSHashTable<SurfaceSession>.weakObjects()

    func register() { Self.live.add(self) }

    /// The surface is gone for good -- closed, and past any undo that could
    /// bring it back -- and Tako is not quitting: its session ends with it.
    deinit {
        guard !Self.appIsDetaching, !ended, confirmedLive else { return }
        Ending(runtime: runtime, guardedRuntime: guardedRuntime, name: name, environment: namespace.environment, records: records,
               id: record.id, generation: record.generation, runtimeID: namespace.runtimeID, owner: owner).start()
    }

    /// Quitting is confirmed: open terminals let go of their sessions --
    /// recorded as detached, clients ended -- while terminals already closed
    /// (held only for undo, never coming back) have theirs ended first,
    /// within a bound. After this no client exit closes a tab and no
    /// session is ended.
    static func detachAll(_ surfaces: [Tako.SurfaceView]) {
        appIsDetaching = true
        let open = Set(surfaces.compactMap { $0.persistence.map(ObjectIdentifier.init) })
        // Terminals closed but still held for undo are not coming back:
        // their sessions end now, like any closed terminal's.
        for session in live.allObjects where !open.contains(ObjectIdentifier(session)) && !session.ended && session.confirmedLive {
            session.ended = true
            Ending(session).start(reportFailure: false)
        }
        // Every ending still under way -- these, and those started earlier
        // when an undo expired -- gets a bounded time to finish without blocking
        // the main runloop or triggering a macOS spinning beach ball. Whatever
        // has not finished is recorded so the next launch asks about it.
        Ending.settleBeforeQuit(within: 0.15)
        for surface in surfaces {
            guard let session = surface.persistence else { continue }
            session.record.quietSince = surface.crab.live == nil ? nil : surface.crab.liveLastOutputAt
            if !session.ended { try? session.save(.detached) }
            let client = surface.pty
            surface.currentProcess = nil
            client?.terminate()
        }
    }

    var environment: [String: String] { namespace.environment }

    /// Keeps when the quiet program last printed. Not while quitting: the
    /// clients end then, and what they leave is recorded on the way out.
    func saveQuietSince(_ date: Date?) {
        guard !Self.appIsDetaching, !ended, record.quietSince != date else { return }
        var next = record
        next.quietSince = date
        guard (try? records.write(next)) != nil else { return }
        record = next
    }

    func rememberPlacement(workspaceID: UUID?, tabIdentifier: String, workingDirectory: String?,
                           windowTabIdentifiers: [String]? = nil) {
        let workspaceID = workspaceID ?? record.workspaceID
        let workingDirectory = workingDirectory ?? record.workingDirectory
        let windowTabIdentifiers = windowTabIdentifiers ?? record.windowTabIdentifiers
        guard !ended, record.workspaceID != workspaceID || record.tabIdentifier != tabIdentifier ||
                record.workingDirectory != workingDirectory || record.windowTabIdentifiers != windowTabIdentifiers else { return }
        var next = record
        next.workspaceID = workspaceID
        next.tabIdentifier = tabIdentifier
        next.workingDirectory = workingDirectory
        next.windowTabIdentifiers = windowTabIdentifiers
        guard (try? records.write(next)) != nil else { return }
        record = next
    }

    func save(_ state: SessionRecord.State) throws {
        var next = record
        next.state = state
        try records.write(next)
        record = next
    }
}

extension SurfaceSession {
    nonisolated static let reattachTimeout: TimeInterval = 5
}
