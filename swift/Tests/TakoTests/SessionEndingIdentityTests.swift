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

@Suite(.serialized)
struct SessionEndingIdentitySpikeTests {
    @Test func aRecordFromAnotherRuntimeCannotAuthorizeKill() throws {
        let root = URL(fileURLWithPath: "/tmp/tke-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("kill-called")
        let runtime = root.appendingPathComponent("zmx")
        try Data("#!/bin/sh\n/usr/bin/touch '\(marker.path)'\nprintf 'killed session abc\\n'\n".utf8).write(to: runtime)
        chmod(runtime.path, 0o755)
        let ns = try SessionNamespace.open(runtimeID: "0.8.1-cc9574e03dfb2480", home: root)
        let records = SessionRecordStore(directory: root.appendingPathComponent("records"))
        let id = UUID()
        try records.write(SessionRecord(id: id, runtimeID: "0.8.1-0000000000000000", generation: "gen1",
                                        state: .attached, createdAt: Date()))
        let ending = Ending(runtime: runtime, guardedRuntime: runtime, name: "abc", environment: [:], records: records,
                            id: id, generation: "gen1", runtimeID: "0.8.1-cc9574e03dfb2480",
                            owner: try SessionOwnerLock(namespace: ns, name: "abc"))
        #expect(!ending.run(reportFailure: false))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        ending.leaveRunning()
        guard case .record(let retained) = records.read(id) else {
            Issue.record("unrelated session record was lost")
            return
        }
        #expect(retained.state == .attached)
    }

    @Test func missingGuardedClientNeverFallsBackToTheOldRuntime() throws {
        let root = URL(fileURLWithPath: "/tmp/tke-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("old-client-called")
        let runtime = root.appendingPathComponent("zmx")
        try Data("#!/bin/sh\n/usr/bin/touch '\(marker.path)'\nexit 0\n".utf8).write(to: runtime)
        chmod(runtime.path, 0o755)
        let ns = try SessionNamespace.open(runtimeID: "0.8.1-cc9574e03dfb2480", home: root)
        let records = SessionRecordStore(directory: root.appendingPathComponent("records"))
        let id = UUID()
        try records.write(SessionRecord(id: id, runtimeID: "0.8.1-cc9574e03dfb2480", generation: "gen1",
                                        state: .attached, createdAt: Date()))
        let ending = Ending(runtime: runtime, name: "abc", environment: [:], records: records, id: id,
                            generation: "gen1", runtimeID: "0.8.1-cc9574e03dfb2480", owner: try SessionOwnerLock(namespace: ns, name: "abc"))
        #expect(!ending.run(reportFailure: false))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test(arguments: [false, true])
    func anUnknownRecordMustNotKillByName(corrupt: Bool) throws {
        let root = URL(fileURLWithPath: "/tmp/tke-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("kill-called")
        let runtime = root.appendingPathComponent("zmx")
        let script = "#!/bin/sh\nif [ \"$1\" = kill ]; then /usr/bin/touch '\(marker.path)'; fi\nif [ \"$1\" = list ]; then printf '  name=abc\\n'; fi\nexit 0\n"
        try Data(script.utf8).write(to: runtime)
        chmod(runtime.path, 0o755)
        let ns = try SessionNamespace.open(runtimeID: "0.8.1-cc9574e03dfb2480", home: root)
        let records = SessionRecordStore(directory: root.appendingPathComponent("records"))
        let id = UUID()
        if corrupt {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("records"), withIntermediateDirectories: true)
            try Data("not a record".utf8).write(to: records.url(for: id))
        }
        let owner = try SessionOwnerLock(namespace: ns, name: "abc")
        let ending = Ending(runtime: runtime, guardedRuntime: runtime, name: "abc", environment: [:], records: records,
                            id: id, generation: "gen1", runtimeID: "0.8.1-cc9574e03dfb2480", owner: owner)
        _ = ending.run(reportFailure: false)
        #expect(!FileManager.default.fileExists(atPath: marker.path), "unknown identity must not issue kill")
    }

    @Test(arguments: ["tako-gen=another", "", "bad-label"])
    func anUnverifiedRuntimeMustNotBeKilled(labels: String) throws {
        let root = URL(fileURLWithPath: "/tmp/tke-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let marker = root.appendingPathComponent("kill-called")
        let runtime = root.appendingPathComponent("zmx")
        let script = "#!/bin/sh\nif [ \"$1\" = kill ] && [ \"$3\" = '\(labels)' ]; then /usr/bin/touch '\(marker.path)'; printf 'killed session abc\\n'; exit 0; fi\nexit 1\n"
        try Data(script.utf8).write(to: runtime)
        chmod(runtime.path, 0o755)
        let ns = try SessionNamespace.open(runtimeID: "0.8.1-cc9574e03dfb2480", home: root)
        let records = SessionRecordStore(directory: root.appendingPathComponent("records"))
        let id = UUID()
        try records.write(SessionRecord(id: id, runtimeID: "0.8.1-cc9574e03dfb2480", generation: "gen1",
                                        state: .attached, createdAt: Date()))
        let owner = try SessionOwnerLock(namespace: ns, name: "abc")
        let ending = Ending(runtime: runtime, guardedRuntime: runtime, name: "abc", environment: [:], records: records,
                            id: id, generation: "gen1", runtimeID: "0.8.1-cc9574e03dfb2480", owner: owner)
        #expect(!ending.run(reportFailure: false))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        guard case .record(let retained) = records.read(id) else {
            Issue.record("session record was lost")
            return
        }
        #expect(retained.state == .error(Ending.closedButRunning))
    }
}
