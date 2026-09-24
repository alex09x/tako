import Testing
import AppKit
@testable import Tako

/// Covers `save`, `frame(for:)`, `pruneCapacity`, and the notification-driven
/// `onScreensChanged` path of `QuickTerminalScreenStateCache`. The base
/// `isValid(for:)` geometry check already has its own coverage in
/// swift/Tests/TakoTests/QuickTerminalScreenStateCacheTests.swift.
@MainActor
struct QuickTerminalScreenStateCacheBehaviorTests {
    private typealias DisplayEntry = QuickTerminalScreenStateCache.DisplayEntry

    @Test func saveThenFrameRoundTripsForTheRealMainScreen() throws {
        let screen = try #require(NSScreen.main)
        let cache = QuickTerminalScreenStateCache()
        let rect = NSRect(x: 10, y: 20, width: 640, height: 480)
        cache.save(frame: rect, for: screen)

        guard screen.displayUUID != nil else {
            // Environments without a stable CoreGraphics display UUID (rare,
            // e.g. some virtual displays) make `save` a documented no-op.
            #expect(cache.frame(for: screen) == nil)
            return
        }
        #expect(cache.frame(for: screen) == rect)
    }

    @Test func savingTwiceKeepsTheMostRecentFrame() throws {
        let screen = try #require(NSScreen.main)
        try #require(screen.displayUUID != nil)
        let cache = QuickTerminalScreenStateCache()
        cache.save(frame: NSRect(x: 0, y: 0, width: 100, height: 100), for: screen)
        let latest = NSRect(x: 5, y: 5, width: 200, height: 200)
        cache.save(frame: latest, for: screen)
        #expect(cache.frame(for: screen) == latest)
    }

    @Test func frameDropsAndRemovesAnEntryWhoseGeometryNoLongerMatches() throws {
        let screen = try #require(NSScreen.main)
        let uuid = try #require(screen.displayUUID)
        let stale = DisplayEntry(
            frame: NSRect(x: 0, y: 0, width: 1, height: 1),
            screenSize: CGSize(width: 1, height: 1),
            scale: screen.backingScaleFactor,
            lastSeen: Date())
        let cache = QuickTerminalScreenStateCache(stateByDisplay: [uuid: stale])
        #expect(cache.stateByDisplay[uuid] != nil)

        #expect(cache.frame(for: screen) == nil)
        #expect(cache.stateByDisplay[uuid] == nil)
    }

    @Test func saveKeepsAtMostTenEntriesEvictingTheOldestFirst() throws {
        let screen = try #require(NSScreen.main)
        try #require(screen.displayUUID != nil)

        var seed: [UUID: DisplayEntry] = [:]
        for i in 0..<12 {
            seed[UUID()] = DisplayEntry(
                frame: .zero,
                screenSize: CGSize(width: 100, height: 100),
                scale: 1,
                lastSeen: Date(timeIntervalSince1970: Double(i)))
        }
        let cache = QuickTerminalScreenStateCache(stateByDisplay: seed)
        #expect(cache.stateByDisplay.count == 12)

        // This save both adds a 13th (freshest) entry and triggers the prune.
        cache.save(frame: NSRect(x: 0, y: 0, width: 1, height: 1), for: screen)

        #expect(cache.stateByDisplay.count == 10)
        // The entry we just touched is the newest and must survive the prune.
        #expect(cache.frame(for: screen) != nil)
    }

    @Test func screenParametersChangeRefreshesLastSeenForAStillValidPresentEntry() throws {
        let screen = try #require(NSScreen.main)
        let uuid = try #require(screen.displayUUID)
        let old = Date(timeIntervalSince1970: 0)
        let matching = DisplayEntry(
            frame: NSRect(x: 1, y: 2, width: 3, height: 4),
            screenSize: screen.frame.size,
            scale: screen.backingScaleFactor,
            lastSeen: old)
        let cache = QuickTerminalScreenStateCache(stateByDisplay: [uuid: matching])

        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)

        let refreshed = try #require(cache.stateByDisplay[uuid])
        #expect(refreshed.lastSeen > old)
        #expect(refreshed.frame == matching.frame)
    }

    @Test func screenParametersChangeRemovesAPresentEntryThatNoLongerMatchesGeometry() throws {
        let screen = try #require(NSScreen.main)
        let uuid = try #require(screen.displayUUID)
        let invalid = DisplayEntry(
            frame: .zero,
            screenSize: CGSize(width: 1, height: 1),
            scale: screen.backingScaleFactor,
            lastSeen: Date())
        let cache = QuickTerminalScreenStateCache(stateByDisplay: [uuid: invalid])

        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)

        #expect(cache.stateByDisplay[uuid] == nil)
    }

    @Test func screenParametersChangePrunesStaleAbsentEntriesButKeepsFreshOnes() {
        let staleAbsent = UUID()
        let freshAbsent = UUID()
        let farPast = Date().addingTimeInterval(-15 * 24 * 60 * 60)
        let recentPast = Date().addingTimeInterval(-1 * 24 * 60 * 60)
        let cache = QuickTerminalScreenStateCache(stateByDisplay: [
            staleAbsent: DisplayEntry(frame: .zero, screenSize: .zero, scale: 1, lastSeen: farPast),
            freshAbsent: DisplayEntry(frame: .zero, screenSize: .zero, scale: 1, lastSeen: recentPast),
        ])

        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)

        #expect(cache.stateByDisplay[staleAbsent] == nil)
        #expect(cache.stateByDisplay[freshAbsent] != nil)
    }
}
