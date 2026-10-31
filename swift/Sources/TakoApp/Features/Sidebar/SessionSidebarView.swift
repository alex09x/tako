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

    @ObservedObject var store: SessionSidebarStore
    @ObservedObject var workspaceStore: WorkspaceStore
    @ObservedObject private var notificationStore = NotificationStore.shared
    @ObservedObject private var subagentStore = SubagentHierarchyStore.shared
    @ObservedObject private var animState = LivingAnimationState.shared

    typealias T = Tako.LivingTokens

    @State var selectedIndex: Int = 0
    /// Whether the arrow-key cursor is drawn: only while the keys move it. A
    /// click selects the tab itself, and a cursor left on another row would
    /// read as a second selection.
    @State var showsArrowCursor = false
    @State private var editingItemId: String? = nil
    @State private var editingDescriptionText: String = ""
    @FocusState private var isSearchFocused: Bool
    @FocusState private var isListFocused: Bool

    @State private var hostingWindow: NSWindow?

    init(
        isPresented: Binding<Bool>,
        containingWindow: NSWindow? = nil,
        backgroundColor: Color = Color(nsColor: .windowBackgroundColor),
        store: SessionSidebarStore = .shared,
        workspaceStore: WorkspaceStore = .shared
    ) {
        self._isPresented = isPresented
        self.containingWindow = containingWindow
        self.backgroundColor = backgroundColor
        self.store = store
        self.workspaceStore = workspaceStore
    }

    var targetWindow: NSWindow? {
        containingWindow ?? hostingWindow ?? NSApp?.keyWindow
    }

    private var filterNeedsAttention: Bool {
        store.filterNeedsAttention(for: targetWindow)
    }

    private var filterText: String {
        store.filterText(for: targetWindow)
    }

    private var filterTextBinding: Binding<String> {
        Binding(
            get: { store.filterText(for: targetWindow) },
            set: { store.setFilterText($0, for: targetWindow) }
        )
    }

    private var workspaceGroups: [SessionSidebarWorkspaceGroup] {
        store.workspaceGroups(for: targetWindow, workspaceStore: workspaceStore)
    }

    var items: [SessionSidebarItem] {
        workspaceGroups.flatMap(\.items)
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
    private var motionPaused: Bool {
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
        let groups = workspaceGroups
        let flatItems = groups.flatMap(\.items)
        VStack(spacing: 0) {
            headerView(sessionCount: Self.sessionCount(groups, flatItems))
            searchAndSegmentsBar(attentionCount: Self.attentionCount(groups, flatItems))
            tabListView(groups: groups, flatItems: flatItems)
            Divider().background(Color(nsColor: T.hairline))
            footerView
        }
        .contextMenu {
            Toggle("Show Git Branch & Dirty Status", isOn: $store.optInGit)
            Toggle("Show Listening TCP Ports", isOn: $store.optInPorts)
        }
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: T.body))
        .overlay(
            Rectangle()
                .frame(width: 1)
                .foregroundColor(Color(nsColor: T.hairline)),
            alignment: .trailing
        )
        .onKeyPress(.escape) {
            isPresented = false
            return .handled
        }
        .onAppear {
            if hostingWindow == nil {
                hostingWindow = containingWindow ?? NSApp?.keyWindow
            }
            followActiveTab()
            isListFocused = true
        }
        // Each tab is a window with a sidebar of its own; the one on screen
        // must not keep an arrow-key cursor left from when it was last shown,
        // or a second row looks chosen. The cursor goes where the active
        // tab goes.
        .onChange(of: flatItems.firstIndex(where: { $0.isSelected })) { _, _ in
            followActiveTab()
        }
        .onReceive(NotificationCenter.default.publisher(for: .takoNotificationStoreDidChange)) { _ in
            store.objectWillChange.send()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notif in
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
            store.objectWillChange.send()
        }
        .onReceive(NotificationCenter.default.publisher(for: .takoCloseTab)) { _ in
            store.objectWillChange.send()
        }
        .onReceive(NotificationCenter.default.publisher(for: .takoMoveTab)) { _ in
            store.objectWillChange.send()
        }
        .onReceive(NotificationCenter.default.publisher(for: Tako.Notification.takoPresentTerminal)) { _ in
            store.objectWillChange.send()
        }
        .onReceive(NotificationCenter.default.publisher(for: .takoSubagentHierarchyDidChange)) { _ in
            store.objectWillChange.send()
        }
    }

    // MARK: - Header (§5.1)

    private func headerView(sessionCount: Int) -> some View {
        HStack(spacing: 8) {
            Text("Sessions")
                .font(T.headerFont(size: 13))
                .foregroundColor(Color(nsColor: T.textActive))
                .accessibilityIdentifier("SessionSidebarHeader")

            Spacer()

            Text("\(sessionCount)")
                .font(Font(T.monoFont(size: 10, weight: .medium)))
                .foregroundColor(Color(nsColor: T.dim))
        }
        .frame(height: 17)
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .contentShape(Rectangle())
        .contextMenu {
            Toggle("Show Git Branch & Dirty Status", isOn: $store.optInGit)
            Toggle("Show Listening TCP Ports", isOn: $store.optInPorts)
        }
    }

    // MARK: - Search & Segments (§5.2, §5.3)

    private func searchAndSegmentsBar(attentionCount: Int) -> some View {
        VStack(spacing: 0) {
            // Search input: margin 0 12 8, h 26, r 7, bg #1A1512, border 1 #2A211B, padding 0 9
            HStack(spacing: 7) {
                Text("⌕")
                    .font(Font(T.monoFont(size: 11)))
                    .foregroundColor(Color(nsColor: T.faint))

                ZStack(alignment: .leading) {
                    if filterText.isEmpty {
                        Text("Filter sessions…")
                            .font(Font(T.monoFont(size: 11)))
                            .foregroundColor(Color(nsColor: T.faint))
                            .allowsHitTesting(false)
                    }
                    TextField("", text: filterTextBinding)
                        .textFieldStyle(.plain)
                        .font(Font(T.monoFont(size: 11)))
                        .foregroundColor(Color(nsColor: T.textActive))
                        .focused($isSearchFocused)
                        .onKeyPress(.escape) {
                            isPresented = false
                            return .handled
                        }
                }

                if !filterText.isEmpty {
                    Button(action: { store.setFilterText("", for: targetWindow) }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(Color(nsColor: T.dim))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: T.chrome)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: T.hairline), lineWidth: 1))
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            // Segments: margin 0 12 6, gap 4. Two segments h 22, r 6, padding 0 8, mono 10: "All" and "◎ Needs you · N"
            HStack(spacing: 4) {
                segmentButton(isActive: !filterNeedsAttention) {
                    store.setFilterNeedsAttention(false, for: targetWindow)
                } content: {
                    Text("All")
                        .font(Font(T.monoFont(size: 10, weight: .regular)))
                }

                segmentButton(isActive: filterNeedsAttention) {
                    store.setFilterNeedsAttention(!filterNeedsAttention, for: targetWindow)
                } content: {
                    HStack(spacing: 6) {
                        // It pulses only while something waits for you; with
                        // nothing waiting it rests. Core Animation runs it, as
                        // a pill's ring: a SwiftUI clock in this row laid the
                        // sidebar out every frame -- in every tab's window --
                        // whenever a tab in the background was at work.
                        let ringRests = Self.headerRingRests(reduceMotion: animState.reduceMotion, waiting: attentionCount)
                        SidebarStatusLayerView(
                            state: .waiting, ringCenter: nil, cornerRadius: 0,
                            reduceMotion: ringRests, paused: motionPaused, pulses: 0,
                            ringOnly: StatusRingSize.extraSmall.rawValue)
                            .frame(width: StatusRingSize.extraSmall.rawValue, height: StatusRingSize.extraSmall.rawValue)
                        Text("Needs you · \(attentionCount)")
                            .font(Font(T.monoFont(size: 10, weight: .regular)))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }

                Spacer(minLength: 4)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
    }

    private func segmentButton<Content: View>(
        isActive: Bool, action: @escaping () -> Void, @ViewBuilder content: () -> Content
    ) -> some View {
        Button(action: action) {
            content()
                .foregroundColor(Color(nsColor: isActive ? T.textActive : T.dim))
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(isActive ? Color(nsColor: T.surfaceActive) : Color.clear))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isActive ? Color(nsColor: T.hairline) : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Tab List (§5.4 - §5.7)

    private func tabListView(groups: [SessionSidebarWorkspaceGroup], flatItems: [SessionSidebarItem]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 0) {
                    if groups.isEmpty || (flatItems.isEmpty && groups.allSatisfy({ !$0.isCollapsed })) {
                        Text("No tabs match filter")
                            .font(Font(T.monoFont(size: 11)))
                            .foregroundColor(Color(nsColor: T.dim))
                            .padding(.vertical, 24)
                    } else {
                        ForEach(groups) { wsGroup in
                            SidebarWorkspaceDropTarget(
                                group: wsGroup,
                                onToggleCollapse: { store.toggleWorkspaceCollapsed(wsGroup.id) },
                                onSelectWorkspace: { store.selectWorkspace(wsGroup.id, in: targetWindow, workspaceStore: workspaceStore) },
                                onMove: { store.moveTab($0, to: $1, around: targetWindow, workspaceStore: workspaceStore) }
                            )
                            ForEach(wsGroup.items) { item in
                                let flatIdx = flatItems.firstIndex(where: { $0.id == item.id }) ?? 0
                                SessionSidebarRowView(
                                    item: item, index: flatIdx, selectedIndex: showsArrowCursor ? selectedIndex : -1,
                                    targetWindow: targetWindow, editingItemId: $editingItemId,
                                    editingDescriptionText: $editingDescriptionText, isPresented: $isPresented,
                                    reduceMotion: animState.reduceMotion, motionPaused: motionPaused,
                                    onSelect: {
                                        selectedIndex = flatIdx
                                        showsArrowCursor = false
                                        store.selectTab(item: item, in: targetWindow, workspaceStore: workspaceStore)
                                    }
                                )
                                .modifier(SidebarWorkspaceMoveModifier(item: item, workspaces: workspaceStore.workspaces,
                                    onMove: { store.moveTab($0, to: $1, around: targetWindow, workspaceStore: workspaceStore) },
                                    canMoveToWindow: { store.canMoveTabToWindow(item.tabId, around: targetWindow, workspaceStore: workspaceStore) },
                                    onMoveToWindow: { _ = store.moveTabToWindow(item.tabId, around: targetWindow, workspaceStore: workspaceStore) }))
                            }
                        }
                    }
                }
            }
            .focusable()
            // The keys go to the list, but it is no text field: no blue ring
            // around the whole sidebar on a click.
            .focusEffectDisabled()
            .focused($isListFocused)
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
            .onKeyPress(.return) {
                if NSEvent.modifierFlags.contains(.option) { jumpToNextWaiting(); return .handled }
                if selectedIndex >= 0 && selectedIndex < items.count {
                    store.selectTab(item: items[selectedIndex], in: targetWindow, workspaceStore: workspaceStore)
                }
                return .handled
            }
            .onKeyPress(.escape) { isPresented = false; return .handled }
        }
    }

}
