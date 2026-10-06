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

@Suite
@MainActor
struct LayoutJournalTests {
    @Test func theLaunchDecisionCoversEveryCase() {
        typealias J = LayoutJournal
        let reads: [J.JournalRead] = [.valid, .invalid("x"), .missing]
        for previous in [J.LaunchState.firstRun, .dirty, .restoring, .clean] {
            for read in reads {
                let want: J.Source = (previous == .dirty || previous == .restoring) && read == .valid ? .journal : .appKit
                #expect(J.decide(previous: previous, journal: read) == want, "\(previous) \(read)")
            }
        }
    }

    private func journal(tabs: [Any], windows: Int = 1, version: Int = 1) -> Data {
        let window: [String: Any] = ["frame": [0, 0, 800, 600], "key": true, "selectedTab": 0, "tabs": tabs]
        let root: [String: Any] = ["version": version, "generation": 3,
                                   "windows": Array(repeating: window, count: windows)]
        return try! JSONSerialization.data(withJSONObject: root)
    }

    private let leaf: [String: Any] = ["leaf": ["view": ["id": UUID().uuidString]]]
    /// A tab exactly as TerminalRestorableState writes it -- encoded, not
    /// written by hand -- with one pane, or `root` in place of its tree.
    private func tab(_ root: Any? = nil) -> [String: Any] {
        let state = TerminalRestorableState.InternalState<LayoutJournal.PaneShape>(
            focusedSurface: nil,
            surfaceTree: SplitTree(view: LayoutJournal.PaneShape(id: UUID())),
            effectiveFullscreenMode: nil, tabColor: nil, titleOverride: nil)
        var object = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        if let root {
            var tree = object["surfaceTree"] as! [String: Any]
            tree["root"] = root
            object["surfaceTree"] = tree
        }
        return object
    }

    @Test func aGoodJournalReadsBack() throws {
        let data = journal(tabs: [["surfaceTree": ["root": leaf]], ["surfaceTree": ["root": leaf]]])
        guard case .success(let j) = LayoutJournal.read(data) else { Issue.record("rejected"); return }
        #expect(j.generation == 3 && j.windows.count == 1 && j.windows[0].tabs.count == 2)
        // And survives its own encoding.
        guard case .success(let again) = LayoutJournal.read(try LayoutJournal.encode(j)) else { Issue.record("re-read"); return }
        #expect(again.windows[0].tabs.count == 2)
    }

    @Test func anythingWrongRejectsTheWholeFile() {
        func rejected(_ data: Data) -> Bool { if case .failure = LayoutJournal.read(data) { return true } else { return false } }
        #expect(rejected(Data("not json".utf8)))
        #expect(rejected(Data("[]".utf8)))
        #expect(rejected(journal(tabs: [leaf], version: 2)))
        #expect(rejected(journal(tabs: [])))
        #expect(rejected(journal(tabs: [leaf], windows: LayoutJournal.maxWindows + 1)))
        #expect(rejected(journal(tabs: Array(repeating: leaf, count: LayoutJournal.maxTabs + 1))))
        var deep: Any = leaf
        for _ in 0..<(LayoutJournal.maxDepth + 2) { deep = ["split": ["left": deep]] }
        #expect(rejected(journal(tabs: [deep])))
        #expect(rejected(journal(tabs: [["title": String(repeating: "x", count: LayoutJournal.maxString + 1)]])))
        let manyPanes = (0...LayoutJournal.maxPanes).map { _ in leaf }
        #expect(rejected(journal(tabs: [["leaves": manyPanes]])))
        #expect(rejected(Data(count: LayoutJournal.maxFileBytes + 1)))
    }

