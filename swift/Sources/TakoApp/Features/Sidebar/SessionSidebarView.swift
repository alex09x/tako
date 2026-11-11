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
import SwiftUI
import TakoKit

/// SwiftUI view for the vertical Session Sidebar 4a (Spec 1b §5 & §7).
struct SessionSidebarView: View {
    @Binding var isPresented: Bool
    let containingWindow: NSWindow?
    let backgroundColor: Color
    let newSessionShortcut: KeyboardShortcut?
    let windowIsPresented: Bool

    @ObservedObject var store: SessionSidebarStore
    @ObservedObject var workspaceStore: WorkspaceStore
    @ObservedObject private var notificationStore = NotificationStore.shared
    @ObservedObject private var subagentStore = SubagentHierarchyStore.shared
    @ObservedObject var animState = LivingAnimationState.shared
    /// Sidebar counter settings (`sidebar-count-*`); the scheme comes from `.shellScheme()`.
    @ObservedObject var presentation = DesktopPresentation.shared

    typealias T = Tako.LivingTokens

    @State var selectedIndex: Int = 0
    /// Whether the arrow-key cursor is drawn: only while the keys move it. A
    /// click selects the tab itself, and a cursor left on another row would
    /// read as a second selection.
    @State var showsArrowCursor = false
    @State var isSearchExpanded = false
    @State var searchFocusToken: Int = 0
    @State private var chromeRevision: Int = 0
#if DEBUG
    static var onContentBuildForTesting: ((NSWindow?) -> Void)?
#endif
    @State var editingItemId: String? = nil
    @State var editingDescriptionText: String = ""
    @FocusState var isSearchFocused: Bool
    @FocusState var isListFocused: Bool

    @State private var hostingWindow: NSWindow?

    init(
        isPresented: Binding<Bool>,
        containingWindow: NSWindow? = nil,
        backgroundColor: Color = Color(nsColor: .windowBackgroundColor),
        newSessionShortcut: KeyboardShortcut? = Tako.Config.defaultKeyboardShortcuts["new_tab"],
        store: SessionSidebarStore = .shared,
        workspaceStore: WorkspaceStore = .shared,
        windowIsPresented: Bool = true
    ) {
        self._isPresented = isPresented
        self.containingWindow = containingWindow
        self.backgroundColor = backgroundColor
        self.newSessionShortcut = newSessionShortcut
        self.store = store
        self.workspaceStore = workspaceStore
        self.windowIsPresented = windowIsPresented
    }

    var targetWindow: NSWindow? {
        containingWindow ?? hostingWindow ?? NSApp?.keyWindow
    }

    var filterNeedsAttention: Bool {
        store.filterNeedsAttention(for: targetWindow)
    }

    var filterText: String {
        store.filterText(for: targetWindow)
    }

    var showsFilterControls: Bool {
        isSearchExpanded || !filterText.isEmpty || filterNeedsAttention
    }

    var filterTextBinding: Binding<String> {
        Binding(
            get: { store.filterText(for: targetWindow) },
            set: { store.setFilterText($0, for: targetWindow) }
        )
    }

    private var workspaceGroups: [SessionSidebarWorkspaceGroup] {
        store.workspaceGroups(for: targetWindow, workspaceStore: workspaceStore,
                              ignoringWorkspaceCollapse: presentation.preferences.sidebarGrouping == .status)
    }

    /// The rows in the order shown, which the arrow keys walk.
    var items: [SessionSidebarItem] {
        let groups = workspaceGroups
        guard presentation.preferences.sidebarGrouping == .status else { return groups.flatMap(\.items) }
        return SidebarStatusBucket.buckets(from: groups).flatMap { $0.rows.map(\.item) }
    }

    private static func sessionCount(_ groups: [SessionSidebarWorkspaceGroup], _ items: [SessionSidebarItem]) -> Int {
        let sum = groups.reduce(0) { $0 + $1.sessionCount }
        return sum > 0 ? sum : items.filter { !$0.isChild }.count
    }

    private static func attentionCount(_ groups: [SessionSidebarWorkspaceGroup], _ items: [SessionSidebarItem]) -> Int {
        let sum = groups.reduce(0) { $0 + $1.attentionCount }
        if sum > 0 { return sum }
        return items.filter { !$0.isChild && ($0.needsAttention || $0.surfaceState == .waiting || $0.surfaceState == .failed) }.count
    }

    /// No animation frames anywhere: the window is hidden or the app away.
    var motionPaused: Bool {
        Self.motionPaused(timelinePaused: animState.isTimelinePaused, isPresented: isPresented)
    }

    /// The header's "Needs you" ring breathes only while something waits,
    /// and never under Reduce Motion.
    static func headerRingRests(reduceMotion: Bool, waiting: Int) -> Bool {
        reduceMotion || waiting == 0
    }

    /// The rows and the header ring stand still while nobody can see Tako,
    /// Reduce Motion is on, or the sidebar is closed.
    static func motionPaused(timelinePaused: Bool, isPresented: Bool) -> Bool {
        timelinePaused || !isPresented
    }

