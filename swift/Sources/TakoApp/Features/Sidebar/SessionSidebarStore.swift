import AppKit
import Combine
import Foundation
import TakoKit

/// Manages persistence, state, and item derivation for the session sidebar (B5).
@MainActor
final class SessionSidebarStore: ObservableObject {
    static let shared = SessionSidebarStore()

    static let isShowingKey = "tako.session_sidebar_is_showing"
    static let optInGitKey = "tako.session_sidebar_opt_in_git"
    static let optInPortsKey = "tako.session_sidebar_opt_in_ports"
    static let descriptionsKey = "tako.session_sidebar_descriptions"

    private let defaults: UserDefaults

    /// Whether the session sidebar is open in terminal windows.
    @Published var isShowing: Bool {
        didSet {
            defaults.set(isShowing, forKey: Self.isShowingKey)
            if !isShowing {
                surfaceSubscriptions.removeAll()
                subscribedSurfaceIds.removeAll()
            }
        }
    }

    /// Opt-in: read local git branch and dirty status from working directory.
    /// OFF by default to respect resource and latency budgets.
    @Published var optInGit: Bool {
        didSet {
            defaults.set(optInGit, forKey: Self.optInGitKey)
            gitCache.removeAll()
            objectWillChange.send()
        }
    }

    /// Opt-in: inspect local TCP listening ports for running pane processes.
    /// OFF by default to avoid unnecessary process inspection.
    @Published var optInPorts: Bool {
        didSet {
            defaults.set(optInPorts, forKey: Self.optInPortsKey)
            portsCache.removeAll()
            objectWillChange.send()
        }
    }

    /// Whether the sidebar view is filtered to only items needing attention.
    @Published var filterNeedsAttention: Bool = false

    /// Filter text for title, working directory, or description search.
    @Published var filterText: String = ""

    /// User-editable descriptions keyed by surface ID or window identifier.
    @Published private(set) var descriptions: [String: String] = [:] {
        didSet {
            defaults.set(descriptions, forKey: Self.descriptionsKey)
        }
    }

    private struct CacheEntry<T> {
        let value: T
        let timestamp: Date
    }

    // In-memory TTL caches to avoid redundant filesystem/process inspections during rendering.
    private var gitCache: [String: CacheEntry<LocalGitInspection.GitInfo?>] = [:]
    private var portsCache: [Int: CacheEntry<[Int]>] = [:]
    private let cacheTTL: TimeInterval = 2.0

    private var surfaceSubscriptions: Set<AnyCancellable> = []
    private var subscribedSurfaceIds: Set<UUID> = []

    init(defaults: UserDefaults = .tako) {
        self.defaults = defaults
        self.isShowing = defaults.bool(forKey: Self.isShowingKey)
        self.optInGit = defaults.bool(forKey: Self.optInGitKey)
        self.optInPorts = defaults.bool(forKey: Self.optInPortsKey)
        self.descriptions = defaults.dictionary(forKey: Self.descriptionsKey) as? [String: String] ?? [:]
    }

    /// Invalidates in-memory inspection caches.
    func invalidateCaches() {
        gitCache.removeAll()
        portsCache.removeAll()
    }

