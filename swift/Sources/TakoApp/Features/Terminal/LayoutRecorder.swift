import AppKit
import OSLog

/// Keeps the layout journal current while Tako runs, and rebuilds windows
/// from it after a run that did not end cleanly. See `LayoutJournal`.
@MainActor
enum LayoutRecorder {
    /// Where this launch's windows come from; decided once, before AppKit
    /// restores anything.
    private(set) static var source: LayoutJournal.Source = .appKit
    /// Every write goes through this, on `io` only.
    private static var committer: JournalCommitter?
    private static var pending: LayoutJournal.Journal?
    private static var timer: Timer?
    private static let io = DispatchQueue(label: "tako.layout-journal")
    /// How many windows AppKit's restoration was asked to rebuild this
    /// launch -- zero whenever the journal is the source.
    static var appKitRestoreCalls = 0

    /// How often the layout is checked for changes; a change is written
    /// within this, and only a change is written. A failed write is tried
    /// again on the next check.
    static let interval: TimeInterval = 0.5

    /// When the app delegate is created, before AppKit restores windows.
    static func begin(bundleID: String, enabled: Bool, keepsWindows: Bool) {
        guard enabled else { return }
        let dir: URL
        do { dir = try LayoutJournal.directory(bundleID: bundleID) } catch {
            AppDelegate.logger.error("layout journal off: \(String(describing: error), privacy: .public)")
            return
        }
        let previous = LayoutJournal.readLaunch(in: dir)
        let named = dir.appendingPathComponent(LayoutJournal.journalName(previous.journalGeneration))
        let (read, journal) = LayoutJournal.check(try? Data(contentsOf: named),
                                                  expected: previous.journalGeneration)
        source = LayoutJournal.decide(previous: previous.state, journal: read, keepsWindows: keepsWindows)
        if case .invalid(let why) = read, previous.state != .clean {
            AppDelegate.logger.error("layout journal unusable, AppKit restores instead: \(why, privacy: .public)")
        }
        let c = JournalCommitter(directory: dir, generation: previous.journalGeneration, state: previous.state)
        committer = c
        if source == .journal {
            pending = journal
            // AppKit stays out of it entirely: a restore from the journal
            // never mixes its windows with AppKit's.
            var args = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            args["ApplePersistenceIgnoreState"] = true
            UserDefaults.standard.setVolatileDomain(args, forName: UserDefaults.argumentDomain)
            io.sync { _ = c.setState(.restoring) }
        }
        // On the AppKit path nothing is written yet: the run becomes `dirty`
        // -- and its journal the one a crash restores -- only once the
        // windows AppKit restored are in it (see `arm`). Until then a crash
        // leaves the previous record, and AppKit restores again.
    }

    /// At `applicationDidFinishLaunching`: build the journal's windows, if it
    /// is the source, then start recording.
    static func finishLaunching(app: Tako.App) {
        guard let c = committer else { return }
        if source == .journal, let journal = pending {
            restore(journal, app: app)
            // AppKit is kept from restoring, not from saving: without this
            // the next normal quit would save nothing and lose the layout.
            var args = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
            args.removeValue(forKey: "ApplePersistenceIgnoreState")
            UserDefaults.standard.setVolatileDomain(args, forName: UserDefaults.argumentDomain)
            // Still not clean: a crash from here restores from the journal again.
            io.sync { _ = c.setState(.dirty) }
            armed = true
        } else {
            // AppKit has restored its windows by now: record them, in full,
            // before anything says a crash should come back to the journal.
            let now = capture()
            armed = io.sync { arm(c, with: now) }
        }
        pending = nil
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { record() }
        }
    }

    /// At `applicationWillTerminate`, after snapshots and session detach.
    /// `clean` only if the final layout is on disk; otherwise the state
    /// stays dirty and the next launch uses the last journal that was.
    static func finish() {
        guard let c = committer else { return }
        timer?.invalidate()
        timer = nil
        let final = capture()
        let clean = io.sync { c.finish(final) }
        if !clean {
            AppDelegate.logger.error("final layout not written; this quit is not recorded as clean")
        }
    }

    /// Writes the layout if it changed since the last successful write, and
    /// arms crash recovery once a full layout is on disk.
    static func record() {
        guard let c = committer else { return }
        let journal = capture()
        let wasArmed = armed
        io.async {
            if wasArmed {
                c.commit(journal)
            } else if arm(c, with: journal) {
                DispatchQueue.main.async { armed = true }
            }
        }
    }

    /// True once the journal holds this run's layout and the run is `dirty`
    /// -- from here a crash restores from the journal.
    private static var armed = false

    /// On `io`: commit `journal`, and only if that succeeded mark the run
    /// dirty. A failed commit leaves the previous record -- clean, or a
    /// journal AppKit's fallback already distrusts -- and is tried again.
    nonisolated private static func arm(_ c: JournalCommitter, with journal: LayoutJournal.Journal) -> Bool {
        c.commit(journal) && c.setState(.dirty)
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
        return LayoutJournal.Journal(generation: 0, windows: windows)
    }

    // MARK: - Restoring

    private static func restore(_ journal: LayoutJournal.Journal, app: Tako.App) {
        let decoder = JSONDecoder()
        var keyWindow: NSWindow?
        for entry in journal.windows {
            var anchor: NSWindow?
            var selected: NSWindow?
            for (index, tab) in entry.tabs.enumerated() {
                // Every tab was checked to decode before this journal was
                // chosen; a failure here would be a bug, not damage.
                guard let data = try? JSONSerialization.data(withJSONObject: tab),
                      let state = try? decoder.decode(TerminalRestorableState.self, from: data) else {
                    AppDelegate.logger.fault("layout journal: a checked tab did not decode")
                    continue
                }
                let controller = TerminalController(app, withSurfaceTree: state.surfaceTree)
                guard let window = controller.window else { continue }
                controller.titleOverride = state.titleOverride
                if let tabId = state.tabIdentifier { window.stableTabIdentifier = tabId }
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