    // The list is built once per change, not per animation frame: only the
    // rings and rows that move redraw on their own (`SessionSidebarRowView`).
    public var body: some View {
#if DEBUG
        let _ = windowIsPresented ? Self.onContentBuildForTesting?(containingWindow) : nil
#endif
        let _ = chromeRevision
        // Keep the native search editor mounted; only the expensive list is
        // suspended. Tab selection retains its existing terminal-focus policy.
        let groups = windowIsPresented ? workspaceGroups : []
        // Grouped by status, the arrow keys walk the rows in the order shown.
        let buckets = presentation.preferences.sidebarGrouping == .status ? SidebarStatusBucket.buckets(from: groups) : nil
        let flatItems = buckets.map { $0.flatMap { $0.rows.map(\.item) } } ?? groups.flatMap(\.items)
        let totalSessions = Self.sessionCount(groups, flatItems)
        let waitingCount = Self.attentionCount(groups, flatItems)
        let counts = windowIsPresented ? store.attentionCounts(for: targetWindow, preferences: presentation.preferences,
                                                               workspaceStore: workspaceStore) : SidebarAttentionCounts()

        VStack(spacing: 0) {
            headerView(sessionCount: totalSessions, attentionCount: waitingCount)
            searchBar
            if SidebarChromeMetrics.showsSegments(style: presentation.preferences.sidebarStyle,
                                                  grouping: presentation.preferences.sidebarGrouping) {
                segmentsRow(attentionCount: waitingCount, counts: counts)
            }

            VStack(spacing: 0) {
                if windowIsPresented { tabListView(groups: groups, buckets: buckets, flatItems: flatItems) }
            }
            // Rows carry the reference's own 8 pt margins (A01 `.row`, `.ws`).
            .padding(.horizontal, 0)
            .padding(.top, 4)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contextMenu {
                Button("New Session") { store.createNewTab(in: targetWindow) }
                Divider()
                Toggle("Show Git Branch & Dirty Status", isOn: $store.optInGit)
                Toggle("Show Listening TCP Ports", isOn: $store.optInPorts)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // No rule on the trailing edge: the sidebar and the canvas are one
        // surface, the cards alone mark where the terminals begin.
        .background(backgroundColor)
        .environment(\.sidebarStyle, presentation.preferences.sidebarStyle)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SessionSidebar")
        .onAppear {
            if hostingWindow == nil {
                hostingWindow = containingWindow ?? NSApp?.keyWindow
            }
            followActiveTab()
            if windowIsPresented && !(containingWindow?.firstResponder is Tako.SurfaceView) { isListFocused = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            guard windowIsPresented else { return }
            chromeRevision &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            guard windowIsPresented else { return }
            chromeRevision &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .fullscreenDidExit)) { _ in
            guard windowIsPresented else { return }
            chromeRevision &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { notif in
            guard windowIsPresented else { return }
            if let win = notif.object as? NSWindow, win === targetWindow {
                chromeRevision &+= 1
            }
        }
        // Each tab is a window with a sidebar of its own; the one on screen
        // must not keep an arrow-key cursor left from when it was last shown,
        // or a second row looks chosen. The cursor goes where the active
        // tab goes, and otherwise stays on its row when rows reorder.
        .modifier(SidebarCursorKeeper(ids: flatItems.map(\.id), activeId: flatItems.first(where: { $0.isSelected })?.id,
                                      enabled: windowIsPresented, selectedIndex: $selectedIndex,
                                      followActive: followActiveTab))
        .onReceive(NotificationCenter.default.publisher(for: .takoNotificationStoreDidChange)) { _ in
            guard windowIsPresented else { return }
            store.objectWillChange.send()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notif in
            guard windowIsPresented else { return }
            guard let win = notif.object as? NSWindow else { return }
            if let bound = containingWindow {
                let group = Tako.CustomTabGroup.group(for: bound)
                guard group.windows.contains(where: { $0 === win }) else { return }
                hostingWindow = win
            } else if hostingWindow == nil {
                hostingWindow = win
            }
            if win === hostingWindow { followActiveTab() }
            store.objectWillChange.send()
        }
        .onReceive(NotificationCenter.default.publisher(for: Tako.Notification.takoNewTab)) { _ in
            guard windowIsPresented else { return }
            store.objectWillChange.send()
        }
        .onReceive(NotificationCenter.default.publisher(for: .takoCloseTab)) { _ in
            guard windowIsPresented else { return }
            store.objectWillChange.send()
        }
        .onReceive(NotificationCenter.default.publisher(for: .takoMoveTab)) { _ in
            guard windowIsPresented else { return }
            store.objectWillChange.send()
        }
        .onReceive(NotificationCenter.default.publisher(for: Tako.Notification.takoPresentTerminal)) { _ in
            guard windowIsPresented else { return }
            store.objectWillChange.send()
        }
        .onReceive(NotificationCenter.default.publisher(for: .takoSubagentHierarchyDidChange)) { _ in
            guard windowIsPresented else { return }
            store.objectWillChange.send()
        }
        .shellScheme()
    }

    // MARK: - Tab List (§5.4 - §5.7)

    func workspaceActions(_ group: SessionSidebarWorkspaceGroup) -> SidebarWorkspaceActions {
        SidebarWorkspaceActions(
            workspaceID: group.id, name: group.name, sessionCount: group.sessionCount, isCollapsed: group.isCollapsed,
            workspaces: workspaceStore, window: targetWindow,
            newSession: { [store, workspaceStore, targetWindow] in
                store.createNewTab(inWorkspace: group.id, around: targetWindow, workspaceStore: workspaceStore)
            },
            toggleCollapse: { [store] in store.toggleWorkspaceCollapsed(group.id) })
    }

    private func tabListView(groups: [SessionSidebarWorkspaceGroup], buckets: [SidebarStatusBucket]?,
                             flatItems: [SessionSidebarItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 0) {
                    if groups.isEmpty || (flatItems.isEmpty && groups.allSatisfy({ !$0.isCollapsed })) {
                        Text("No tabs match filter")
                            .font(Font(T.monoFont(size: 11)))
                            .foregroundColor(Color(nsColor: T.dim))
                            .padding(.vertical, 24)
                    } else if let buckets {
                        ForEach(buckets) { bucket in
                            SidebarStatusBucketHeader(bucket: bucket)
                            ForEach(bucket.rows) { row in
                                sessionRow(row.item, flatItems: flatItems, workspace: row.workspace)
                            }
                        }
                    } else {
                        ForEach(groups) { wsGroup in
                            SidebarWorkspaceDropTarget(
                                group: wsGroup,
                                onToggleCollapse: { store.toggleWorkspaceCollapsed(wsGroup.id) },
                                onSelectWorkspace: { store.selectWorkspace(wsGroup.id, in: targetWindow, workspaceStore: workspaceStore) },
                                onMove: { store.moveTab($0, to: $1, around: targetWindow, workspaceStore: workspaceStore) },
                                actions: workspaceActions(wsGroup)
                            )
                            ForEach(wsGroup.items) { item in
                                sessionRow(item, flatItems: flatItems, workspace: nil)
                            }
                        }
                    }
                }
                // The lazy stack keeps a row it has built while the row's data
                // is unchanged, even when it is now given another style or a
                // workspace badge: a new look builds the list anew. Row ids,
                // which scrolling uses, stay the same.
                .id(presentation.preferences.sidebarLook)
                .background(SessionSidebarScrollerInstaller().frame(width: 0, height: 0))
            }
            .focusable()
            // The keys go to the list, but it is no text field: no blue ring
            // around the whole sidebar on a click.
            .focusEffectDisabled()
            .focused($isListFocused)
            .task {
                guard let selected = flatItems.first(where: { $0.isSelected }) else { return }
                await Task.yield()
                guard !Task.isCancelled else { return }
                proxy.scrollTo(selected.id, anchor: .center)
            }
            .onKeyPress(.upArrow) {
                if selectedIndex > 0 { selectedIndex -= 1 }
                showsArrowCursor = true
                if items.indices.contains(selectedIndex) { proxy.scrollTo(items[selectedIndex].id) }
                return .handled
            }
            .onKeyPress(.downArrow) {
                if selectedIndex < items.count - 1 { selectedIndex += 1 }
                showsArrowCursor = true
                if items.indices.contains(selectedIndex) { proxy.scrollTo(items[selectedIndex].id) }
                return .handled
            }
            .onKeyPress(.leftArrow) {
                if selectedIndex >= 0 && selectedIndex < items.count {
                    let current = items[selectedIndex]
                    if current.hasChildren && !current.isCollapsed {
                        store.setTabSplitsCollapsed(current.tabId, collapsed: true)
                    } else if let wsId = current.workspaceId {
                        store.setWorkspaceCollapsed(wsId, collapsed: true)
                    }
                }
                return .handled
            }
            .onKeyPress(.rightArrow) {
                if selectedIndex >= 0 && selectedIndex < items.count {
                    let current = items[selectedIndex]
                    if current.hasChildren && current.isCollapsed {
                        store.setTabSplitsCollapsed(current.tabId, collapsed: false)
                    }
                }
                return .handled
            }
            .onExitCommand {
                if showsFilterControls {
                    collapseSearchAndClearFilter()
                }
            }
            .onKeyPress(.escape) {
                guard showsFilterControls else { return .ignored }
                collapseSearchAndClearFilter()
                return .handled
            }
            .onKeyPress(.return) {
                if NSEvent.modifierFlags.contains(.option) { jumpToNextWaiting(); return .handled }
                if selectedIndex >= 0 && selectedIndex < items.count {
                    store.selectTab(item: items[selectedIndex], in: targetWindow, workspaceStore: workspaceStore)
                }
                return .handled
            }
            .onKeyPress(Self.renameKey) {
                guard store.renamingRowId == nil, items.indices.contains(selectedIndex) else { return .ignored }
                store.beginRename(items[selectedIndex])
                return .handled
            }
        }
    }

}
