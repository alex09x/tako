import Foundation
import Testing
@testable import Tako

@Suite
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
        let data = journal(tabs: [leaf])          // generation 3
        #expect(LayoutJournal.check(data, expected: 3).0 == .valid)
        if case .invalid = LayoutJournal.check(data, expected: 4).0 {} else { Issue.record("a newer record accepted an older file") }
        if case .invalid = LayoutJournal.check(data, expected: 2).0 {} else { Issue.record("an older record accepted a newer file") }
        #expect(LayoutJournal.check(nil, expected: 3).0 == .missing)
        // And only a valid, matching journal ever makes the journal the source.
        #expect(LayoutJournal.decide(previous: .dirty, journal: LayoutJournal.check(data, expected: 4).0) == .appKit)
        #expect(LayoutJournal.decide(previous: .dirty, journal: LayoutJournal.check(data, expected: 3).0) == .journal)
    }
}

