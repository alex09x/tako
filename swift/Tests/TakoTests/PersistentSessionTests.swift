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

let runtimeID = "0.8.1-cc9574e03dfb2480"

/// A home directory of its own, short enough for socket paths.
struct Home {
    let url = URL(fileURLWithPath: "/tmp/tkh-\(UUID().uuidString.prefix(8))", isDirectory: true)
    init() { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    func tearDown() { try? FileManager.default.removeItem(at: url) }
}

@Suite
struct PersistentSessionTests {
    // MARK: namespace

    @Test func theNamespaceIsAPrivateDirectoryForOneRuntime() throws {
        let home = Home()
        defer { home.tearDown() }
        let ns = try SessionNamespace.open(runtimeID: runtimeID, home: home.url)

        var info = stat()
        #expect(lstat(ns.directory.path, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o700)
        #expect(try String(contentsOf: ns.directory.appendingPathComponent("runtime-id"), encoding: .utf8) == runtimeID + "\n")
        // Opening it again for the same runtime is fine.
        #expect(try SessionNamespace.open(runtimeID: runtimeID, home: home.url) == ns)
        let name = SessionNamespace.sessionName(for: UUID())
        #expect(name.count == 32)
        #expect(ns.socketPath(for: name).utf8.count <= SessionNamespace.socketPathLimit)
    }

    @Test func aDirectoryMadeForAnotherRuntimeIsRefused() throws {
        let home = Home()
        defer { home.tearDown() }
        let ns = try SessionNamespace.open(runtimeID: runtimeID, home: home.url)
        try Data("0.8.1-0000000000000000\n".utf8).write(to: ns.directory.appendingPathComponent("runtime-id"))

        #expect(throws: SessionNamespace.Failure.belongsToAnotherRuntime("0.8.1-0000000000000000\n")) {
            try SessionNamespace.open(runtimeID: runtimeID, home: home.url)
        }
    }

    @Test func aNamespaceOthersCanReadOrThatIsALinkIsRefused() throws {
        let home = Home()
        defer { home.tearDown() }
        let ns = try SessionNamespace.open(runtimeID: runtimeID, home: home.url)
        chmod(ns.directory.path, 0o750)
        #expect(throws: SessionNamespace.Failure.notPrivate(ns.directory.path)) {
            try SessionNamespace.open(runtimeID: runtimeID, home: home.url)
        }

