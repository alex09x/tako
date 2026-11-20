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

private func core(_ text: String, cols: UInt32 = 40, rows: UInt32 = 5) -> TakoCore {
    let core = TakoCore(cols: cols, rows: rows)
    core.feed(bytes: Data(text.utf8))
    return core
}

private func target(_ core: TakoCore, _ place: String, pane: String? = nil) -> CrossSearchTarget {
    CrossSearchTarget(surfaceID: UUID(), core: core, place: place, pane: pane, currentDirectory: nil)
}

/// Polls with the main actor free, so the search's own main-actor work
/// can run in between -- a spun run loop would hold it.
@MainActor
private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<250 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

/// Counts steps from the search's worker thread.
private final class StepCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

@Suite
@MainActor
struct CrossSessionSearchTests {
    @Test func findsInEveryTerminalNewestFirstWithinEach() async throws {
        let a = target(core("build failed\r\nok\r\nbuild failed again"), "tab 1")
        let b = target(core("nothing here"), "tab 2")
        let c = target(core("BUILD FAILED"), "tab 3", pane: "pane 2 of 2")

        let found = try #require(await CrossSessionSearch.search("build failed", in: [a, b, c]))

        #expect(found.results.map { $0.hit.before + $0.hit.matched + $0.hit.after }
            == ["build failed again", "build failed", "BUILD FAILED"])
        #expect(found.results.map(\.hit.matched) == ["build failed", "build failed", "BUILD FAILED"])
        #expect(found.results.map(\.place) == ["tab 1", "tab 1", "tab 3"])
        #expect(found.results.last?.pane == "pane 2 of 2")
        #expect(!found.more)
    }

    @Test func moreIsSaidOnlyWhenAMatchPastTheLimitExists() async throws {
        let limit = CrossSessionSearch.limit
        // Exactly the limit, split over two terminals: nothing more.
        let half = String(repeating: "x\r\n", count: limit / 2)
        let exact = try #require(await CrossSessionSearch.search(
            "x", in: [target(core(half, rows: 2), "1"), target(core(half, rows: 2), "2")]))
        #expect(exact.results.count == limit)
        #expect(!exact.more)

        // One more, in a third terminal searched after the limit was reached.
        let extra = try #require(await CrossSessionSearch.search(
            "x", in: [target(core(half, rows: 2), "1"), target(core(half, rows: 2), "2"),
                      target(core("x"), "3")]))
        #expect(extra.results.count == limit)
        #expect(extra.more)
    }

    @Test func aNewQueryReplacesTheOneInFlight() async {
        let search = CrossSessionSearch()
        let t = target(core("alpha\r\nbeta"), "tab")
        search.targets = { [t] }
        search.debounce = .zero

        search.query = "alpha"
        search.query = "beta"

        #expect(await eventually { search.status == .done(more: false) })
        #expect(search.results.map(\.hit.matched) == ["beta"])
    }

    @Test func changingTheQueryClearsMatchesForItsPrefix() async throws {
        let terminal = core("grp-build two")
        let tab = target(terminal, "tab")
        let search = CrossSessionSearch()
        search.targets = { [tab] }
        search.debounce = .zero
        defer { search.cancel() }
        search.query = "grp"
        try #require(await eventually { search.status == .done(more: false) })
        let prefix = try #require(search.results.first?.hit)
        #expect(prefix.matched == "grp")

        // Both queries show the same excerpt, but the old match has a shorter range.
        search.debounce = .seconds(60)
        search.query = "grp-build"
        #expect(terminal.searchHitIsCurrent(needle: "grp", hit: prefix))
        #expect(!terminal.searchHitIsCurrent(needle: search.query, hit: prefix))
        #expect(search.status == .searching)
        #expect(search.results.isEmpty)

        search.debounce = .zero
        search.refresh()
        try #require(await eventually { search.status == .done(more: false) })
        #expect(search.results.map(\.hit.matched) == ["grp-build"])
    }

    @Test func closingOnePanelDoesNotCancelAnotherPanelsRefresh() async throws {
        let terminal = core("match")
        let tab = target(terminal, "tab")
        let search = CrossSessionSearch()
        let first = UUID()
        let second = UUID()
        search.targets = { [tab] }
        search.debounce = .zero
        search.panelOpened(first)
        defer {
            search.panelClosed(first)
            search.panelClosed(second)
        }
        search.query = "match"
        try #require(await eventually { search.results.count == 1 })

        terminal.feed(bytes: Data("\r\nmatch again".utf8))
        search.panelOpened(second)
        #expect(search.results.count == 1, "the unchanged query retains its results during refresh")
        search.panelClosed(first)

        #expect(await eventually { search.status == .done(more: false) && search.results.count == 2 })
    }

    @Test func anEmptyQueryClearsTheList() async {
        let search = CrossSessionSearch()
        search.targets = { [target(core("alpha"), "tab")] }
        search.debounce = .zero
        search.query = "alpha"
        #expect(await eventually { !search.results.isEmpty })

        search.query = ""

        #expect(search.results.isEmpty)
        #expect(search.status == .idle)
    }

    @Test func aResultInAClosedTerminalIsReportedNotShown() async throws {
        let search = CrossSessionSearch()
        let closedTarget = target(core("x"), "tab")
        search.targets = { [closedTarget] }
        search.debounce = .zero
        defer { search.cancel() }
        search.query = "x"
        try #require(await eventually { search.results.count == 1 })
        let gone = try #require(search.results.first)
        search.targets = { [] }

        var selected: Bool?
        search.reveal(gone) { selected = $0 }

        #expect(selected == false)
        #expect(search.notice == "That terminal has been closed.")
        #expect(search.results.isEmpty)
    }

    @Test func reopeningAfterTheLastPanelClosesDiscardsOldExcerpts() async throws {
        let search = CrossSessionSearch()
        let tab = target(core("previous output"), "tab")
        let first = UUID()
        let second = UUID()
        search.targets = { [tab] }
        search.debounce = .zero
        search.panelOpened(first)
        defer { search.panelClosed(second) }
        search.query = "previous"
        try #require(await eventually { search.results.count == 1 })
        search.panelClosed(first)

        search.targets = { [] }
        search.panelOpened(second)
        #expect(search.results.isEmpty, "the previous panel's excerpts must not remain actionable")
        #expect(await eventually { search.status == .done(more: false) })
    }

    @Test func cancellingStopsAWorkerThatHasStartedScanning() async {
        // Many terminals with long histories: far more steps than run before
        // the cancel lands.
        let history = String(repeating: "line\r\n", count: 5_000)
        let targets = (0..<20).map { target(core(history, rows: 2), "\($0)") }
        let steps = StepCounter()
        let task = Task { await CrossSessionSearch.search("zzz", in: targets, onStep: { steps.bump() }) }
        while steps.count == 0 { await Task.yield() }
        task.cancel()
        let outcome = await task.value

        #expect(outcome == nil)
        // 20 terminals x 3 steps each would be 60; a cancelled one stops early.
        #expect(steps.count < 60)
    }

    @Test func openingThePanelAgainSearchesTheTerminalsAsTheyAreNow() async {
        let search = CrossSessionSearch()
        let c = core("before")
        let t = target(c, "tab")
        search.targets = { [t] }
        search.debounce = .zero
        search.query = "later"
        #expect(await eventually { search.status == .done(more: false) })
        #expect(search.results.isEmpty)

        c.feed(bytes: Data("\r\nlater".utf8))
        search.refresh()

        #expect(await eventually { search.results.count == 1 })
    }

    @Test func selectingAHitSelectsExactlyItsCells() throws {
        let surface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { surface.close() }
        surface.core.feed(bytes: Data("\u{1b}[2J\u{1b}[HОшибка: 漢字 failed\r\n".utf8))
        for (needle, expected) in [("ошибка", "Ошибка"), ("漢字", "漢字"), ("FAILED", "failed")] {
            let hit = try #require(surface.core.searchChunk(
                needle: needle, before: nil, maxRows: 1000, maxHits: 1).hits.first)
            #expect(surface.selectSearchHit(needle: needle, hit: hit))
            #expect(surface.core.selectedText() == expected)
        }
    }

    @Test func aHitScrolledIntoHistoryIsStillSelectedWhereItIs() throws {
        let surface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { surface.close() }
        surface.core.feed(bytes: Data("\u{1b}[2J\u{1b}[Hthe needle\r\n".utf8))
        let hit = try #require(surface.core.searchChunk(
            needle: "needle", before: nil, maxRows: 1000, maxHits: 1).hits.first)
        // Push it far into scrollback.
        surface.core.feed(bytes: Data(String(repeating: "filler\r\n", count: 200).utf8))

        #expect(surface.selectSearchHit(needle: "needle", hit: hit))
        #expect(surface.core.selectedText() == "needle")
    }

    @Test func aHitThatChangedIsNotSelectedAndNothingElseIs() throws {
        let surface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        defer { surface.close() }
        surface.core.feed(bytes: Data("\u{1b}[2J\u{1b}[Hold text\r\n".utf8))
        let hit = try #require(surface.core.searchChunk(
            needle: "old", before: nil, maxRows: 1000, maxHits: 1).hits.first)
        surface.core.feed(bytes: Data("\u{1b}[2J\u{1b}[Hnew text\r\n".utf8))

        #expect(!surface.selectSearchHit(needle: "old", hit: hit))
        #expect(!surface.core.hasSelection())
    }
}
