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
import Combine
import Foundation
import TakoKit

/// State, data derivation, and live reactive observers for the Pane Overview (B6).
@MainActor
final class PaneOverviewStore: ObservableObject {
    static let shared = PaneOverviewStore()

    @Published var items: [PaneOverviewItem] = []
    @Published var filterText: String = "" {
        didSet {
            clampSelection()
        }
    }
    @Published var selectedIndex: Int = 0

    /// What the header chips filter by (Spec 4b: "2 need you", "2 working"
    /// are filters too) -- the same states they count.
    enum StatusFilter: Equatable {
        case needsYou
        case working

        func matches(_ item: PaneOverviewItem) -> Bool {
            switch (self, item.surfaceState) {
            case (.needsYou, .waiting): return true
            case (.working, .working), (.working, .progress): return true
            default: return false
            }
        }
    }

    @Published var statusFilter: StatusFilter? {
        didSet {
            clampSelection()
        }
    }

    /// Weak references to live surfaces mapped by surface ID.
    private var surfacesByID: [UUID: Weak<Tako.SurfaceView>] = [:]
    private var surfaceSubscriptions: [UUID: [AnyCancellable]] = [:]
    /// Notifications arriving or read while the overview is open change
    /// which quiet panes wait for you.
    private var notificationSubscription: AnyCancellable?

    /// Where unread notifications are read from; a test passes its own.
    let notifications: NotificationStore

    init(notifications: NotificationStore = .shared) {
        self.notifications = notifications
    }

    /// Filtered list of items matching the current `filterText`.
    var filteredItems: [PaneOverviewItem] {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { item in
            (statusFilter?.matches(item) ?? true) && (query.isEmpty || item.matches(query: query))
        }
    }

    /// The currently selected item in the filtered view, if any.
    var selectedItem: PaneOverviewItem? {
        let current = filteredItems
        guard !current.isEmpty, selectedIndex >= 0, selectedIndex < current.count else { return nil }
        return current[selectedIndex]
    }

    private func clampSelection() {
        let count = filteredItems.count
        if count == 0 {
            selectedIndex = 0
        } else if selectedIndex >= count {
            selectedIndex = count - 1
        } else if selectedIndex < 0 {
            selectedIndex = 0
        }
    }

    func selectNext(cols: Int = 1) {
        let count = filteredItems.count
        guard count > 0 else { return }
        selectedIndex = min(selectedIndex + cols, count - 1)
    }

    func selectPrevious(cols: Int = 1) {
        let count = filteredItems.count
        guard count > 0 else { return }
        selectedIndex = max(selectedIndex - cols, 0)
    }

    /// Discovers all terminal panes across all windows and tab groups.
    /// Fast: designed to complete in < 20 ms for 30 panes (well under 150 ms budget).
    func refresh(
        fromControllers customControllers: [BaseTerminalController]? = nil,
        workspaceStore: WorkspaceStore = .shared
    ) {
        let controllers = customControllers ?? discoverControllers()
        var discoveredItems: [PaneOverviewItem] = []
        var discoveredSurfaces: [UUID: Weak<Tako.SurfaceView>] = [:]
        let activeWsName = workspaceStore.activeWorkspace.name

        for controller in controllers {
            let win = controller.window
            let winTitle = win?.title ?? ""
            let group = win.flatMap { Tako.CustomTabGroup.existingGroup(for: $0) }
            let groupWindows = group?.windows ?? (win.map { [$0] } ?? [])
            let tabIndex = groupWindows.firstIndex(where: { $0 === win }) ?? 0
            let wsName = win.flatMap { workspaceStore.workspace(forTab: $0.stableTabIdentifier)?.name } ?? activeWsName

            for surface in controller.surfaceTree {
                let sid = surface.id
                discoveredSurfaces[sid] = Weak(surface)

                let title = surface.titleText.isEmpty ? (surface.title.isEmpty ? Tako.titleForDirectory(surface.pwd ?? "") : surface.title) : surface.titleText
                let tabTitle = winTitle.isEmpty ? title : winTitle
                let pwd = surface.pwd
                let status = surface.crab.paneStatus
                let crabState = surface.crab.state
                let statusText = surface.crab.statusText
                let progressState = surface.activeProgressState
                let progressValue = surface.activeProgressValue
                let isFocused = controller.focusedSurface === surface
                let isKey = win?.isKeyWindow == true
                let lines = surfacePreviewLines(for: surface, maxRows: 10)

                let item = PaneOverviewItem(
                    id: sid,
                    workspaceName: wsName,
                    windowTitle: winTitle,
                    tabTitle: tabTitle,
                    tabIndex: tabIndex,
                    title: title,
                    pwd: pwd,
                    status: status,
                    crabState: crabState,
                    statusText: statusText,
                    progressState: progressState,
                    progressValue: progressValue,
                    live: surface.crab.live,
                    isFocused: isFocused,
                    isKeyWindow: isKey,
                    hasUnread: hasUnread(surface),
                    thumbnailLines: lines
                )
                discoveredItems.append(item)
            }
        }

        self.surfacesByID = discoveredSurfaces
        self.items = discoveredItems
        clampSelection()

        // Bind live observers so status changes reflect immediately in the overview
        bindLiveObservers()
    }

