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

/// Ending a closed terminal's session. It holds the owner lock until it is
/// settled -- so no other copy of Tako can take the session over in between
/// -- ends only the session it made (the record still names its generation),
/// and removes the record only once the session is confirmed gone. Until
/// then it stays registered: quitting waits for it, a failure is shown with
/// a way to try again, and one left unsettled at quit is asked about on the
/// next launch.
final class Ending: @unchecked Sendable {
    static let closedButRunning = "closed, but its session could not be ended"

    let runtime: URL
    let guardedRuntime: URL?
    let name: String
    let environment: [String: String]
    let records: SessionRecordStore
    let id: UUID
    let generation: String
    let runtimeID: String
    let owner: SessionOwnerLock

    private static let lock = NSLock()
    nonisolated(unsafe) private static var pending: [ObjectIdentifier: Ending] = [:]
    let attemptFinished = DispatchSemaphore(value: 0)

    init(runtime: URL, guardedRuntime: URL? = nil, name: String, environment: [String: String], records: SessionRecordStore,
         id: UUID, generation: String, runtimeID: String, owner: SessionOwnerLock) {
        self.runtime = runtime
        self.guardedRuntime = guardedRuntime
        self.name = name
        self.environment = environment
        self.records = records
        self.id = id
        self.generation = generation
        self.runtimeID = runtimeID
        self.owner = owner
    }

    @MainActor convenience init(_ session: SurfaceSession) {
        self.init(runtime: session.runtime, guardedRuntime: session.guardedRuntime, name: session.name, environment: session.namespace.environment,
                  records: session.records, id: session.record.id, generation: session.record.generation,
                  runtimeID: session.namespace.runtimeID,
                  owner: session.owner)
    }

    static var pendingCount: Int { lock.withLock { pending.count } }

    /// Registers this ending and runs it in the background.
    func start(reportFailure: Bool = true) {
        Self.lock.withLock { Self.pending[ObjectIdentifier(self)] = self }
        DispatchQueue.global(qos: .utility).async { self.run(reportFailure: reportFailure) }
    }

    private func settle() {
        _ = Self.lock.withLock { Self.pending.removeValue(forKey: ObjectIdentifier(self)) }
        // If it was settled before the attempt finished (e.g. generation mismatch), signal it.
        attemptFinished.signal()
    }

    /// True when the session is confirmed gone (or was never this ending's).
    @discardableResult
    func run(reportFailure: Bool = true) -> Bool {
        guard case .record(let record) = records.read(id), record.generation == generation,
              record.runtimeID == runtimeID else {
            settle()
            return false
        }
        if let guardedRuntime,
           RuntimeCommand.killIfGeneration(guardedRuntime, name: name, generation: generation,
                                           environment: environment) == .killed {
            if (try? records.removeIfSameIdentity(record)) != nil {
                settle()
                return true
            }
        }
        markClosedButRunning()
        attemptFinished.signal()
        guard reportFailure else { return false }
        DispatchQueue.main.async {
            Self.promptAskAgain(self)
        }
        return false
    }

    /// The record says what is pending, so it survives the app ending.
    private func markClosedButRunning() {
        if case .record(var record) = records.read(id), record.generation == generation, record.runtimeID == runtimeID {
            record.state = .error(Self.closedButRunning)
            try? records.write(record)
        }
    }

    /// Keep the record so a running session can be recovered later.
    func leaveRunning() {
        Self.markDetached(id: id, generation: generation, runtimeID: runtimeID, records: records)
        settle()
    }

    private static func markDetached(id: UUID, generation: String, runtimeID: String, records: SessionRecordStore) {
        guard case .record(var record) = records.read(id), record.generation == generation,
              record.runtimeID == runtimeID else { return }
        record.state = .detached
        try? records.write(record)
    }

