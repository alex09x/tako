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
                surfaceLastStatus.removeAll()
            }
        }
    }

    /// Opt-in: read local git branch and dirty status from working directory.
    /// OFF by default to respect resource and latency budgets.
    @Published var optInGit: Bool {
        didSet {
            defaults.set(optInGit, forKey: Self.optInGitKey)
            invalidateCaches()
            objectWillChange.send()
        }
    }

    /// Opt-in: inspect local TCP listening ports for running pane processes.
    /// OFF by default to avoid unnecessary process inspection.
    @Published var optInPorts: Bool {
        didSet {
            defaults.set(optInPorts, forKey: Self.optInPortsKey)
            invalidateCaches()
            objectWillChange.send()
        }
    }

    private var defaultFilterNeedsAttention: Bool = false
    private var defaultFilterText: String = ""
    private var groupFilterTexts: [ObjectIdentifier: String] = [:]
    private var groupNeedsAttention: [ObjectIdentifier: Bool] = [:]

    /// Whether the sidebar view is filtered to only items needing attention for the specified window's tab group.
    func filterNeedsAttention(for window: NSWindow?) -> Bool {
        guard let window else { return defaultFilterNeedsAttention }
        let group = Tako.CustomTabGroup.group(for: window)
        return groupNeedsAttention[ObjectIdentifier(group)] ?? defaultFilterNeedsAttention
    }

    /// Sets whether the sidebar view is filtered to only items needing attention for the specified window's tab group.
    func setFilterNeedsAttention(_ enabled: Bool, for window: NSWindow?) {
        guard let window else {
            defaultFilterNeedsAttention = enabled
            objectWillChange.send()
            return
        }
        let group = Tako.CustomTabGroup.group(for: window)
        groupNeedsAttention[ObjectIdentifier(group)] = enabled
        objectWillChange.send()
    }

    /// Filter text for title, working directory, or description search for the specified window's tab group.
    func filterText(for window: NSWindow?) -> String {
        guard let window else { return defaultFilterText }
        let group = Tako.CustomTabGroup.group(for: window)
        return groupFilterTexts[ObjectIdentifier(group)] ?? defaultFilterText
    }

    /// Sets filter text for title, working directory, or description search for the specified window's tab group.
    func setFilterText(_ text: String, for window: NSWindow?) {
        guard let window else {
            defaultFilterText = text
            objectWillChange.send()
            return
        }
        let group = Tako.CustomTabGroup.group(for: window)
        groupFilterTexts[ObjectIdentifier(group)] = text
        objectWillChange.send()
    }

    /// Global fallback filter needs attention (for tests or global binding).
    var filterNeedsAttention: Bool {
        get { defaultFilterNeedsAttention }
        set {
            defaultFilterNeedsAttention = newValue
            objectWillChange.send()
        }
    }

    /// Global fallback filter text (for tests or global binding).
    var filterText: String {
        get { defaultFilterText }
        set {
            defaultFilterText = newValue
            objectWillChange.send()
        }
    }

    /// User-editable descriptions keyed by surface ID or window identifier.
    @Published private(set) var descriptions: [String: String] = [:] {
        didSet {
            defaults.set(descriptions, forKey: Self.descriptionsKey)
        }
    }

    // In-memory caches to avoid redundant filesystem/process inspections during rendering.
    // Refreshed only on explicit invalidation, directory change, command completion, or opt-in toggle.
    private var gitCache: [String: LocalGitInspection.GitInfo?] = [:]
    private var dirToRepoRoot: [String: String] = [:]
    private var repoRootToDirs: [String: Set<String>] = [:]
    private var gitRepoGenerations: [String: Int] = [:]
    private var portsCache: [Int: [Int]] = [:]
    private var pendingGitInspections: Set<String> = []
    private var pendingPortsInspections: Set<Int> = []
    private var globalCacheEpoch: Int = 0
    private var gitGenerations: [String: Int] = [:]
    private var portsGenerations: [Int: Int] = [:]

    private var surfaceSubscriptions: [UUID: [AnyCancellable]] = [:]
    private var surfaceLastStatus: [UUID: Tako.PaneStatus] = [:]

    init(defaults: UserDefaults = .tako) {
        self.defaults = defaults
        self.isShowing = defaults.bool(forKey: Self.isShowingKey)
        self.optInGit = defaults.bool(forKey: Self.optInGitKey)
        self.optInPorts = defaults.bool(forKey: Self.optInPortsKey)
        self.descriptions = defaults.dictionary(forKey: Self.descriptionsKey) as? [String: String] ?? [:]

        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            MainActor.assumeIsolated {
                guard let self, let win = notif.object as? NSWindow else { return }
                let closedSurfaces = self.surfaces(in: win)
                for s in closedSurfaces {
                    self.surfaceSubscriptions.removeValue(forKey: s.id)
                    self.surfaceLastStatus.removeValue(forKey: s.id)
                }
                let group = Tako.CustomTabGroup.group(for: win)
                if group.windows.allSatisfy({ $0 === win }) {
                    self.groupFilterTexts.removeValue(forKey: ObjectIdentifier(group))
                    self.groupNeedsAttention.removeValue(forKey: ObjectIdentifier(group))
                }
            }
        }
    }

    /// Invalidates Git cache for a specific directory and all directories in the same repository, discarding in-flight inspections.
    func invalidateGitCache(for directory: String) {
        let root = dirToRepoRoot[directory]
            ?? repoRootToDirs.keys.first(where: { directory == $0 || directory.hasPrefix($0 + "/") })
            ?? LocalGitInspection.resolveBranch(directory: directory)?.repoRoot
        if let root {
            dirToRepoRoot[directory] = root
            repoRootToDirs[root, default: []].insert(directory)
            repoRootToDirs[root, default: []].insert(root)
            gitRepoGenerations[root, default: 0] += 1
            let dirs = (repoRootToDirs[root] ?? []).union([root, directory])
            for d in dirs {
                gitCache.removeValue(forKey: d)
                pendingGitInspections.remove(d)
                gitGenerations[d, default: 0] += 1
            }
        } else {
            gitCache.removeValue(forKey: directory)
            pendingGitInspections.remove(directory)
            gitGenerations[directory, default: 0] += 1
        }
        objectWillChange.send()
    }

    /// Checks whether an asynchronous Git inspection is currently in flight for a directory.
    func isGitInspectionPending(for directory: String) -> Bool {
        if pendingGitInspections.contains(directory) { return true }
        if let root = dirToRepoRoot[directory] ?? repoRootToDirs.keys.first(where: { directory == $0 || directory.hasPrefix($0 + "/") }) {
            return pendingGitInspections.contains(root)
        }
        return false
    }

    /// Checks whether Git metadata is cached for a directory.
    func hasGitCache(for directory: String) -> Bool {
        if gitCache[directory] != nil { return true }
        if let root = dirToRepoRoot[directory] ?? repoRootToDirs.keys.first(where: { directory == $0 || directory.hasPrefix($0 + "/") }) {
            return gitCache[root] != nil
        }
        return false
    }

    /// Checks whether an asynchronous ports inspection is currently in flight for a PID.
    func isPortsInspectionPending(for pid: Int) -> Bool {
        pendingPortsInspections.contains(pid)
    }

    /// Checks whether ports are cached for a PID.
    func hasPortsCache(for pid: Int) -> Bool {
        portsCache[pid] != nil
    }

    /// Invalidates listening ports cache for a specific PID, discarding in-flight inspections.
    func invalidatePortsCache(for pid: Int) {
        portsCache.removeValue(forKey: pid)
        pendingPortsInspections.remove(pid)
        portsGenerations[pid, default: 0] += 1
    }

    /// Invalidates in-memory inspection caches and increments global epoch and generations to discard in-flight tasks.
    func invalidateCaches() {
        globalCacheEpoch += 1
        gitCache.removeAll()
        portsCache.removeAll()
        pendingGitInspections.removeAll()
        pendingPortsInspections.removeAll()
        gitGenerations.removeAll()
        portsGenerations.removeAll()
        dirToRepoRoot.removeAll()
        repoRootToDirs.removeAll()
        gitRepoGenerations.removeAll()
    }

    /// Dynamically binds to live surfaces across open tab groups to observe status, progress, elapsed, title, and pwd changes in real time.
    func bindSurfaces(for window: NSWindow?) {
        guard let window else { return }
        let group = Tako.CustomTabGroup.group(for: window)
        let windows = group.windows
        let currentSurfaces = windows.flatMap { surfaces(in: $0) }

        for s in currentSurfaces {
            let sid = s.id
            guard surfaceSubscriptions[sid] == nil else { continue }
            surfaceLastStatus[sid] = s.crab.paneStatus
            var subs: [AnyCancellable] = []
            subs.append(
                s.objectWillChange
                    .receive(on: RunLoop.main)
                    .sink { [weak self] _ in self?.objectWillChange.send() }
            )
            subs.append(
                s.crab.objectWillChange
                    .receive(on: RunLoop.main)
                    .sink { [weak self] _ in self?.objectWillChange.send() }
            )
            subs.append(
                s.crab.$paneStatus
                    .dropFirst()
                    .sink { [weak self, weak s] newStatus in
                        guard let self, let s else { return }
                        let oldStatus = self.surfaceLastStatus[sid]
                        self.surfaceLastStatus[sid] = newStatus
                        // If command finished (entered terminal status from an active or attention state),
                        // invalidate git/ports caches for this surface.
                        let isTerminal = (newStatus == .done || newStatus == .error || newStatus == .idle || newStatus == .disconnected)
                        let wasActiveOrAttention = (oldStatus == .running || oldStatus == .working || oldStatus == .waitingForInput || oldStatus == .needsApproval)
                        if let oldStatus, oldStatus != newStatus, isTerminal, wasActiveOrAttention {
                            if let pwd = s.pwd {
                                self.invalidateGitCache(for: pwd)
                            }
                            if let pty = s.pty {
                                let pid = pty.foregroundPID ?? Int(pty.child)
                                self.invalidatePortsCache(for: pid)
                            }
                        }
                        self.objectWillChange.send()
                    }
            )
            surfaceSubscriptions[sid] = subs
        }
    }

    /// Sets or updates a custom user description for a tab.
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
    func items(
        for window: NSWindow?,
        filterText explicitFilterText: String? = nil,
        filterNeedsAttention explicitFilterNeedsAttention: Bool? = nil
    ) -> [SessionSidebarItem] {
        bindSurfaces(for: window)

        let group = window.flatMap { Tako.CustomTabGroup.group(for: $0) }
        let windows = group?.windows ?? (window.map { [$0] } ?? [])
        let selected = group?.selectedWindow ?? window

        var result: [SessionSidebarItem] = []
        result.reserveCapacity(windows.count)

        for (index, win) in windows.enumerated() {
            let winSurfaces = surfaces(in: win)
            let controller = win.windowController as? BaseTerminalController
            let focused = controller?.focusedSurface
            let surface = (focused != nil && winSurfaces.contains(where: { $0 === focused })) ? focused : winSurfaces.first
            let surfaceIds = Set(winSurfaces.map(\.id))
            let surfaceId = surface?.id
            let id = win.stableTabIdentifier

            let title = titleFor(window: win, surface: surface)
            let crab = aggregateCrab(for: win)
            let status = crab?.paneStatus ?? .idle
            let crabState = crab?.state ?? .idle
            let elapsed = crab?.elapsedLabel
            let prog = aggregateProgress(for: win)
            let pwd = surface?.pwd

            // Opt-in Git branch and dirty status (no background polling on render cadence)
            var gitBranch: String?
            var gitDirty: Bool?
            if optInGit, let dir = pwd, !dir.isEmpty {
                let knownRoot = dirToRepoRoot[dir] ?? repoRootToDirs.keys.first(where: { dir == $0 || dir.hasPrefix($0 + "/") })
                if let knownRoot {
                    dirToRepoRoot[dir] = knownRoot
                    repoRootToDirs[knownRoot, default: []].insert(dir)
                }
                let cacheKey = knownRoot ?? dir
                if let cached = gitCache[dir] ?? gitCache[cacheKey] {
                    gitBranch = cached?.branch
                    gitDirty = cached?.isDirty
                } else if !pendingGitInspections.contains(dir) && (knownRoot == nil || !pendingGitInspections.contains(knownRoot!)) {
                    pendingGitInspections.insert(dir)
                    let gen = gitGenerations[dir, default: 0]
                    let epoch = globalCacheEpoch
                    let repoGenSnapshot = gitRepoGenerations
                    Task.detached(priority: .utility) {
                        let inspected = LocalGitInspection.inspect(directory: dir)
                        await MainActor.run { [weak self] in
                            guard let self else { return }
                            self.pendingGitInspections.remove(dir)
                            guard self.globalCacheEpoch == epoch && self.gitGenerations[dir, default: 0] == gen else {
                                self.objectWillChange.send()
                                return
                            }
                            if let root = inspected?.repoRoot {
                                let startRootGen = repoGenSnapshot[root, default: 0]
                                if self.gitRepoGenerations[root, default: 0] != startRootGen {
                                    self.objectWillChange.send()
                                    return
                                }
                                self.dirToRepoRoot[dir] = root
                                self.repoRootToDirs[root, default: []].insert(dir)
                                self.repoRootToDirs[root, default: []].insert(root)
                                self.gitCache[root] = inspected
                                for d in self.repoRootToDirs[root, default: []] {
                                    self.gitCache[d] = inspected
                                }
                            } else {
                                self.gitCache[dir] = inspected
                            }
                            self.objectWillChange.send()
                        }
                    }
                }
            }

            // Opt-in listening ports (no background polling on render cadence)
            // Aggregates ports across all panes in this tab (winSurfaces)
            var ports: [Int]?
            if optInPorts {
                var aggregatedPorts: Set<Int> = []
                var hasInspectedPane = false
                for s in winSurfaces {
                    guard let pty = s.pty else { continue }
                    let pid = pty.foregroundPID ?? Int(pty.child)
                    guard pid > 0 else { continue }
                    if let cached = portsCache[pid] {
                        hasInspectedPane = true
                        aggregatedPorts.formUnion(cached)
                    } else if !pendingPortsInspections.contains(pid) {
                        pendingPortsInspections.insert(pid)
                        let gen = portsGenerations[pid, default: 0]
                        let epoch = globalCacheEpoch
                        Task.detached(priority: .utility) {
                            let inspected = LocalPortInspection.inspectListeningPorts(pid: pid)
                            await MainActor.run { [weak self] in
                                guard let self else { return }
                                self.pendingPortsInspections.remove(pid)
                                if self.globalCacheEpoch == epoch && self.portsGenerations[pid, default: 0] == gen {
                                    self.portsCache[pid] = inspected
                                }
                                self.objectWillChange.send()
                            }
                        }
                    }
                }
                if hasInspectedPane || !aggregatedPorts.isEmpty {
                    ports = aggregatedPorts.sorted()
                }
            }

            // Latest notification text across all panes in this tab (from Track B4)
            // Chooses the matching record with the greatest timestamp (Codex P2)
            let latestRecord = NotificationStore.shared.records
                .filter { surfaceIds.contains($0.surfaceId) }
                .max(by: { $0.time < $1.time })
            let latestNotification = latestRecord.flatMap { rec in
                rec.title.isEmpty ? (rec.body.isEmpty ? nil : rec.body) : rec.title
            }

            // User-editable description (for stable tab ID, with legacy surface ID fallback)
            var userDesc = descriptions[id]
            if userDesc == nil {
                for sid in surfaceIds {
                    if let desc = descriptions[sid.uuidString] {
                        userDesc = desc
                        descriptions[id] = desc
                        descriptions.removeValue(forKey: sid.uuidString)
                        break
                    }
                }
            }

            // Total unread count across all panes in this tab (excluding muted panes)
            let unread = surfaceIds.reduce(0) { sum, sid in
                AttentionManager.shared.isMuted(surfaceId: sid) ? sum : sum + NotificationStore.shared.unreadCount(for: sid)
            }
            let isSelected = win === selected

            // Needs attention condition across all panes in this tab
            let hasCrabUnread = winSurfaces.contains(where: { !AttentionManager.shared.isMuted(surfaceId: $0.id) && $0.crab.unread })
            let hasStatusAttention = winSurfaces.contains(where: {
                !AttentionManager.shared.isMuted(surfaceId: $0.id) &&
                ($0.crab.paneStatus == .error || $0.crab.paneStatus == .needsApproval || $0.crab.paneStatus == .waitingForInput)
            })
            let needsAttention = !isSelected && (
                hasStatusAttention ||
                unread > 0 ||
                hasCrabUnread
            )

            let item = SessionSidebarItem(
                id: id,
                surfaceId: surfaceId,
                surfaceIds: surfaceIds,
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
            let effectiveNeedsAttention = explicitFilterNeedsAttention ?? filterNeedsAttention(for: window ?? win)
            if effectiveNeedsAttention && !item.needsAttention {
                continue
            }

            let effectiveFilterText = explicitFilterText ?? filterText(for: window ?? win)
            if !effectiveFilterText.isEmpty {
                let query = effectiveFilterText.lowercased()
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
        let winTitle = window.title
        let raw: String
        if !winTitle.isEmpty && winTitle != "👻" {
            raw = winTitle
        } else {
            raw = (surface?.title.isEmpty == false ? surface?.title : winTitle) ?? ""
        }
        guard !raw.isEmpty, raw != "👻" else { return "~" }
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