    /// Optional fixture controllers for benchmarks and tests when running in test hosts
    static var fixtureControllers: [BaseTerminalController]?

    /// Optional injected delay in controller discovery / data refresh pipeline for negative control benchmarks.
    static var discoveryDelay: TimeInterval = 0

    /// Discovers all active terminal window controllers in the application.
    private func discoverControllers() -> [BaseTerminalController] {
        if Self.discoveryDelay > 0 {
            Thread.sleep(forTimeInterval: Self.discoveryDelay)
        }
        if let fixture = Self.fixtureControllers {
            return fixture
        }
        var seen = Set<ObjectIdentifier>()
        var controllers: [BaseTerminalController] = []

        // Primary: check NSApp.windows
        if let windows = NSApp?.windows {
            for win in windows {
                if let c = win.windowController as? BaseTerminalController {
                    if seen.insert(ObjectIdentifier(c)).inserted {
                        controllers.append(c)
                    }
                }
            }
        }

        // Secondary: check TerminalController.all in case any windows are unlisted
        for c in TerminalController.all {
            if seen.insert(ObjectIdentifier(c)).inserted {
                controllers.append(c)
            }
        }

        return controllers
    }

    /// Extracts recent viewport lines for live thumbnail without expensive Metal rendering.
    func surfacePreviewLines(for surface: Tako.SurfaceView, maxRows: Int = 10) -> [String] {
        let totalRows = surface.rows
        guard totalRows > 0 else { return [] }
        let count = min(totalRows, maxRows)
        let startRow = UInt32(max(0, totalRows - count))
        let plain = surface.core.getPlainText(startRow: startRow, maxRows: UInt32(count))
        let split = plain.components(separatedBy: "\n")
        return split.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Binds Combine publishers on every surface's status and lifecycle.
    /// When status changes (B1), the card updates in-place live without reopening!
    private func bindLiveObservers() {
        surfaceSubscriptions.removeAll()
        notificationSubscription = NotificationCenter.default
            .publisher(for: .takoNotificationStoreDidChange, object: notifications)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshUnread() }
            }

