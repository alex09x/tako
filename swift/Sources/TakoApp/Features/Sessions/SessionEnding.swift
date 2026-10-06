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
    let name: String
    let environment: [String: String]
    let records: SessionRecordStore
    let id: UUID
    let generation: String
    let owner: SessionOwnerLock

    private static let lock = NSLock()
    nonisolated(unsafe) private static var pending: [ObjectIdentifier: Ending] = [:]
    let attemptFinished = DispatchSemaphore(value: 0)

    init(runtime: URL, name: String, environment: [String: String], records: SessionRecordStore,
         id: UUID, generation: String, owner: SessionOwnerLock) {
        self.runtime = runtime
        self.name = name
        self.environment = environment
        self.records = records
        self.id = id
        self.generation = generation
        self.owner = owner
    }

    @MainActor convenience init(_ session: SurfaceSession) {
        self.init(runtime: session.runtime, name: session.name, environment: session.namespace.environment,
                  records: session.records, id: session.record.id, generation: session.record.generation,
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
        if case .record(let record) = records.read(id), record.generation != generation {
            settle()
            return true
        }
        _ = RuntimeCommand.run(runtime, ["kill", name], environment: environment, timeout: 3)
        let listed = RuntimeCommand.isListed(runtime, name: name, environment: environment)
        attemptFinished.signal()

        if listed == false {
            records.remove(id)
            settle()
            return true
        }
        markClosedButRunning()
        guard reportFailure else { return false }
        DispatchQueue.main.async {
            if Self.askAgain(self.name) {
                _ = self.attemptFinished.wait(timeout: .now())
                DispatchQueue.global(qos: .utility).async { self.run() }
            } else {
                self.leaveRunning()
            }
        }
        return false
    }

    /// The record says what is pending, so it survives the app ending.
    private func markClosedButRunning() {
        if case .record(var record) = records.read(id), record.generation == generation {
            record.state = .error(Self.closedButRunning)
            try? records.write(record)
        }
    }

    /// The user chose to leave the session running: Tako forgets it.
    func leaveRunning() {
        records.remove(id)
        settle()
    }

    @MainActor static func askAgain(_ name: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "A closed terminal is still running"
        alert.informativeText = "Its session could not be ended. Try again, or leave it running -- Tako will then stop tracking it."
        alert.addButton(withTitle: "Try Again")
        alert.addButton(withTitle: "Leave It Running")
        return alert.runModal() == .alertFirstButtonReturn
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
        for record in records.all() where !openIDs.contains(record.id) {
            guard case .error(let reason) = record.state, reason == closedButRunning else { continue }
            let alert = NSAlert()
            alert.messageText = "A terminal closed before Tako last quit is still running"
            alert.informativeText = "Its session could not be ended then. End it now, or leave it running -- Tako will then stop tracking it."
            alert.addButton(withTitle: "End It")
            alert.addButton(withTitle: "Leave It Running")
            guard alert.runModal() == .alertFirstButtonReturn else {
                records.remove(record.id)
                continue
            }
            let name = SessionNamespace.sessionName(for: record.id)
            guard let runtime = try? registry.executable(for: record.runtimeID),
                  let namespace = try? SessionNamespace.open(runtimeID: record.runtimeID, home: home),
                  let owner = try? SessionOwnerLock(namespace: namespace, name: name)
            else { continue }   // Still marked: asked again next launch.
            Ending(runtime: runtime, name: name, environment: namespace.environment, records: records,
                   id: record.id, generation: record.generation, owner: owner).start()
        }
    }
}

typealias SessionEnding = Ending
