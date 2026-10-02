import AppKit

/// Keeps the layout journal current while Tako runs, and rebuilds windows
/// from it after a run that did not end cleanly. See `LayoutJournal`.
@MainActor
enum LayoutRecorder {
    /// Where this launch's windows come from; decided once, before AppKit
    /// restores anything.
    private(set) static var source: LayoutJournal.Source = .appKit
    private static var directory: URL?
    private static var pending: LayoutJournal.Journal?
    private static var generation: UInt64 = 0
    private static var lastWritten: Data?
    private static var timer: Timer?
    private static let io = DispatchQueue(label: "tako.layout-journal")
    /// The launch state as last written; every journal commit carries it.
    private static var state: LayoutJournal.LaunchState = .dirty
    /// How many windows AppKit's restoration was asked to rebuild this
    /// launch -- zero whenever the journal is the source.
    static var appKitRestoreCalls = 0

    /// How often the layout is checked for changes; a change is written
    /// within this, and only a change is written.
    static let interval: TimeInterval = 0.5

    /// At `applicationWillFinishLaunching`, before AppKit restores windows.
    static func begin(bundleID: String, enabled: Bool) {
        guard enabled else { return }
        let dir: URL
        do { dir = try LayoutJournal.directory(bundleID: bundleID) } catch {
            AppDelegate.logger.error("layout journal off: \(String(describing: error), privacy: .public)")
            return
        }
        directory = dir
        let previous = LayoutJournal.readLaunch(in: dir)
        let named = dir.appendingPathComponent(LayoutJournal.journalName(previous.journalGeneration))
        let (read, journal) = LayoutJournal.check(try? Data(contentsOf: named),
                                                  expected: previous.journalGeneration)
        source = LayoutJournal.decide(previous: previous.state, journal: read)
        if case .invalid(let why) = read, previous.state != .clean {
            AppDelegate.logger.error("layout journal unusable, AppKit restores instead: \(why, privacy: .public)")
        }
        generation = previous.journalGeneration
        state = previous.state
        if source == .journal {
            pending = journal
            // AppKit stays out of it entirely: a crash restore never mixes
            // its windows with AppKit's.
            var args = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            args["ApplePersistenceIgnoreState"] = true
            UserDefaults.standard.setVolatileDomain(args, forName: UserDefaults.argumentDomain)
            state = .restoring
            write(.init(state: .restoring, journalGeneration: generation))
        } else {
            state = .dirty
            write(.init(state: .dirty, journalGeneration: generation))
            if read != .valid {
                // An explicit empty journal: from now on a dirty state with
                // no journal is damage, not a first run.
                commit(LayoutJournal.Journal(generation: generation, windows: []), sync: true)
            }
        }
    }

