import AppKit
import Combine
import Foundation

/// One terminal a search covers: its engine, and how to tell it apart from
/// the others. Built on the main thread; only `core` is used off it.
struct CrossSearchTarget: @unchecked Sendable {
    let surfaceID: UUID
    let core: TakoCore
    /// Window title and tab position, e.g. "~/src -- tab 2 of 3".
    let place: String
    /// "pane 2 of 3" when the tab is split, nil otherwise.
    let pane: String?
    /// The directory the shell is in now. Not where a found line was printed.
    let currentDirectory: String?
}

/// A hit, and which terminal it is in -- by id, so a closed tab is not kept
/// alive by the list that found it.
struct CrossSearchResult: Identifiable, Equatable {
    let id = UUID()
    let surfaceID: UUID
    let hit: FfiSearchHit
    let place: String
    let pane: String?
    let currentDirectory: String?

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
}

/// Search across every open terminal, for the Find in All Tabs panel.
///
/// The work is the engine's: bounded steps (`TakoCore.searchChunk`) run off
/// the main thread, each holding a terminal only briefly, and a newer query
/// cancels the one in flight between steps. Nothing is written anywhere.
@MainActor
final class CrossSessionSearch: ObservableObject {
    enum Status: Equatable {
        case idle
        case searching
        /// `more`: at least one match past the limit was actually found.
        case done(more: Bool)
    }

    /// Matches shown at most, across all terminals.
    static let limit = 500
    /// Rows one step reads before letting the terminal go.
    static let rowsPerStep: UInt32 = 2_000

    @Published var query = "" {
        didSet { if query != oldValue { schedule() } }
    }
    @Published private(set) var results: [CrossSearchResult] = []
    @Published private(set) var status: Status = .idle
    /// Said when a chosen result could not be shown.
    @Published private(set) var notice: String?

    /// The terminals to search; tests substitute their own.
    var targets: () -> [CrossSearchTarget] = CrossSessionSearch.openTerminals
    /// How long typing must pause before a search starts.
    var debounce: Duration = .milliseconds(150)

    private var task: Task<Void, Never>?

    /// How long a revealed pane gets to take focus before the match is
    /// checked and selected. TAKO_FIND_ALL_SETTLE (seconds) lengthens it so
    /// an end-to-end test can change the output inside that window.
    nonisolated static var settle: TimeInterval {
        ProcessInfo.processInfo.environment["TAKO_FIND_ALL_SETTLE"].flatMap(Double.init) ?? 0.15
    }

