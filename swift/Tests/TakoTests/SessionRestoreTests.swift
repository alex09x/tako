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


/// A store in a directory of its own, installed as the shared one for the
/// test's lifetime so nothing reaches the user's Application Support.
@MainActor
private final class TemporaryStore {
    let store: SessionSnapshotStore
    private let previous: SessionSnapshotStore

    init() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tako-sessions-\(UUID().uuidString)", isDirectory: true)
        store = SessionSnapshotStore(directory: dir)
        previous = SessionSnapshotStore.shared
        SessionSnapshotStore.shared = store
    }

    func files() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: store.directory.path)) ?? []).sorted()
    }

    func tearDown() {
        SessionSnapshotStore.shared = previous
        try? FileManager.default.removeItem(at: store.directory)
    }
}

@MainActor
private func makeSurface() -> Tako.SurfaceView {
    Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
}

@MainActor
private func text(of surface: Tako.SurfaceView) -> String {
    surface.core.bufferText()
}

private let on = SessionSnapshotSaver.Settings(enabled: true, limit: 64 << 20, secureInput: false)

@Suite
@MainActor
struct SessionRestoreTests {
    @Test func storeRoundTripsAndKeepsFilesPrivate() throws {
        let tmp = TemporaryStore()
        defer { tmp.tearDown() }
        let id = UUID()
        let saved = SessionSnapshot(savedAt: Date(timeIntervalSince1970: 1_790_000_000.5), checkpoint: Data([1, 2, 3]))

        try tmp.store.write(saved, id: id)

        #expect(tmp.store.read(id: id) == saved)
        let mode = try FileManager.default.attributesOfItem(atPath: tmp.store.url(for: id).path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(tmp.store.read(id: UUID()) == nil)
    }

    @Test func storeRejectsAFileItDidNotWrite() throws {
        let tmp = TemporaryStore()
        defer { tmp.tearDown() }
        let id = UUID()
        try FileManager.default.createDirectory(at: tmp.store.directory, withIntermediateDirectories: true)
        try Data("not a snapshot".utf8).write(to: tmp.store.url(for: id))

        #expect(tmp.store.read(id: id) == nil)
    }

    @Test func aRestoredTabShowsItsOldScreenWithoutABannerAndKeepsItsIdentity() throws {
        let tmp = TemporaryStore()
        defer { tmp.tearDown() }
        let original = makeSurface()
        defer { original.close() }
        original.core.feed(bytes: Data("build failed: 3 errors\r\n".utf8))

        SessionSnapshotSaver(store: tmp.store).save([original], settings: on)
        let encoded = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(Tako.SurfaceView.self, from: encoded)
        defer { restored.close() }

        #expect(restored.id == original.id)
        let screen = text(of: restored)
        #expect(screen.contains("build failed: 3 errors"))
        // No banner: the old screen, then the new shell, nothing between.
        #expect(!screen.contains("restored from"))
    }

    @Test func aRestoredTabIsSavedWithWhatItPrintedAfterwards() throws {
        let tmp = TemporaryStore()
        defer { tmp.tearDown() }
        let first = makeSurface()
        defer { first.close() }
        first.core.feed(bytes: Data("first-life\r\n".utf8))
        let saver = SessionSnapshotSaver(store: tmp.store)
        saver.save([first], settings: on)

        let second = try JSONDecoder().decode(Tako.SurfaceView.self, from: JSONEncoder().encode(first))
        defer { second.close() }
        second.core.feed(bytes: Data("second-life\r\n".utf8))
        SessionSnapshotSaver(store: tmp.store).save([second], settings: on)

        let third = try JSONDecoder().decode(Tako.SurfaceView.self, from: JSONEncoder().encode(second))
        defer { third.close() }
        let screen = text(of: third)
        // Each life in order, once each.
        let firstLife = try #require(screen.range(of: "first-life"))
        let secondLife = try #require(screen.range(of: "second-life"))
        #expect(firstLife.upperBound <= secondLife.lowerBound)
        #expect(screen.components(separatedBy: "first-life").count == 2)
        #expect(screen.components(separatedBy: "second-life").count == 2)
    }

    @Test func withoutASavedScreenATabStillComesBackEmpty() throws {
        let tmp = TemporaryStore()
        defer { tmp.tearDown() }
        let original = makeSurface()
        defer { original.close() }

        let restored = try JSONDecoder().decode(Tako.SurfaceView.self, from: JSONEncoder().encode(original))
        defer { restored.close() }

        #expect(text(of: restored).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test func theSeparatorHandsAFreshShellPlainInputModes() {
        let surface = makeSurface()
        defer { surface.close() }
        // What a full-screen program leaves on: the alternate screen, mouse
        // reporting, bracketed paste, application cursor keys.
        surface.core.feed(bytes: Data("\u{1b}[?1049h\u{1b}[?1002h\u{1b}[?1006h\u{1b}[?2004h\u{1b}[?1h".utf8))
        #expect(surface.core.modes().alternateScreen)

        surface.core.feed(bytes: Data(SessionSnapshot.leaveAlternateScreen))
        surface.core.feed(bytes: Data(SessionSnapshot.separator(
            savedAt: Date(), cursorRow: surface.core.cursorRow(), cursorCol: surface.core.cursorCol())))

        let modes = surface.core.modes()
        #expect(!modes.alternateScreen)
        #expect(modes.mouseTracking == .off)
        #expect(!modes.mouseSgr)
        #expect(!modes.bracketedPaste)
        #expect(!modes.cursorKeyAppMode)
    }

    @Test func aTabIsWrittenAgainOnlyAfterItsShellPrintedSomething() {
        let surface = makeSurface()
        defer { surface.close() }
        #expect(waitUntil { surface.exportSnapshotState(maxBytes: 0, unlessGeneration: 0) != .unchanged })

        guard case .exported(_, let generation) = surface.exportSnapshotState(maxBytes: 0, unlessGeneration: nil)
        else { Issue.record("no state"); return }
        // Quiet shell: nothing new parsed, so nothing to write -- the prompt
        // may still be arriving, so allow it to settle first.
        _ = waitUntil(timeout: 0.5) { false }
        guard case .exported(_, let settled) = surface.exportSnapshotState(maxBytes: 0, unlessGeneration: nil)
        else { Issue.record("no state"); return }
        #expect(generation <= settled)
        #expect(surface.exportSnapshotState(maxBytes: 0, unlessGeneration: settled) == .unchanged)
    }

    @Test func turningSavingOffRemovesWhatWasSaved() {
        let tmp = TemporaryStore()
        defer { tmp.tearDown() }
        let surface = makeSurface()
        defer { surface.close() }
        let saver = SessionSnapshotSaver(store: tmp.store)

        saver.save([surface], settings: on)
        #expect(tmp.files().count == 1)

        saver.save([surface], settings: .init(enabled: false, limit: 64 << 20, secureInput: false))
        #expect(tmp.files().isEmpty)
    }

    @Test func secureKeyboardEntryKeepsEverythingOffDisk() {
        let tmp = TemporaryStore()
        defer { tmp.tearDown() }
        let surface = makeSurface()
        defer { surface.close() }
        let saver = SessionSnapshotSaver(store: tmp.store)
        saver.save([surface], settings: on)

        saver.save([surface], settings: .init(enabled: true, limit: 64 << 20, secureInput: true))

        #expect(tmp.files().isEmpty)
    }

    @Test func aTabTooBigForItsShareIsDroppedRatherThanLeftStale() {
        let tmp = TemporaryStore()
        defer { tmp.tearDown() }
        let surface = makeSurface()
        defer { surface.close() }
        let saver = SessionSnapshotSaver(store: tmp.store)
        saver.save([surface], settings: on)
        #expect(tmp.files().count == 1)

        // The shell echoes a key, so the tab is due again; then a limit
        // nothing fits in.
        surface.writeToShell(Array("x".utf8))
        _ = waitUntil(timeout: 0.5) { false }
        saver.save([surface], settings: .init(enabled: true, limit: 16, secureInput: false))

        #expect(tmp.files().isEmpty)
    }

    @Test func aSmallerLimitEvictsAnUnchangedTabAndARoomierOneBringsItBack() throws {
        let tmp = TemporaryStore()
        defer { tmp.tearDown() }
        let surface = makeSurface()
        defer { surface.close() }
        let saver = SessionSnapshotSaver(store: tmp.store)
        saver.save([surface], settings: on)
        let size = try #require(tmp.store.size(id: surface.id))

        // Nothing new printed, but the share no longer holds the file.
        saver.save([surface], settings: .init(enabled: true, limit: size - 1, secureInput: false))
        #expect(tmp.files().isEmpty)

        saver.save([surface], settings: on)
        #expect(tmp.files().count == 1)
    }

    @Test func closedTabsLoseTheirFiles() {
        let tmp = TemporaryStore()
        defer { tmp.tearDown() }
        let a = makeSurface()
        let b = makeSurface()
        defer { a.close(); b.close() }
        let saver = SessionSnapshotSaver(store: tmp.store)
        saver.save([a, b], settings: on)
        #expect(tmp.files().count == 2)

        saver.save([a], settings: on)

        #expect(tmp.files() == [a.id.uuidString + ".snapshot"])
    }

    @Test func aRestoredShellStartsWhereTheOldOneReportedOnlyIfThatStillExists() throws {
        let dir = FileManager.default.temporaryDirectory.path
        #expect(Tako.SurfaceView.restoredWorkingDirectory(dir, fallback: "/fallback") == dir)
        #expect(Tako.SurfaceView.restoredWorkingDirectory("/no/such/dir-\(UUID())", fallback: "/fallback") == "/fallback")
        #expect(Tako.SurfaceView.restoredWorkingDirectory(nil, fallback: nil) == NSHomeDirectory())
        // A file is not somewhere a shell can start.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tako-file-\(UUID())")
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(Tako.SurfaceView.restoredWorkingDirectory(file.path, fallback: "/fallback") == "/fallback")
    }

    @Test func windowSaveStateIsReadFromTheConfig() throws {
        #expect(try TemporaryConfig("").windowSaveState == "always")
        #expect(try TemporaryConfig("window-save-state = never").windowSaveState == "never")
        #expect(try TemporaryConfig("window-save-state = default").windowSaveState == "default")
        #expect(try TemporaryConfig("window-save-state = sometimes").windowSaveState == "always")
    }

    @Test func savingIsOnByDefaultAndConfigurable() throws {
        #expect(try TemporaryConfig("").windowSaveContent)
        #expect(try TemporaryConfig("").windowSaveContentLimit == 64 << 20)
        #expect(try !TemporaryConfig("window-save-content = false").windowSaveContent)
        #expect(try TemporaryConfig("window-save-content-limit = 8").windowSaveContentLimit == 8 << 20)
        #expect(try TemporaryConfig("window-save-content-limit = nope").windowSaveContentLimit == 64 << 20)
        // Out of range must not trap converting to bytes.
        #expect(try TemporaryConfig("window-save-content-limit = 1e300").windowSaveContentLimit == 1 << 40)
        #expect(try TemporaryConfig("window-save-content-limit = inf").windowSaveContentLimit == 64 << 20)
        #expect(try TemporaryConfig("window-save-content-limit = -1").windowSaveContentLimit == 64 << 20)
    }
}