        let other = Home()
        defer { other.tearDown() }
        let base = other.url.appendingPathComponent(".tako-sessions")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        chmod(base.path, 0o700)
        let elsewhere = other.url.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        chmod(elsewhere.path, 0o700)
        try FileManager.default.createSymbolicLink(at: base.appendingPathComponent(runtimeID), withDestinationURL: elsewhere)
        #expect(throws: SessionNamespace.Failure.notPrivate(base.appendingPathComponent(runtimeID).path)) {
            try SessionNamespace.open(runtimeID: runtimeID, home: other.url)
        }
    }

    @Test func aHomeTooLongForSocketPathsIsRefused() throws {
        let deep = URL(fileURLWithPath: "/tmp/" + String(repeating: "d", count: 60), isDirectory: true)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: deep) }
        #expect(throws: SessionNamespace.Failure.self) {
            try SessionNamespace.open(runtimeID: runtimeID, home: deep)
        }
    }

    @Test func aRuntimeIdThatIsNotOneComponentIsRefused() {
        #expect(throws: SessionNamespace.Failure.self) {
            try SessionNamespace.open(runtimeID: "../x-cc9574e03dfb2480", home: URL(fileURLWithPath: "/tmp"))
        }
    }

    @Test func theRuntimeEnvironmentPointsAtTheNamespaceAndTracksNothing() throws {
        let home = Home()
        defer { home.tearDown() }
        let env = try SessionNamespace.open(runtimeID: runtimeID, home: home.url).environment
        #expect(env["ZMX_NO_DETACH_KEY"] == "1")
        #expect(env["ZMX_TRACK_ENV"] == "")
        #expect(env["ZMX_DIR"]?.hasPrefix(home.url.path) == true)
        #expect(SessionNamespace.inheritedVariablesToDrop.contains("ZMX_SESSION"))
    }

    // MARK: owner

    @Test func aSecondOwnerIsRefusedAndTheFirstReleasesOnItsEnd() throws {
        let home = Home()
        defer { home.tearDown() }
        let ns = try SessionNamespace.open(runtimeID: runtimeID, home: home.url)
        let name = SessionNamespace.sessionName(for: UUID())

        var first: SessionOwnerLock? = try SessionOwnerLock(namespace: ns, name: name)
        #expect(throws: SessionOwnerLock.Failure.heldElsewhere) { try SessionOwnerLock(namespace: ns, name: name) }
        #expect(first != nil)
        first = nil
        #expect((try? SessionOwnerLock(namespace: ns, name: name)) != nil)
    }

    // MARK: records

    @Test func recordsRoundTripAndAnUnreadableOneIsNotNoSession() throws {
        let home = Home()
        defer { home.tearDown() }
        let store = SessionRecordStore(directory: home.url.appendingPathComponent("records"))
        let id = UUID()
        #expect(store.read(id) == .none)

        let record = SessionRecord(id: id, runtimeID: runtimeID, generation: SessionRecord.newGeneration(),
                                   state: .creating, createdAt: Date(timeIntervalSince1970: 1_790_000_000))
        try store.write(record)
        #expect(store.read(id) == .record(record))

        try Data("garbage".utf8).write(to: store.url(for: id))
        #expect(store.read(id) == .unreadable)

        // A record filed under another terminal's id is not this one's.
        var other = record
        other.id = UUID()
        try JSONEncoder().encode(other).write(to: store.url(for: id))
        #expect(store.read(id) == .unreadable)
    }

    // MARK: reattach

    @Test func labelsParseExactlyOrNotAtAll() {
        #expect(Reattach.labels(from: "tako-attempt=ab tako-gen=cd\n") == ["tako-attempt": "ab", "tako-gen": "cd"])
        #expect(Reattach.labels(from: "") == [:])
        #expect(Reattach.labels(from: "tako-gen") == nil)
        #expect(Reattach.labels(from: "=x") == nil)
        #expect(Reattach.labels(from: "tako-gen=a tako-gen=b") == nil)
    }

    @Test func onlyTheExactGenerationAndThisAttemptWithOurClientIsLive() {
        func c(_ labels: [String: String]?, marker: Bool = false, client: Bool = true, timedOut: Bool = false)
            -> ReattachOutcome {
            Reattach.classify(generation: "gen1", attempt: "att1", labels: labels, marker: marker,
                              clientRunning: client, timedOut: timedOut)
        }
        #expect(c(["tako-gen": "gen1", "tako-attempt": "att1"]) == .live)
        // A prefix, another generation, an older attempt: not this session.
        #expect(c(["tako-gen": "gen", "tako-attempt": "att1"]) == .pending)
        #expect(c(["tako-gen": "gen2", "tako-attempt": "att1"]) == .pending)
        #expect(c(["tako-gen": "gen1", "tako-attempt": "att0"]) == .pending)
        // Only the attempt label: a session the runtime just made for the sentinel.
        #expect(c(["tako-attempt": "att1"]) == .pending)
        // Our client gone: never live, whatever the labels.
        #expect(c(["tako-gen": "gen1", "tako-attempt": "att1"], client: false) == .pending)
        // A failed get.
        #expect(c(nil) == .pending)
        // This attempt's marker settles it.
        #expect(c(nil, marker: true, client: false) == .absent)
        // Out of time: an error, never "absent".
        #expect(c(nil, timedOut: true) == .error("the session did not answer in time"))
        #expect(c(["tako-gen": "gen2"], timedOut: true) == .error("the session found is not the one Tako made"))
        #expect(c(nil, client: false, timedOut: true) == .error("the attach client exited without an answer"))
    }

    // MARK: client preamble

    @Test func theClientsOpeningIsRemovedAndNothingElse() {
        func run(_ chunks: [String], name: String = "abc") -> String {
            var p = SessionClientPreamble(sessionName: name)
            return chunks.map { String(decoding: p.consume(Data($0.utf8)), as: UTF8.self) }.joined()
        }
        let clear = "\u{1b}[2J\u{1b}[H"
        // A session the attach created: the line, CR LF or LF, then the clear.
        #expect(run(["session \"abc\" created\r\n" + clear + "$ "]) == "$ ")
        #expect(run(["session \"abc\" created\n", clear, "$ "]) == "$ ")
        // Split anywhere.
        #expect(run(["sess", "ion \"abc\" cre", "ated\r\n\u{1b}[2", "J\u{1b}[Hhi"]) == "hi")
        // An existing session: only the clear, then its restored state.
        #expect(run([clear + "\u{1b}[2J\u{1b}[Hstate"]) == "\u{1b}[2J\u{1b}[Hstate")
        // Someone else's name is not ours to remove.
        #expect(run(["session \"other\" created\n" + clear]) == "session \"other\" created\n" + clear)
        // Output that is not the preamble passes untouched.
        #expect(run(["plain text"]) == "plain text")
        // After the preamble, a later clear is the program's and stays.
        #expect(run([clear, "x", clear]) == "x" + clear)
    }
}

/// RuntimeCommand against stand-in helpers: harmless scripts, no runtime.
@Suite
struct RuntimeCommandTests {
    func helper(_ body: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tako-helper-\(UUID().uuidString).sh")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        chmod(url.path, 0o755)
        return url
    }


}
