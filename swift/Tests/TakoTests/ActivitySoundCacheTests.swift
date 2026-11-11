/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Testing
@testable import Tako

/// The sound cache (ActivitySoundCache): a known system sound copied, as is,
/// into Library/Sounds of Tako's group container -- only for a process signed
/// by the group's team with the group in its entitlements, and never over
/// anything that is not its own plain `tako-*.aiff` file. A private temp
/// directory stands in for the container and for /System/Library/Sounds.
@Suite(.serialized)
struct ActivitySoundCacheTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("tako-sound-cache-\(UUID().uuidString)")
    var source: URL { root.appendingPathComponent("System") }
    var container: URL { root.appendingPathComponent("Group") }
    var sounds: URL { container.appendingPathComponent("Library/Sounds") }
    let group = ActivitySoundCache.group

    init() throws {
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        for name in ["Glass", "Hero"] { try aiff(name).write(to: source.appendingPathComponent("\(name).aiff")) }
    }

    private func aiff(_ name: String) -> Data {
        Data("FORM".utf8) + Data([0, 0, 0, 32]) + Data("AIFF".utf8) + Data("COMM \(name) sound bytes".utf8)
    }

    private func env(groups: [String]? = nil, team: String? = ActivitySoundCache.team, container: URL? = nil) -> ActivitySoundCache.Environment {
        let url = container ?? self.container
        let g = groups ?? [group]
        return .init(groups: { g }, teamID: { team }, container: { $0 == self.group ? url : nil })
    }

    private func place(_ name: String, _ env: ActivitySoundCache.Environment) -> Result<ActivitySoundCache.Placed, ActivitySoundCache.Failure> {
        ActivitySoundCache.place(name, known: ActivitySounds.names, env: env, source: source)
    }

    private func cleanup() { try? FileManager.default.removeItem(at: root) }

    @Test func aKnownSoundIsCopiedAsIs() throws {
        defer { cleanup() }
        let placed = try place("Glass", env()).get()
        #expect(placed.fileName == "tako-Glass.aiff" && placed.url == sounds.appendingPathComponent("tako-Glass.aiff"))
        #expect(try Data(contentsOf: placed.url) == aiff("Glass"))
        #expect(placed.sha256 == ActivitySoundCache.sha256(aiff("Glass")))
        let mode = try FileManager.default.attributesOfItem(atPath: placed.url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        // Again: the same bytes are kept, not rewritten.
        let before = try FileManager.default.attributesOfItem(atPath: placed.url.path)[.modificationDate] as? Date
        #expect(try place("Glass", env()).get() == placed)
        #expect(try FileManager.default.attributesOfItem(atPath: placed.url.path)[.modificationDate] as? Date == before)
    }

    @Test func onlyAProcessSignedIntoTheGroupTouchesIt() {
        defer { cleanup() }
        #expect(place("Glass", env(groups: [])) == .failure(.notEntitled), "no group entitlement (ad-hoc, unsigned)")
        #expect(place("Glass", env(groups: ["ABCDE12345.other"])) == .failure(.notEntitled))
        #expect(place("Glass", env(team: nil)) == .failure(.otherTeam), "no team in the signature")
        #expect(place("Glass", env(team: "ABCDE12345")) == .failure(.otherTeam), "another team")
        #expect(place("Glass", .init(groups: { [self.group] }, teamID: { ActivitySoundCache.team }, container: { _ in nil }))
                == .failure(.noContainer))
        #expect(!FileManager.default.fileExists(atPath: sounds.path), "a refused process created the folder")
    }

    @Test func onlyKnownPlainSoundsAreTaken() throws {
        defer { cleanup() }
        #expect(place("Doorbell", env()) == .failure(.unknownSound))
        #expect(place("../Glass", env()) == .failure(.unknownSound))
        #expect(place("Basso", env()) == .failure(.badSource), "missing from the source folder")
        try Data("not a sound".utf8).write(to: source.appendingPathComponent("Pop.aiff"))
        #expect(place("Pop", env()) == .failure(.badSource))
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("Tink.aiff"),
                                                   withDestinationURL: source.appendingPathComponent("Glass.aiff"))
        #expect(place("Tink", env()) == .failure(.badSource), "a link is not the installed sound")
    }

    @Test func nothingButItsOwnPlainFileIsReplaced() throws {
        defer { cleanup() }
        try FileManager.default.createDirectory(at: sounds, withIntermediateDirectories: true)
        let unrelated = sounds.appendingPathComponent("Glass.aiff")
        try Data("someone else's".utf8).write(to: unrelated)
        // An older copy of ours is brought up to date.
        try Data("old".utf8).write(to: sounds.appendingPathComponent("tako-Hero.aiff"))
        #expect(try Data(contentsOf: try place("Hero", env()).get().url) == aiff("Hero"))
        // A link where ours would go stays a link.
        let elsewhere = root.appendingPathComponent("elsewhere.aiff")
        try Data("keep".utf8).write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: sounds.appendingPathComponent("tako-Glass.aiff"), withDestinationURL: elsewhere)
        #expect(place("Glass", env()) == .failure(.unsafeTarget))
        #expect(try Data(contentsOf: elsewhere) == Data("keep".utf8))
        #expect(try Data(contentsOf: unrelated) == Data("someone else's".utf8))
    }

    @Test func aLinkedLibraryFolderIsRefusedAndNothingIsMadeBeyondIt() throws {
        defer { cleanup() }
        let elsewhere = root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: container.appendingPathComponent("Library"), withDestinationURL: elsewhere)
        #expect(place("Glass", env()) == .failure(.unsafeTarget))
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty, "a Sounds folder was made outside the container")
        // A Library that is a plain file is refused too.
        try FileManager.default.removeItem(at: container.appendingPathComponent("Library"))
        try Data("x".utf8).write(to: container.appendingPathComponent("Library"))
        #expect(place("Glass", env()) == .failure(.unsafeTarget))
    }

    @Test func aLinkedSoundsFolderIsRefused() throws {
        defer { cleanup() }
        let elsewhere = root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: container.appendingPathComponent("Library"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: sounds, withDestinationURL: elsewhere)
        #expect(place("Glass", env()) == .failure(.unsafeTarget))
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    }
}