    /// Dynamically binds to live surfaces in the tab group to observe status, progress, elapsed, title, and pwd changes in real time.
    func bindSurfaces(for window: NSWindow?) {
        let group = window.flatMap { Tako.CustomTabGroup.group(for: $0) }
        let windows = group?.windows ?? (window.map { [$0] } ?? [])
        let currentSurfaces = windows.flatMap { surfaces(in: $0) }
        let currentIds = Set(currentSurfaces.map(\.id))

        guard currentIds != subscribedSurfaceIds else { return }
        subscribedSurfaceIds = currentIds
        surfaceSubscriptions.removeAll()

        for s in currentSurfaces {
            s.objectWillChange
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &surfaceSubscriptions)
            s.crab.objectWillChange
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.objectWillChange.send() }
                .store(in: &surfaceSubscriptions)
        }
    }

    /// Sets or updates a custom user description for a tab or surface.
    func setDescription(_ text: String, for id: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            descriptions.removeValue(forKey: id)
        } else {
            descriptions[id] = trimmed
        }
    }

    /// Clears a user description.
    func clearDescription(for id: String) {
        descriptions.removeValue(forKey: id)
    }

    /// Retrieves user description for an identifier.
    func description(for id: String) -> String? {
        descriptions[id]
    }

    /// Computes and returns the ordered sidebar items for the given window's tab group.
    func items(for window: NSWindow?) -> [SessionSidebarItem] {
        bindSurfaces(for: window)

        let group = window.flatMap { Tako.CustomTabGroup.group(for: $0) }
        let windows = group?.windows ?? (window.map { [$0] } ?? [])
        let selected = group?.selectedWindow ?? window

        var result: [SessionSidebarItem] = []
        result.reserveCapacity(windows.count)

        for (index, win) in windows.enumerated() {
            let surface = surface(in: win)
            let surfaceId = surface?.id
            let id = surfaceId?.uuidString ?? "\(win.windowNumber)"

            let title = titleFor(window: win, surface: surface)
            let crab = aggregateCrab(for: win)
            let status = crab?.paneStatus ?? .idle
            let crabState = crab?.state ?? .idle
            let elapsed = crab?.elapsedLabel
            let prog = aggregateProgress(for: win)
            let pwd = surface?.pwd

            // Opt-in Git branch and dirty status
            var gitBranch: String?
            var gitDirty: Bool?
            if optInGit, let dir = pwd, !dir.isEmpty {
                if let cached = gitCache[dir], Date().timeIntervalSince(cached.timestamp) < cacheTTL {
                    gitBranch = cached.value?.branch
                    gitDirty = cached.value?.isDirty
                } else {
                    let inspected = LocalGitInspection.inspect(directory: dir)
                    gitCache[dir] = CacheEntry(value: inspected, timestamp: Date())
                    gitBranch = inspected?.branch
                    gitDirty = inspected?.isDirty
                }
            }

            // Opt-in listening ports
            var ports: [Int]?
            if optInPorts, let pty = surface?.pty {
                let pid = pty.foregroundPID ?? Int(pty.child)
                if pid > 0 {
                    if let cached = portsCache[pid], Date().timeIntervalSince(cached.timestamp) < cacheTTL {
                        ports = cached.value
                    } else {
                        let inspected = LocalPortInspection.inspectListeningPorts(pid: pid)
                        portsCache[pid] = CacheEntry(value: inspected, timestamp: Date())
                        ports = inspected
                    }
                }
            }

            // Latest notification text from Track B4
            let latestNotification = surfaceId.flatMap { sid in
                NotificationStore.shared.records.first(where: { $0.surfaceId == sid })?.title
            }

            // User-editable description
            let userDesc = descriptions[id] ?? surfaceId.flatMap { descriptions[$0.uuidString] }

            let unread = surfaceId.map { NotificationStore.shared.unreadCount(for: $0) } ?? 0
            let isSelected = win === selected

            // Needs attention condition
            let needsAttention = !isSelected && (
                status == .error ||
                status == .needsApproval ||
                status == .waitingForInput ||
                unread > 0 ||
                (crab?.unread ?? false)
            )

            let item = SessionSidebarItem(
                id: id,
                surfaceId: surfaceId,
                index: index,
                totalCount: windows.count,
                isSelected: isSelected,
                title: title,
                status: status,
                crabState: crabState,
                progress: prog?.progress.map { Double($0) / 100.0 },
                progressState: prog?.state ?? .none,
                elapsed: elapsed,
                workingDirectory: pwd,
                gitBranch: gitBranch,
                gitDirty: gitDirty,
                latestNotification: latestNotification,
                userDescription: userDesc,
                listeningPorts: ports,
                unreadCount: unread,
                needsAttention: needsAttention
            )

            // Filtering
            if filterNeedsAttention && !item.needsAttention {
                continue
            }

            if !filterText.isEmpty {
                let query = filterText.lowercased()
                let matchesTitle = item.title.lowercased().contains(query)
                let matchesPwd = item.workingDirectory?.lowercased().contains(query) ?? false
                let matchesGit = item.gitBranch?.lowercased().contains(query) ?? false
                let matchesDesc = item.userDescription?.lowercased().contains(query) ?? false
                if !matchesTitle && !matchesPwd && !matchesGit && !matchesDesc {
                    continue
                }
            }

            result.append(item)
        }

        return result
    }

    /// Selects a tab corresponding to the sidebar item.
    func selectTab(item: SessionSidebarItem, in window: NSWindow?) {
        guard let group = window.flatMap({ Tako.CustomTabGroup.group(for: $0) }) else { return }
        if item.index >= 0 && item.index < group.windows.count {
            let target = group.windows[item.index]
            group.select(target)
        }
    }

    /// Moves a tab up or down within its group.
    func moveTab(item: SessionSidebarItem, delta: Int, in window: NSWindow?) {
        guard let group = window.flatMap({ Tako.CustomTabGroup.group(for: $0) }) else { return }
        let newIndex = item.index + delta
        guard item.index >= 0 && item.index < group.windows.count,
              newIndex >= 0 && newIndex < group.windows.count else { return }
        let target = group.windows[item.index]
        Tako.CustomTabGroup.move(target, to: newIndex, in: group)
        objectWillChange.send()
    }

    /// Closes a tab from the sidebar.
    func closeTab(item: SessionSidebarItem, in window: NSWindow?) {
        guard let group = window.flatMap({ Tako.CustomTabGroup.group(for: $0) }) else { return }
        if item.index >= 0 && item.index < group.windows.count {
            let target = group.windows[item.index]
            target.performClose(nil)
            objectWillChange.send()
        }
    }

    // MARK: - Internal Helpers

    private func surface(in window: NSWindow) -> Tako.SurfaceView? {
        func find(_ view: NSView) -> Tako.SurfaceView? {
            if let s = view as? Tako.SurfaceView { return s }
            for sub in view.subviews {
                if let found = find(sub) { return found }
            }
            return nil
        }
        return window.contentView.flatMap(find)
    }

    private func titleFor(window: NSWindow, surface: Tako.SurfaceView?) -> String {
        let raw = surface?.title ?? window.title
        guard !raw.isEmpty else { return "~" }
        if raw.hasPrefix("/") || raw.hasPrefix("~") {
            return Tako.titleForDirectory(raw)
        }
        return raw
    }

    func surfaces(in window: NSWindow) -> [Tako.SurfaceView] {
        func collect(_ view: NSView, into list: inout [Tako.SurfaceView]) {
            if let surface = view as? Tako.SurfaceView {
                list.append(surface)
            }
            for sub in view.subviews {
                collect(sub, into: &list)
            }
        }
        var list: [Tako.SurfaceView] = []
        if let content = window.contentView {
            collect(content, into: &list)
        }
        return list
    }

    private func aggregateCrab(for window: NSWindow) -> Tako.CrabTracker? {
        let all = surfaces(in: window)
        guard !all.isEmpty else { return nil }
        return all.max(by: { $0.crab.paneStatus.priority < $1.crab.paneStatus.priority })?.crab
    }

    private func aggregateProgress(for window: NSWindow) -> (state: TakoTerminalNSView.ProgressState, progress: Int?)? {
        let all = surfaces(in: window)
        guard !all.isEmpty else { return nil }
        return Tako.CrabTabBinding.aggregateProgress(for: all)
    }
}
