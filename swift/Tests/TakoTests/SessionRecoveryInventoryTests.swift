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
import Testing
@testable import Tako

struct SessionRecoveryInventoryTests {
    @Test func aSessionRecordSymlinkIsUnreadableAndNeverReplaced() throws {
        let root = URL(fileURLWithPath: "/tmp/tki-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let records = SessionRecordStore(directory: root)
        let id = UUID()
        let target = root.appendingPathComponent("target")
        let record = SessionRecord(id: id, runtimeID: "0.8.1-0000000000000000", generation: "gen",
                                   state: .detached, createdAt: Date())
        let bytes = try JSONEncoder().encode(record)
        try bytes.write(to: target)
        try FileManager.default.createSymbolicLink(at: records.url(for: id), withDestinationURL: target)
        #expect(records.read(id) == .unreadable)
        #expect(throws: (any Error).self) { try records.write(record) }
        #expect(try Data(contentsOf: target) == bytes)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: records.url(for: id).path) == target.path)
    }

    @Test func damagedRecordRecoveryDoesNotFollowAHistorySymlink() throws {
        let root = URL(fileURLWithPath: "/tmp/tki-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let records = SessionRecordStore(directory: root)
        let id = UUID()
        let damaged = Data("damaged record".utf8)
        try damaged.write(to: records.url(for: id))
        let elsewhere = root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("History"), withDestinationURL: elsewhere)
        let proposed = SessionRecord(id: id, runtimeID: "0.8.1-cc9574e03dfb2480",
                                     generation: "0123456789abcdef0123456789abcdef", state: .detached, createdAt: Date())
        #expect(throws: (any Error).self) { try records.recover(proposed) }
        #expect(try Data(contentsOf: records.url(for: id)) == damaged)
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    }

    @Test func damagedRecordIsUntouchedWhenItsArchiveCannotBeSaved() throws {
        let root = URL(fileURLWithPath: "/tmp/tki-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let records = SessionRecordStore(directory: root)
        let id = UUID()
        let damaged = Data("damaged record".utf8)
        try damaged.write(to: records.url(for: id))
        try Data("not a directory".utf8).write(to: root.appendingPathComponent("History"))
        let proposed = SessionRecord(id: id, runtimeID: "0.8.1-cc9574e03dfb2480",
                                     generation: "0123456789abcdef0123456789abcdef",
                                     state: .detached, createdAt: Date())
        #expect(throws: (any Error).self) { try records.recover(proposed) }
        #expect(try Data(contentsOf: records.url(for: id)) == damaged)
    }

    @Test(arguments: [false, true])
    func discoversUnplacedSessionsWithoutMutatingRuntime(damagedRecord: Bool) throws {
        let root = URL(fileURLWithPath: "/tmp/tki-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let savedID = UUID(), unrecordedID = UUID(), openID = UUID(), missingID = UUID(), mismatchID = UUID(), crossID = UUID()
        let savedName = SessionNamespace.sessionName(for: savedID)
        let unrecordedName = SessionNamespace.sessionName(for: unrecordedID)
        let openName = SessionNamespace.sessionName(for: openID)
        let mismatchName = SessionNamespace.sessionName(for: mismatchID)
        let crossName = SessionNamespace.sessionName(for: crossID)
        let marker = root.appendingPathComponent("mutated")
        let calls = root.appendingPathComponent("called")
        let runtime = root.appendingPathComponent("zmx")
        let script = """
        #!/bin/sh
        /usr/bin/touch '\(calls.path)'
        case "$1" in
          list) printf '  name=\(savedName)\\tpid=1\\n  name=\(unrecordedName)\\tpid=2\\tcmd=/bin/sh\\n  name=\(openName)\\tpid=3\\n  name=\(mismatchName)\\tpid=4\\n  name=\(crossName)\\tpid=5\\n' ;;
          get) if [ "$2" = "\(unrecordedName)" ] || [ "$2" = "\(mismatchName)" ] || [ "$2" = "\(crossName)" ]; then
                 printf 'tako-gen=0123456789abcdef0123456789abcdef\\n'
               else printf 'tako-gen=g1\\n'; fi ;;
          *) /usr/bin/touch '\(marker.path)' ;;
        esac
        """
        try Data(script.utf8).write(to: runtime)
        chmod(runtime.path, 0o755)
        let registry = SessionRuntimeRegistry(root: root.appendingPathComponent("support"))
        let manifest = SessionRuntimeRegistry.Manifest(name: "zmx", version: "0.8.1", commit: "8bab1f0",
                                                        sha256: try SessionRuntimeRegistry.sha256(of: runtime))
        let runtimeID = try registry.install(manifest: manifest, from: runtime)
        let guardedRuntime = try registry.executable(for: runtimeID)
        let namespace = try SessionNamespace.open(runtimeID: runtimeID, home: root)
        let records = SessionRecordStore(directory: root.appendingPathComponent("records"))
        for id in [savedID, openID, missingID] {
            try records.write(SessionRecord(id: id, runtimeID: runtimeID, generation: "g1",
                                            state: .detached, createdAt: Date()))
        }
        try records.write(SessionRecord(id: mismatchID, runtimeID: runtimeID, generation: "different",
                                        state: .detached, createdAt: Date()))
        let crossPrevious = SessionRecord(id: crossID, runtimeID: "0.8.1-0000000000000000",
            generation: "0123456789abcdef0123456789abcdef", state: .creating, createdAt: Date())
        try records.write(crossPrevious)
        if damagedRecord {
            try Data("damaged record".utf8).write(to: records.url(for: unrecordedID))
        }

        let unavailable = SessionRecoveryInventory.scan(records: records, registry: registry, guardedRuntime: nil,
                                                        home: root, openIDs: [openID])
        #expect(unavailable.allSatisfy { $0.identity == .unavailable })
        #expect(!FileManager.default.fileExists(atPath: calls.path))
        let found = SessionRecoveryInventory.scan(records: records, registry: registry, guardedRuntime: guardedRuntime,
                                                  home: root, openIDs: [openID])
        #expect(found.first(where: { $0.id == savedID })?.identity == .verified)
        #expect(found.first(where: { $0.id == unrecordedID })?.identity == .unverified)
        #expect(found.first(where: { $0.id == missingID })?.identity == .unavailable)
        #expect(found.first(where: { $0.id == mismatchID })?.identity == .unverified)
        let cross = try #require(found.first(where: { $0.id == crossID && $0.runtimeID == runtimeID }))
        #expect(cross.identity == .unverified)
        #expect(cross.record == crossPrevious)
        let openElsewhere = SessionRecoveryInventory.scan(records: records, registry: registry, guardedRuntime: guardedRuntime,
            home: root, openIDs: [], openRuntimes: [crossID: crossPrevious.runtimeID, savedID: runtimeID])
        #expect(openElsewhere.contains { $0.id == crossID && $0.runtimeID == runtimeID })
        #expect(openElsewhere.first { $0.id == crossID && $0.runtimeID == runtimeID }?.record == crossPrevious)
        #expect(!openElsewhere.contains { $0.id == savedID && $0.runtimeID == runtimeID })
        #expect(!found.contains(where: { $0.id == openID }))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        let unrecorded = try #require(found.first(where: { $0.id == unrecordedID }))
        #expect(unrecorded.processID == 2)
        #expect(unrecorded.executableName == "sh")
        do {
            let owner = try SessionOwnerLock(namespace: namespace, name: unrecordedName)
            #expect(throws: (any Error).self) {
                try SessionRecoveryInventory.adopt(unrecorded, records: records, guardedRuntime: guardedRuntime, home: root)
            }
            withExtendedLifetime(owner) {}
        }
        let adopted = try SessionRecoveryInventory.adopt(unrecorded, records: records, guardedRuntime: guardedRuntime, home: root)
        #expect(adopted.generation == "0123456789abcdef0123456789abcdef")
        #expect(records.read(unrecordedID) == .record(adopted))
        if damagedRecord {
            let history = records.directory.appendingPathComponent("History")
            let files = try FileManager.default.contentsOfDirectory(at: history, includingPropertiesForKeys: nil)
            #expect(try files.contains { try Data(contentsOf: $0) == Data("damaged record".utf8) })
        }
        #expect(throws: (any Error).self) {
            try SessionRecoveryInventory.adopt(unrecorded, records: records, guardedRuntime: guardedRuntime, home: root)
        }
        var replacement = adopted
        replacement.generation = "ffffffffffffffffffffffffffffffff"
        #expect(throws: (any Error).self) { try records.createIfAbsent(replacement) }
        #expect(records.read(unrecordedID) == .record(adopted))
        let mismatch = try #require(found.first(where: { $0.id == mismatchID }))
        let previous = try #require(mismatch.record)
        let adoptedMismatch = try SessionRecoveryInventory.adopt(mismatch, records: records,
                                                                  guardedRuntime: guardedRuntime, home: root)
        #expect(records.read(mismatchID) == .record(adoptedMismatch))
        let historyFiles = try FileManager.default.contentsOfDirectory(at: records.directory.appendingPathComponent("History"),
                                                                       includingPropertiesForKeys: nil)
        #expect(historyFiles.contains { file in
            (try? JSONDecoder().decode(SessionRecord.self, from: Data(contentsOf: file))) == previous
        })
        let crossAdopted = try SessionRecoveryInventory.adopt(cross, records: records,
                                                              guardedRuntime: guardedRuntime, home: root)
        #expect(crossAdopted.runtimeID == runtimeID)
        #expect(records.read(crossID) == .record(crossAdopted))
        let allHistory = try FileManager.default.contentsOfDirectory(at: records.directory.appendingPathComponent("History"),
                                                                     includingPropertiesForKeys: nil)
        #expect(allHistory.contains { file in
            (try? JSONDecoder().decode(SessionRecord.self, from: Data(contentsOf: file))) == crossPrevious
        })
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
}