    /// Every terminal in every terminal window, labelled for the list.
    static func openTerminals() -> [CrossSearchTarget] {
        var targets: [CrossSearchTarget] = []
        for controller in TerminalController.all {
            let surfaces = Array(controller.surfaceTree)
            let window = controller.window
            let tabs = window.map { Tako.CustomTabGroup.group(for: $0).windows } ?? []
            let tabIndex = window.flatMap { w in tabs.firstIndex(where: { $0 === w }) }
            let title = window?.title.isEmpty == false ? window!.title : "Terminal"
            let place = tabs.count > 1 && tabIndex != nil
                ? "\(title) -- tab \(tabIndex! + 1) of \(tabs.count)" : title
            for (i, surface) in surfaces.enumerated() {
                targets.append(CrossSearchTarget(
                    surfaceID: surface.id,
                    core: surface.core,
                    place: place,
                    pane: surfaces.count > 1 ? "pane \(i + 1) of \(surfaces.count)" : nil,
                    currentDirectory: surface.pwd))
            }
        }
        return targets
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// Searches again for the current query, against the terminals as they
    /// are now -- when the panel opens, so a list from last time is not shown
    /// as if it were current.
    func refresh() {
        schedule(keepNotice: true)
    }

    private func schedule(keepNotice: Bool = false) {
        cancel()
        if !keepNotice { notice = nil }
        let needle = query
        guard !needle.isEmpty else {
            results = []
            status = .idle
            return
        }
        status = .searching
        let targets = targets()
        let debounce = debounce
        task = Task { [weak self] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            let found = await Self.search(needle, in: targets)
            guard !Task.isCancelled, let self, self.query == needle, let found else { return }
            self.results = found.results
            self.status = .done(more: found.more)
        }
    }

    /// Runs the search off the main thread. Nil when cancelled. Asks each
    /// step for one hit more than room is left for, so `more` is only ever
    /// said about a match that exists.
    nonisolated static func search(
        _ needle: String,
        in targets: [CrossSearchTarget],
        onStep: (@Sendable () -> Void)? = nil
    ) async -> (results: [CrossSearchResult], more: Bool)? {
        // The work is a detached task, which does not inherit cancellation:
        // pass it on, so a replaced query stops scanning between steps.
        let worker = Task.detached(priority: .userInitiated) { () -> (results: [CrossSearchResult], more: Bool)? in
            var results: [CrossSearchResult] = []
            var more = false
            for (index, target) in targets.enumerated() {
                var before: UInt64?
                repeat {
                    if Task.isCancelled { return nil }
                    onStep?()
                    let room = Self.limit - results.count
                    let chunk = target.core.searchChunk(
                        needle: needle, before: before,
                        maxRows: Self.rowsPerStep, maxHits: UInt32(room + 1))
                    var hits = chunk.hits
                    if hits.count > room || chunk.truncated {
                        more = true
                        hits = Array(hits.prefix(room))
                    }
                    results += hits.map {
                        CrossSearchResult(
                            surfaceID: target.surfaceID, hit: $0, place: target.place,
                            pane: target.pane, currentDirectory: target.currentDirectory)
                    }
                    before = chunk.nextBefore
                } while before != nil && !more
                if more { break }
                if results.count == Self.limit {
                    guard let left = Self.anyMatch(needle, in: targets[(index + 1)...]) else { return nil }
                    more = left
                    break
                }
            }
            return (results, more)
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    /// Whether any of `targets` holds a match; stops at the first. Nil when
    /// cancelled.
    nonisolated private static func anyMatch(
        _ needle: String, in targets: ArraySlice<CrossSearchTarget>
    ) -> Bool? {
        for target in targets {
            var before: UInt64?
            repeat {
                if Task.isCancelled { return nil }
                let chunk = target.core.searchChunk(needle: needle, before: before, maxRows: rowsPerStep, maxHits: 1)
                if !chunk.hits.isEmpty { return true }
                before = chunk.nextBefore
            } while before != nil
        }
        return false
    }

    /// Shows `result` in its terminal: brings its window and tab forward,
    /// focuses its pane, then -- once the pane has focus -- checks the match
    /// and selects it under one hold of the terminal. `done` gets whether it
    /// was selected; when it was not (the terminal closed, the line changed)
    /// a notice says so and the list is searched again. Nothing else is ever
    /// selected in its place.
    func reveal(
        _ result: CrossSearchResult,
        settle: TimeInterval = CrossSessionSearch.settle,
        done: @escaping @MainActor (Bool) -> Void = { _ in }
    ) {
        let needle = query
        guard let surface = Self.surface(withID: result.surfaceID) else {
            fail("That terminal has been closed.", done)
            return
        }
        guard surface.core.searchHitIsCurrent(needle: needle, hit: result.hit) else {
            fail("That output has changed since the search; the list is updated.", done)
            return
        }
        NotificationCenter.default.post(name: Tako.Notification.takoPresentTerminal, object: surface)
        // The pane takes focus after a short delay (see
        // `takoDidPresentTerminal`); select after it.
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) { [weak self] in
            MainActor.assumeIsolated {
                // Looked up again, not kept: a closed tab's surface can live
                // on (its undo keeps it) without being in any window.
                guard let surface = Self.surface(withID: result.surfaceID) else {
                    self?.failVisibly("That terminal has been closed.", in: NSApp.keyWindow, done)
                    return
                }
                guard surface.selectSearchHit(needle: needle, hit: result.hit) else {
                    self?.failVisibly(
                        "That output has changed since the search; the list is updated.",
                        in: surface.window, done)
                    return
                }
                done(true)
            }
        }
    }

    /// A failure found after the target's tab was brought forward: the panel
    /// that asked may be in a tab now hidden, so the panel is shown, with the
    /// notice, in the window that is in front.
    private func failVisibly(_ message: String, in window: NSWindow?, _ done: @MainActor (Bool) -> Void) {
        fail(message, done)
        (window?.windowController as? BaseTerminalController)?.findAllIsShowing = true
    }

    private func fail(_ message: String, _ done: @MainActor (Bool) -> Void) {
        schedule()
        notice = message
        done(false)
    }

    private static func surface(withID id: UUID) -> Tako.SurfaceView? {
        for controller in TerminalController.all {
            if let surface = controller.surfaceTree.first(where: { $0.id == id }) { return surface }
        }
        return nil
    }
}

/// What a result list says about the command that printed a match, taken
/// only from what the shell reported (OSC 133, OSC 7) and the host's clock.
/// Nothing is inferred from screen text.
struct CommandHeading: Equatable {
    /// Which command, in which engine generation: ids restart after an
    /// import, so the id alone could join two different commands.
    struct Key: Hashable {
        let surfaceID: UUID
        let epoch: UInt64
        let id: UInt64
    }

    enum Outcome: Equatable {
        case running
        case succeeded
        case failed(Int32)
        /// The shell said it ended but sent no exit status: not a success.
        case endedWithoutStatus
        /// A new prompt came before the shell said it ended.
        case interrupted
    }

    let key: Key
    /// The command line as typed; nil when the shell did not mark it.
    let commandLine: String?
    let outcome: Outcome
    let directory: String?
    let startedAt: Date?

    init(surfaceID: UUID, info: FfiCommandInfo) {
        key = Key(surfaceID: surfaceID, epoch: info.epoch, id: info.id)
        commandLine = info.input.map { line in
            let first = line.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? line
            return first != line || info.inputTruncated ? first + " …" : first
        }
        if info.running {
            outcome = .running
        } else if info.abandoned {
            outcome = .interrupted
        } else if let code = info.exitCode {
            outcome = code == 0 ? .succeeded : .failed(code)
        } else {
            outcome = .endedWithoutStatus
        }
        directory = info.cwd.map { URL(string: $0)?.path ?? $0 }.flatMap { $0.isEmpty ? nil : $0 }
        startedAt = info.startedAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }

    var title: String {
        commandLine.map { "$ \($0)" } ?? "Command (command line not reported)"
    }

    var outcomeText: String {
        switch outcome {
        case .running: return "running"
        case .succeeded: return "✓ exit 0"
        case .failed(let code): return "✗ exit \(code)"
        case .endedWithoutStatus: return "ended, no exit status"
        case .interrupted: return "no end reported"
        }
    }

    /// Status, directory and start time, as far as they are known.
    func details(now: Date = Date()) -> String {
        var parts = [outcomeText]
        if let directory { parts.append(directory) }
        if let startedAt {
            let formatter = DateFormatter()
            formatter.dateStyle = Calendar.current.isDate(startedAt, inSameDayAs: now) ? .none : .short
            formatter.timeStyle = .short
            parts.append("started \(formatter.string(from: startedAt))")
        }
        return parts.joined(separator: " · ")
    }
}

extension CrossSearchResult {
    /// The command that printed this match, when the shell marked one.
    var command: CommandHeading? {
        hit.command.map { CommandHeading(surfaceID: surfaceID, info: $0) }
    }
}
