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

    /// Weak references to live surfaces mapped by surface ID.
    private var surfacesByID: [UUID: Weak<Tako.SurfaceView>] = [:]
    private var surfaceSubscriptions: [UUID: [AnyCancellable]] = [:]

    init() {}

    /// Filtered list of items matching the current `filterText`.
    var filteredItems: [PaneOverviewItem] {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return items
        }
        return items.filter { $0.matches(query: query) }
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
    func refresh(fromControllers customControllers: [BaseTerminalController]? = nil) {
        let controllers = customControllers ?? discoverControllers()
        var discoveredItems: [PaneOverviewItem] = []
        var discoveredSurfaces: [UUID: Weak<Tako.SurfaceView>] = [:]

        for controller in controllers {
            let win = controller.window
            let winTitle = win?.title ?? ""
            let group = win.flatMap { Tako.CustomTabGroup.group(for: $0) }
            let groupWindows = group?.windows ?? (win.map { [$0] } ?? [])
            let tabIndex = groupWindows.firstIndex(where: { $0 === win }) ?? 0

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
                let elapsed = surface.crab.elapsedLabel
                let isFocused = controller.focusedSurface === surface
                let isKey = win?.isKeyWindow == true
                let lines = surfacePreviewLines(for: surface, maxRows: 10)

                let item = PaneOverviewItem(
                    id: sid,
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
                    elapsed: elapsed,
                    isFocused: isFocused,
                    isKeyWindow: isKey,
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

    /// Discovers all active terminal window controllers in the application.
    private func discoverControllers() -> [BaseTerminalController] {
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
    private func updateItem(for sid: UUID, surface: Tako.SurfaceView, newStatus: Tako.PaneStatus? = nil) {
        guard let index = items.firstIndex(where: { $0.id == sid }) else { return }
        let current = items[index]
        let status = newStatus ?? surface.crab.paneStatus
        let title = surface.titleText.isEmpty ? (surface.title.isEmpty ? current.title : surface.title) : surface.titleText
        let lines = surfacePreviewLines(for: surface, maxRows: 10)

        items[index] = PaneOverviewItem(
            id: sid,
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
            elapsed: surface.crab.elapsedLabel,
            isFocused: current.isFocused,
            isKeyWindow: current.isKeyWindow,
            thumbnailLines: lines.isEmpty ? current.thumbnailLines : lines
        )
    }

    /// Stops observers and releases references when overview closes.
    func stopObserving() {
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