    @MainActor static func promptAskAgain(_ ending: Ending) {
        Task { @MainActor in
            guard let window = AppUpdater.noticeWindow(key: NSApp.keyWindow, windows: NSApp.windows)
                ?? TerminalController.preferredParent?.window
                ?? NSApp.windows.first(where: { $0.isVisible }) else {
                ending.leaveRunning()
                return
            }
            let theme = (NSApp.delegate as? AppDelegate)?.tako.config.theme
            let answer = await TerminalDialogView.choose(
                in: window,
                title: "Session May Still Be Running",
                lines: TUIText.plain("Tako could not confirm that the session ended. Try again, or keep its session record.", width: 56),
                choices: [
                    .init(title: "Leave Running", kind: .normal),
                    .init(title: "Try Again", kind: .primary)
                ],
                selected: 1,
                cancelIndex: 0,
                theme: theme
            )
            if answer == 1 {
                _ = ending.attemptFinished.wait(timeout: .now())
                DispatchQueue.global(qos: .utility).async { ending.run() }
            } else {
                ending.leaveRunning()
            }
        }
    }

    /// Quitting: waits up to `seconds` for every ending under way. Those
    /// still unsettled are marked in their records; the next launch asks.
    static func settleBeforeQuit(within seconds: TimeInterval) {
        let group = DispatchGroup()
        let endings = lock.withLock { Array(pending.values) }
        for ending in endings {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                _ = ending.attemptFinished.wait(timeout: .now() + seconds)
                group.leave()
            }
        }
        _ = group.wait(timeout: .now() + seconds + 0.1)
        let unsettled = lock.withLock { pending }
        for ending in endings {
            if unsettled[ObjectIdentifier(ending)] != nil {
                ending.markClosedButRunning()
            }
        }
    }

    /// At launch: sessions of terminals closed before Tako last quit that
    /// could not be ended. Each is asked about: end it, or leave it running.
    @MainActor static func askAboutLeftovers(records: SessionRecordStore, registry: SessionRuntimeRegistry,
                                             home: URL, openIDs: Set<UUID>) {
        let leftovers = records.all().filter { record in
            guard !openIDs.contains(record.id) else { return false }
            if case .error(let reason) = record.state, reason == closedButRunning { return true }
            return false
        }
        guard !leftovers.isEmpty else { return }

        Task { @MainActor in
            var window = AppUpdater.noticeWindow(key: NSApp.keyWindow, windows: NSApp.windows)
                ?? TerminalController.preferredParent?.window
                ?? NSApp.windows.first(where: { $0.isVisible })
            if window == nil {
                try? await Task.sleep(nanoseconds: 300_000_000)
                window = AppUpdater.noticeWindow(key: NSApp.keyWindow, windows: NSApp.windows)
                    ?? TerminalController.preferredParent?.window
                    ?? NSApp.windows.first(where: { $0.isVisible })
            }
            guard let window else {
                return
            }
            let theme = (NSApp.delegate as? AppDelegate)?.tako.config.theme
            for record in leftovers {
                let answer = await TerminalDialogView.choose(
                    in: window,
                    title: "Leftover Terminal Session",
                    lines: TUIText.plain("Tako could not confirm whether a previously closed session ended. Try again, or keep its session record.", width: 56),
                    choices: [
                        .init(title: "Leave Running", kind: .normal),
                        .init(title: "End Session", kind: .destructive)
                    ],
                    selected: 0,
                    cancelIndex: 0,
                    theme: theme
                )
                guard answer == 1 else {
                    markDetached(id: record.id, generation: record.generation, runtimeID: record.runtimeID, records: records)
                    continue
                }
                let name = SessionNamespace.sessionName(for: record.id)
                guard let runtime = try? registry.executable(for: record.runtimeID),
                      let guardedRuntime = try? registry.guardedClient(in: Bundle.main.bundleURL),
                      let namespace = try? SessionNamespace.open(runtimeID: record.runtimeID, home: home),
                      let owner = try? SessionOwnerLock(namespace: namespace, name: name)
                else { continue }   // Still marked: asked again next launch.
                Ending(runtime: runtime, guardedRuntime: guardedRuntime, name: name, environment: namespace.environment, records: records,
                       id: record.id, generation: record.generation, runtimeID: record.runtimeID, owner: owner).start()
            }
        }
    }
}

typealias SessionEnding = Ending