    /// At `applicationDidFinishLaunching`: build the journal's windows, if it
    /// is the source, then start recording.
    static func finishLaunching(app: Tako.App) {
        guard let dir = directory else { return }
        _ = dir
        if source == .journal, let journal = pending {
            restore(journal, app: app)
            // AppKit is kept from restoring, not from saving: without this
            // the next normal quit would save nothing and lose the layout.
            var args = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            args.removeValue(forKey: "ApplePersistenceIgnoreState")
            UserDefaults.standard.setVolatileDomain(args, forName: UserDefaults.argumentDomain)
            // Still not clean: a crash from here restores from the journal again.
            state = .dirty
            write(.init(state: .dirty, journalGeneration: generation))
        }
        pending = nil
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { record() }
        }
    }

    /// At `applicationWillTerminate`, after snapshots and session detach: the
    /// last layout, written before `clean` is.
    static func finish() {
        guard directory != nil else { return }
        timer?.invalidate()
        timer = nil
        record(sync: true)
        io.sync {}
        state = .clean
        write(.init(state: .clean, journalGeneration: generation))
    }

    // MARK: - Recording

    static func capture() -> LayoutJournal.Journal {
        var groups: [Tako.CustomTabGroup] = []
        for controller in TerminalController.all {
            guard let window = controller.window else { continue }
            let group = Tako.CustomTabGroup.group(for: window)
            if !groups.contains(where: { $0 === group }) { groups.append(group) }
        }
        let encoder = JSONEncoder()
        var windows: [LayoutJournal.Window] = []
        for group in groups {
            let controllers = group.windows.compactMap { $0.windowController as? TerminalController }
            let tabs: [Any] = controllers.compactMap { controller in
                guard let data = try? encoder.encode(TerminalRestorableState(from: controller)) else { return nil }
                return try? JSONSerialization.jsonObject(with: data)
            }
            guard !tabs.isEmpty, let first = controllers.first?.window else { continue }
            let selected = group.selectedWindow.flatMap { s in controllers.firstIndex { $0.window === s } } ?? 0
            windows.append(LayoutJournal.Window(
                frame: first.frame,
                isKey: group.windows.contains { $0.isKeyWindow },
                selectedTab: selected,
                tabs: tabs))
        }
        return LayoutJournal.Journal(generation: generation, windows: windows)
    }

    /// Writes the layout if it changed since the last write.
    static func record(sync: Bool = false) {
        commit(capture(), sync: sync)
    }

    private static func commit(_ journal: LayoutJournal.Journal, sync: Bool) {
        guard let dir = directory else { return }
        var next = journal
        // The generation is not part of what "changed" means.
        next.generation = 0
        guard let body = try? LayoutJournal.encode(next), body != lastWritten else { return }
        lastWritten = body
        let previousGeneration = generation
        generation += 1
        next.generation = generation
        guard let data = try? LayoutJournal.encode(next) else { return }
        let committed = generation
        let launch = LayoutJournal.LaunchRecord(state: state, journalGeneration: committed)
        let work = {
            // The new generation's file whole first, then the record naming
            // it, then the old file: every crash point names a whole file.
            do {
                try LayoutJournal.atomicWrite(data, to: dir.appendingPathComponent(LayoutJournal.journalName(committed)))
                try LayoutJournal.writeLaunch(launch, in: dir)
                unlink(dir.appendingPathComponent(LayoutJournal.journalName(previousGeneration)).path)
            } catch {
                AppDelegate.logger.error("layout journal write failed: \(String(describing: error), privacy: .public)")
            }
        }
        if sync { io.sync(execute: work) } else { io.async(execute: work) }
    }

    private static func write(_ record: LayoutJournal.LaunchRecord) {
        guard let dir = directory else { return }
        io.sync {
            do { try LayoutJournal.writeLaunch(record, in: dir) } catch {
                AppDelegate.logger.error("launch state write failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: - Restoring

    private static func restore(_ journal: LayoutJournal.Journal, app: Tako.App) {
        let decoder = JSONDecoder()
        var keyWindow: NSWindow?
        for entry in journal.windows {
            var anchor: NSWindow?
            var selected: NSWindow?
            for (index, tab) in entry.tabs.enumerated() {
                guard let data = try? JSONSerialization.data(withJSONObject: tab),
                      let state = try? decoder.decode(TerminalRestorableState.self, from: data) else {
                    AppDelegate.logger.error("layout journal: a tab could not be decoded; skipped")
                    continue
                }
                let controller = TerminalController(app, withSurfaceTree: state.surfaceTree)
                guard let window = controller.window else { continue }
                controller.titleOverride = state.titleOverride
                if let color = state.tabColor { (window as? TerminalWindow)?.tabColor = color }
                if let focused = state.focusedSurface,
                   let view = controller.surfaceTree.first(where: { $0.id.uuidString == focused }) {
                    controller.focusedSurface = view
                }
                // As undoing a closed window rebuilds its tabs: shown, then
                // joined to the first, in order.
                controller.showWindow(nil)
                if let anchor {
                    Tako.CustomTabGroup.join(window, to: anchor, select: false)
                } else {
                    window.setFrame(onScreen(entry.frame), display: false)
                    anchor = window
                }
                if index == entry.selectedTab { selected = window }
            }
            if let selected, let anchor {
                Tako.CustomTabGroup.group(for: anchor).select(selected)
                if entry.isKey { keyWindow = selected }
            }
        }
        keyWindow?.makeKeyAndOrderFront(nil)
    }

    /// `frame`, moved onto the main screen when no screen shows it any more.
    static func onScreen(_ frame: CGRect) -> CGRect {
        if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) { return frame }
        guard let main = NSScreen.main?.visibleFrame else { return frame }
        return CGRect(x: main.midX - frame.width / 2, y: main.midY - frame.height / 2,
                      width: min(frame.width, main.width), height: min(frame.height, main.height))
    }
}