    @Test func aReplacementIsWholeOrNotAtAll() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("journal.json")
        try LayoutJournal.atomicWrite(Data("old".utf8), to: url)
        try LayoutJournal.atomicWrite(Data("new".utf8), to: url)
        #expect(try Data(contentsOf: url) == Data("new".utf8))
        var st = stat()
        #expect(stat(url.path, &st) == 0 && st.st_mode & 0o777 == 0o600)
        // A write that cannot complete leaves the previous file.
        chmod(dir.path, 0o500)
        defer { chmod(dir.path, 0o700) }
        #expect(throws: (any Error).self) { try LayoutJournal.atomicWrite(Data("lost".utf8), to: url) }
        #expect(try Data(contentsOf: url) == Data("new".utf8))
        // No temporary file is left behind.
        chmod(dir.path, 0o700)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["journal.json"])
    }

    @Test func theLaunchRecordReadsAsWhatHappened() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(LayoutJournal.readLaunch(in: dir).state == .firstRun)
        try LayoutJournal.writeLaunch(.init(state: .clean, journalGeneration: 7), in: dir)
        #expect(LayoutJournal.readLaunch(in: dir) == .init(state: .clean, journalGeneration: 7))
        // A damaged launch record is not a clean quit.
        try Data("garbage".utf8).write(to: dir.appendingPathComponent("launch.json"))
        #expect(LayoutJournal.readLaunch(in: dir).state == .dirty)
    }

    @Test func aJournalCountsOnlyAsTheGenerationTheLaunchRecordNames() {
        let data = journal(tabs: [tab()])         // generation 3
        #expect(LayoutJournal.check(data, expected: 3).0 == .valid)
        if case .invalid = LayoutJournal.check(data, expected: 4).0 {} else { Issue.record("a newer record accepted an older file") }
        if case .invalid = LayoutJournal.check(data, expected: 2).0 {} else { Issue.record("an older record accepted a newer file") }
        #expect(LayoutJournal.check(nil, expected: 3).0 == .missing)
        // And only a valid, matching journal ever makes the journal the source.
        #expect(LayoutJournal.decide(previous: .dirty, journal: LayoutJournal.check(data, expected: 4).0) == .appKit)
        #expect(LayoutJournal.decide(previous: .dirty, journal: LayoutJournal.check(data, expected: 3).0) == .journal)
    }

    private func layout(_ tabs: Int) -> LayoutJournal.Journal {
        LayoutJournal.Journal(generation: 0, windows: [LayoutJournal.Window(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600), isKey: true, selectedTab: 0,
            tabs: (0..<tabs).map { _ in tab() })])
    }

    @Test func aFailedWriteChangesNothingAndIsTriedAgain() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { chmod(dir.path, 0o700); try? FileManager.default.removeItem(at: dir) }
        let c = JournalCommitter(directory: dir, generation: 0, state: .dirty)
        #expect(c.commit(layout(1)))
        #expect(c.generation == 1)
        // The disk refuses: nothing advances.
        let two = layout(2)   // one value: the retry is the same layout
        chmod(dir.path, 0o500)
        #expect(!c.commit(two))
        #expect(c.generation == 1)
        #expect(LayoutJournal.readLaunch(in: dir).journalGeneration == 1)
        // The disk is back: the same layout is written, not skipped as known.
        chmod(dir.path, 0o700)
        #expect(c.commit(two))
        #expect(c.generation == 2)
        let named = LayoutJournal.readLaunch(in: dir)
        let (read, j) = LayoutJournal.check(try Data(contentsOf: dir.appendingPathComponent(LayoutJournal.journalName(named.journalGeneration))),
                                            expected: named.journalGeneration)
        #expect(read == .valid && j?.windows.first?.tabs.count == 2)
        // The previous generation's file is gone; only the named one remains.
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["journal-2.json", "launch.json"])
    }

    @Test func aQuitWhoseLastWriteFailedIsNotClean() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { chmod(dir.path, 0o700); try? FileManager.default.removeItem(at: dir) }
        let c = JournalCommitter(directory: dir, generation: 0, state: .dirty)
        #expect(c.setState(.dirty))
        #expect(c.commit(layout(1)))
        let three = layout(3)
        chmod(dir.path, 0o500)
        #expect(!c.finish(three))
        chmod(dir.path, 0o700)
        let record = LayoutJournal.readLaunch(in: dir)
        #expect(record.state == .dirty && record.journalGeneration == 1)
        // The next launch follows the last journal that was written.
        let (read, _) = LayoutJournal.check(try Data(contentsOf: dir.appendingPathComponent(LayoutJournal.journalName(1))), expected: 1)
        #expect(LayoutJournal.decide(previous: record.state, journal: read) == .journal)
        // A final write that succeeds is clean.
        #expect(c.finish(three))
        #expect(LayoutJournal.readLaunch(in: dir).state == .clean)
    }

    @Test func oneBadTabRejectsTheWholeJournal() {
        let good = journal(tabs: [tab(), tab()])
        #expect(LayoutJournal.check(good, expected: 3).0 == .valid)
        // One tab right, one with a pane whose id is not a UUID, one empty.
        let noPanes: [String: Any] = ["surfaceTree": ["version": 1]]
        for bad in [tab(["leaf": ["view": ["id": "not-a-uuid"]]]), [String: Any](), noPanes] {
            let data = journal(tabs: [tab(), bad])
            if case .invalid = LayoutJournal.check(data, expected: 3).0 {} else { Issue.record("accepted \(bad)") }
        }
    }

    @Test func aRunIsDirtyOnlyOnceItsLayoutIsWritten() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { chmod(dir.path, 0o700); try? FileManager.default.removeItem(at: dir) }
        // After a clean quit: the journal is written first, still under `clean`.
        let c = JournalCommitter(directory: dir, generation: 0, state: .clean)
        let restored = layout(2)
        chmod(dir.path, 0o500)
        #expect(!(c.commit(restored) && c.setState(.dirty)))
        chmod(dir.path, 0o700)
        // Nothing written, nothing armed: a crash now is still AppKit's.
        #expect(LayoutJournal.readLaunch(in: dir).state == .firstRun)
        #expect(c.commit(restored))
        let mid = LayoutJournal.readLaunch(in: dir)
        #expect(mid.state == .clean)          // a crash here: AppKit again
        #expect(LayoutJournal.decide(previous: mid.state, journal: .valid) == .appKit)
        #expect(c.setState(.dirty))
        let armed = LayoutJournal.readLaunch(in: dir)
        let (read, j) = LayoutJournal.check(try Data(contentsOf: dir.appendingPathComponent(LayoutJournal.journalName(armed.journalGeneration))),
                                            expected: armed.journalGeneration)
        // A crash from here restores the full layout, never an empty one.
        #expect(LayoutJournal.decide(previous: armed.state, journal: read) == .journal)
        #expect(j?.windows.first?.tabs.count == 2)
    }

    @Test func generationsACrashLeftBehindAreRemovedByTheNextCommit() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // A crash after launch.json named 6, before journal-5 was removed;
        // and an older leftover. Plus files that are not journals.
        for name in ["journal-4.json", "journal-5.json", "journal-6.json", "journal-x.json", "notes.txt"] {
            try Data("{}".utf8).write(to: dir.appendingPathComponent(name))
        }
        try LayoutJournal.writeLaunch(.init(state: .dirty, journalGeneration: 6), in: dir)
        let c = JournalCommitter(directory: dir, generation: 6, state: .dirty)
        #expect(c.commit(layout(1)))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
            == ["journal-7.json", "journal-x.json", "launch.json", "notes.txt"])
    }

    @Test func aQuitThatKeepsWindowsRestoresFromTheJournal() {
        typealias J = LayoutJournal
        // Every tab and split as they were, not AppKit's view of them.
        #expect(J.decide(previous: .clean, journal: .valid, keepsWindows: true) == .journal)
        // A quit that closes windows restores none from the journal either.
        #expect(J.decide(previous: .clean, journal: .valid, keepsWindows: false) == .appKit)
        // Nothing to trust, or nothing saved yet: AppKit, whatever the setting.
        #expect(J.decide(previous: .clean, journal: .invalid("x"), keepsWindows: true) == .appKit)
        #expect(J.decide(previous: .clean, journal: .missing, keepsWindows: true) == .appKit)
        #expect(J.decide(previous: .firstRun, journal: .valid, keepsWindows: true) == .appKit)
        // After a crash the journal wins, however the quit is set.
        #expect(J.decide(previous: .dirty, journal: .valid, keepsWindows: false) == .journal)
    }
}

