/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Darwin
import Foundation

/// Read-only discovery of sessions which are not represented by a pane.
/// No observation here authorizes attachment, replacement, or termination.
enum SessionRecoveryInventory {
    enum Identity: Equatable {
        case verified
        case unverified
        case unavailable
    }

    struct Candidate: Equatable {
        let id: UUID
        let runtimeID: String
        let identity: Identity
        let record: SessionRecord?
        let observedInRuntime: Bool
        let observedGeneration: String?
        let processID: Int32?
        let executableName: String?
    }

    static func scan(records: SessionRecordStore, registry: SessionRuntimeRegistry, guardedRuntime: URL?,
                     home: URL, openIDs: Set<UUID>, openRuntimes: [UUID: String] = [:]) -> [Candidate] {
        let allSaved = records.all()
        let saved = allSaved.filter { !openIDs.contains($0.id) && openRuntimes[$0.id] != $0.runtimeID }
        let savedByID = allSaved.reduce(into: [UUID: SessionRecord]()) { $0[$1.id] = $1 }
        var results: [Candidate] = []
        var seen = Set<UUID>()
        let root = home.appendingPathComponent(".tako-sessions", isDirectory: true)
        let namespaceIDs = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let runtimeIDs = Set(registry.installed() + saved.map(\.runtimeID) + namespaceIDs)
        for runtimeID in runtimeIDs.sorted() {
            guard let executable = guardedRuntime,
                  let namespace = existingNamespace(runtimeID: runtimeID, home: home),
                  let listing = RuntimeCommand.run(executable, ["list"], environment: namespace.environment),
                  listing.status == 0 else { continue }
            let entries = RuntimeCommand.listing(listing.output)
            for name in entries.keys.sorted() {
                guard let id = sessionID(name), !openIDs.contains(id), openRuntimes[id] != runtimeID else { continue }
                let record = savedByID[id]
                let info = RuntimeCommand.run(executable, ["get", name], environment: namespace.environment)
                let labels = info.flatMap { $0.status == 0 ? Reattach.labels(from: $0.output) : nil }
                let identity: Identity
                if let labels {
                    identity = record?.runtimeID == runtimeID && labels["tako-gen"] == record?.generation
                        && !(record?.generation.isEmpty ?? true) ? .verified : .unverified
                } else {
                    identity = .unavailable
                }
                results.append(Candidate(id: id, runtimeID: runtimeID, identity: identity,
                                         record: record, observedInRuntime: true,
                                         observedGeneration: labels?["tako-gen"],
                                         processID: entries[name]?["pid"].flatMap(Int32.init),
                                         executableName: executableName(entries[name]?["cmd"])))
                if record?.runtimeID == runtimeID { seen.insert(id) }
            }
        }
        // A failed or incomplete scan cannot establish that a saved session is dead.
        results.append(contentsOf: saved.filter { !seen.contains($0.id) }.map {
            Candidate(id: $0.id, runtimeID: $0.runtimeID, identity: .unavailable,
                      record: $0, observedInRuntime: false, observedGeneration: nil,
                      processID: nil, executableName: nil)
        })
        return results.sorted { ($0.runtimeID, $0.id.uuidString) < ($1.runtimeID, $1.id.uuidString) }
    }

    /// Adopts a user-selected session while holding its owner lock. Any
    /// conflicting or damaged record is preserved before replacement.
    static func adopt(_ candidate: Candidate, records: SessionRecordStore,
                      guardedRuntime: URL, home: URL) throws -> SessionRecord {
        guard candidate.observedInRuntime,
              let generation = candidate.observedGeneration, isGeneration(generation),
              candidate.record.map({ $0.runtimeID != candidate.runtimeID || $0.generation != generation }) ?? true,
              let namespace = existingNamespace(runtimeID: candidate.runtimeID, home: home) else {
            throw AdoptionError.unverified
        }
        let name = SessionNamespace.sessionName(for: candidate.id)
        let owner = try SessionOwnerLock(namespace: namespace, name: name)
        guard let info = RuntimeCommand.run(guardedRuntime, ["get", name], environment: namespace.environment),
              info.status == 0, Reattach.labels(from: info.output)?["tako-gen"] == generation else {
            throw AdoptionError.unverified
        }
        let record = SessionRecord(id: candidate.id, runtimeID: candidate.runtimeID, generation: generation,
                                   state: .detached, createdAt: Date())
        try records.recover(record, replacing: candidate.record)
        withExtendedLifetime(owner) {}
        return record
    }

    enum AdoptionError: Error { case unverified }

    static func isGeneration(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func executableName(_ command: String?) -> String? {
        guard let first = command?.split(separator: " ").first else { return nil }
        let name = URL(fileURLWithPath: String(first)).lastPathComponent
        let safe = String(name.filter { character in
            character.asciiValue.map { (33...126).contains($0) } ?? false
        }.prefix(64))
        return safe.isEmpty ? nil : safe
    }

    private static func existingNamespace(runtimeID: String, home: URL) -> SessionNamespace? {
        guard SessionRuntimeRegistry.isValidID(runtimeID) else { return nil }
        let base = home.appendingPathComponent(".tako-sessions", isDirectory: true)
        let directory = base.appendingPathComponent(runtimeID, isDirectory: true)
        for path in [base, directory] {
            var info = stat()
            guard lstat(path.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { return nil }
        }
        let marker = directory.appendingPathComponent("runtime-id")
        guard let id = try? String(contentsOf: marker, encoding: .utf8),
              id.trimmingCharacters(in: .whitespacesAndNewlines) == runtimeID else { return nil }
        return SessionNamespace(directory: directory, runtimeID: runtimeID)
    }

    private static func sessionID(_ name: String) -> UUID? {
        guard name.utf8.count == 32, name.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            return nil
        }
        let c = Array(name)
        return UUID(uuidString: "\(String(c[0..<8]))-\(String(c[8..<12]))-\(String(c[12..<16]))-\(String(c[16..<20]))-\(String(c[20..<32]))")
    }
}