        for (sid, weakSurface) in surfacesByID {
            guard let surface = weakSurface.value else { continue }
            var subs: [AnyCancellable] = []

            // Live status changes: e.g. running -> done, or waiting -> error
            subs.append(
                surface.crab.$paneStatus
                    .dropFirst()
                    .sink { [weak self, weak surface] newStatus in
                        guard let self, let surface else { return }
                        self.updateItem(for: sid, surface: surface, newStatus: newStatus)
                    }
            )

            // A bell or a notification seen or not: waiting or quiet
            subs.append(
                surface.crab.$unread
                    .dropFirst()
                    .sink { [weak self, weak surface] newUnread in
                        guard let self, let surface else { return }
                        self.updateItem(for: sid, surface: surface, unread: newUnread)
                    }
            )

            // A live program's activity, passed in for the same reason: a
            // quiet one publishes once a minute, so a card that read the old
            // value here would show it for that long.
            subs.append(
                surface.crab.$live
                    .dropFirst()
                    .sink { [weak self, weak surface] newLive in
                        guard let self, let surface else { return }
                        self.updateItem(for: sid, surface: surface, live: .some(newLive))
                    }
            )

            // Crab state / elapsed updates
            subs.append(
                surface.crab.objectWillChange
                    .sink { [weak self, weak surface] _ in
                        guard let self, let surface else { return }
                        self.updateItem(for: sid, surface: surface)
                    }
            )

            // Content updates (terminal output damage)
            subs.append(
                surface.objectWillChange
                    .sink { [weak self, weak surface] _ in
                        guard let self, let surface else { return }
                        self.updateItem(for: sid, surface: surface)
                    }
            )

            surfaceSubscriptions[sid] = subs
        }
    }

    /// Updates a single item in-place when a live event occurs.
    /// Something on the pane the user has not seen (bell or notification),
    /// unless its attention is muted.
    /// `crabUnread` is the crab's new value when called from its publisher,
    /// before the property itself changes.
    func hasUnread(_ surface: Tako.SurfaceView, crabUnread: Bool? = nil) -> Bool {
        guard !AttentionManager.shared.isMuted(surfaceId: surface.id) else { return false }
        return (crabUnread ?? surface.crab.unread) || notifications.unreadCount(for: surface.id) > 0
    }

    /// `live` is the crab's new activity when called from its publisher:
    /// `.some(nil)` when the program ended, nil to read the crab.
    private func updateItem(for sid: UUID, surface: Tako.SurfaceView, newStatus: Tako.PaneStatus? = nil,
                            unread: Bool? = nil, live: Tako.LiveActivity?? = nil) {
        guard let index = items.firstIndex(where: { $0.id == sid }) else { return }
        let current = items[index]
        let status = newStatus ?? surface.crab.paneStatus
        let title = surface.titleText.isEmpty ? (surface.title.isEmpty ? current.title : surface.title) : surface.titleText
        let lines = surfacePreviewLines(for: surface, maxRows: 10)

        let updated = PaneOverviewItem(
            id: sid,
            workspaceName: current.workspaceName,
            windowTitle: current.windowTitle,
            tabTitle: current.tabTitle,
            tabIndex: current.tabIndex,
            title: title,
            pwd: surface.pwd ?? current.pwd,
            status: status,
            crabState: surface.crab.state,
            statusText: surface.crab.statusText,
            progressState: surface.activeProgressState,
            progressValue: surface.activeProgressValue,
            live: live ?? surface.crab.live,
            isFocused: current.isFocused,
            isKeyWindow: current.isKeyWindow,
            hasUnread: hasUnread(surface, crabUnread: unread),
            thumbnailLines: lines.isEmpty ? current.thumbnailLines : lines
        )
        if updated != current {
            items[index] = updated
        }
    }

    /// Re-reads every card's unread state, as the notification store changed.
    func refreshUnread() {
        for (sid, weakSurface) in surfacesByID {
            guard let surface = weakSurface.value else { continue }
            updateItem(for: sid, surface: surface)
        }
    }

    /// Stops observers and releases references when overview closes.
    func stopObserving() {
        notificationSubscription = nil
        surfaceSubscriptions.removeAll()
        surfacesByID.removeAll()
    }

    /// Jumps to the selected pane across windows and tabs (B6).
    func jump(to item: PaneOverviewItem) {
        guard let surface = surfacesByID[item.id]?.value ?? Self.findSurface(byID: item.id) else {
            return
        }

        stopObserving()

        // Post takoPresentTerminal to select tab, bring window forward, focus pane, mark read, and highlight!
        NotificationCenter.default.post(
            name: Tako.Notification.takoPresentTerminal,
            object: surface
        )
    }

    private static func findSurface(byID id: UUID) -> Tako.SurfaceView? {
        for c in TerminalController.all {
            if let found = c.surfaceTree.first(where: { $0.id == id }) {
                return found
            }
        }
        return nil
    }
}
