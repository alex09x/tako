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

/// "quiet 17h 4m" under a quiet program says how long since it last printed:
/// by the clock, across a restart of Tako, and not reset by Tako's own doing.
@Suite(.serialized) @MainActor
struct QuietSinceTests {
    private func quietCrab(_ clock: @escaping () -> Date, lines: @escaping () -> Int = { 0 },
                           quietSince: Date? = nil) -> Tako.CrabTracker {
        let crab = Tako.CrabTracker(now: clock)
        crab.commandStarted(kind: .quiet, probe: Tako.LiveProbe(takeOutputLines: lines, program: "tail"),
                            quietSince: quietSince)
        return crab
    }

    // MARK: - The clock

    @Test func quietIsCountedByTheClockNotBySamples() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let crab = quietCrab { now }
        // The Mac slept, or App Nap held the timer: ten minutes, one sample.
        now += 600
        crab.sampleLive()
        #expect(crab.live?.quietLabel == "quiet 10m")
    }

    @Test func outputStartsTheQuietOver() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        var printed = 0
        let crab = quietCrab({ now }, lines: { defer { printed = 0 }; return printed })
        now += 120
        printed = 5
        crab.sampleLive()
        now += 300
        crab.sampleLive()
        #expect(crab.live?.quietLabel == "quiet 5m")
    }

    @Test func aHeldBackTimerDoesNotInflateTheRate() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        var printed = 0
        let crab = quietCrab({ now }, lines: { defer { printed = 0 }; return printed })
        // Ten lines a second, sampled every two seconds: twenty a sample.
        for _ in 0..<3 {
            now += 2
            printed = 20
            crab.sampleLive()
        }
        #expect(crab.live?.linesPerSecond == 10)
        #expect(crab.live?.rateLabel == "10/s")
    }

    @Test func outputAfterALongNapShowsItsRateAtOnce() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        var printed = 0
        let crab = quietCrab({ now }, lines: { defer { printed = 0 }; return printed })
        // Ten silent minutes in one held-back sample, then 20 lines a second.
        now += 600
        crab.sampleLive()
        now += 1
        printed = 20
        crab.sampleLive()
        #expect(crab.live?.rateLabel == "10/s")
        now += 2
        printed = 40
        crab.sampleLive()
        #expect(crab.live?.rateLabel == "20/s")
    }

    // MARK: - Across a restart

    @Test func aProgramFoundAfterARestartIsQuietSinceItLastPrinted() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let crab = quietCrab({ now }, quietSince: now - 17 * 3600 - 4 * 60)
        // Right away, before its first sample.
        #expect(crab.live?.quietLabel == "quiet 17h 4m")
        now += 60
        crab.sampleLive()
        #expect(crab.live?.quietLabel == "quiet 17h 5m")
    }

    @Test func aRecordedMomentAheadOfTheClockCountsFromNow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let crab = quietCrab({ now }, quietSince: now + 3600)
        #expect(crab.live?.quietLabel == "quiet")
    }

    @Test func theMomentIsToldOnStartAtMostOnceAMinuteAndClearedAtTheEnd() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        let start = now
        var printed = 0
        var told: [Date?] = []
        let crab = Tako.CrabTracker(now: { now })
        crab.onQuietSince = { told.append($0) }
        crab.commandStarted(kind: .quiet, probe: Tako.LiveProbe(
            takeOutputLines: { defer { printed = 0 }; return printed }, program: "tail"))
        #expect(told == [start])

        now += 10
        printed = 3
        crab.sampleLive()
        #expect(told == [start])

        now += 60
        printed = 3
        crab.sampleLive()
        #expect(told == [start, start + 70])

        crab.commandEnded(exitCode: 0)
        #expect(told == [start, start + 70, nil])
    }

    @Test func aRestartedTakoAdoptsTheProgramWithItsQuiet() {
        _ = NSApplication.shared
        let surface = Tako.SurfaceView(frame: .zero)
        surface.adoptRunningCommand("tail -f /var/log/app.log", quietSince: Date() - 2 * 3600 - 37 * 60 - 5)
        defer { surface.crab.commandEnded(exitCode: 0) }
        #expect(surface.crab.live?.quietLabel == "quiet 2h 37m")
    }

    @Test func aSessionRecordKeepsTheQuietAndAnOlderRecordReadsWithoutIt() throws {
        let dir = URL(fileURLWithPath: "/tmp/tkq-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionRecordStore(directory: dir)
        var record = SessionRecord(id: UUID(), runtimeID: "0.8.1-cc9574e03dfb2480", generation: "g",
                                   state: .attached, createdAt: Date(timeIntervalSince1970: 5))
        record.quietSince = Date(timeIntervalSince1970: 1_000)
        try store.write(record)
        #expect(store.read(record.id) == .record(record))

        // A record an older Tako wrote has no such key.
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: store.url(for: record.id))) as? [String: Any])
        json.removeValue(forKey: "quietSince")
        try JSONSerialization.data(withJSONObject: json).write(to: store.url(for: record.id))
        record.quietSince = nil
        #expect(store.read(record.id) == .record(record))
    }

    @Test func aPaneWithASessionKeepsItsQuietInTheRecord() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/tkq-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ns = try SessionNamespace.open(runtimeID: "0.8.1-cc9574e03dfb2480", home: root)
        let records = SessionRecordStore(directory: root.appendingPathComponent("records"))
        let record = SessionRecord(id: UUID(), runtimeID: "0.8.1-cc9574e03dfb2480", generation: "g",
                                   state: .attached, createdAt: Date())
        try records.write(record)
        let session = SurfaceSession(runtime: root.appendingPathComponent("zmx"), namespace: ns, name: "abc",
                                     owner: try SessionOwnerLock(namespace: ns, name: "abc"),
                                     records: records, record: record)
        // Nothing to end: the session is a stand-in.
        defer { session.ended = true }

        let surface = Tako.SurfaceView(frame: .zero)
        surface.persistence = session
        let since = Date() - 3 * 3600
        surface.adoptRunningCommand("tail -f /var/log/app.log", quietSince: since)
        guard case .record(let kept) = records.read(record.id) else {
            Issue.record("no record")
            return
        }
        #expect(kept.quietSince == since)

        surface.crab.commandEnded(exitCode: 0)
        guard case .record(let ended) = records.read(record.id) else {
            Issue.record("no record")
            return
        }
        #expect(ended.quietSince == nil)
    }

    // MARK: - Tako's own doing

    @Test func aRedrawAfterAResizeIsNotOutput() {
        let meter = Tako.OutputActivityMeter()
        meter.noteResize(at: 10)
        meter.noteOutput(Data("╭──╮\n│  │\n╰──╯\n".utf8), at: 10.9)
        #expect(meter.take() == 0)
        meter.noteOutput(Data("a real line\n".utf8), at: 11.1)
        #expect(meter.take() == 1)
    }
}
