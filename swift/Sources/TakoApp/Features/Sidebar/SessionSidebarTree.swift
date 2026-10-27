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
import SwiftUI
import TakoKit

/// Represents a top-level Workspace node in the Session Sidebar tree (`Workspace ▸ Session ▸ Split Pane`).
struct SessionSidebarWorkspaceGroup: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let color: String?
    let icon: String?
    let isActive: Bool
    let isCollapsed: Bool
    let sessionCount: Int
    let paneCount: Int
    let attentionCount: Int
    let unreadCount: Int
    let dominantStatus: Tako.PaneStatus
    let items: [SessionSidebarItem]
}

extension SessionSidebarStore {
    /// Builds the 3-level tree (`Workspace ▸ Session/Tab ▸ Split Panes & Subagents`) for the sidebar.
    func workspaceGroups(
        for window: NSWindow?,
        workspaceStore: WorkspaceStore = .shared,
        includeSplitPanes: Bool = true,
        filterText explicitFilterText: String? = nil,
        filterNeedsAttention explicitFilterNeedsAttention: Bool? = nil
    ) -> [SessionSidebarWorkspaceGroup] {
        bindSurfaces(for: window)

        let (windows, selectedWindow) = sidebarWindows(for: window, workspaceStore: workspaceStore)

        let effectiveNeedsAttention = explicitFilterNeedsAttention ?? filterNeedsAttention(for: window)
        let rawQuery = (explicitFilterText ?? filterText(for: window)).trimmingCharacters(in: .whitespacesAndNewlines)
        let query = rawQuery.lowercased()
        let hasActiveFilter = effectiveNeedsAttention || !query.isEmpty

        // Build all uncollapsed base items (without filtering yet so we can group by workspace and expand splits)
        // Rows of every window the sidebar lists: the own group's, then each
        // other group's -- built per group, so each knows its own tabs' order.
        let ownGroup = window.flatMap { Tako.CustomTabGroup.group(for: $0) }
        var baseItems = items(for: window, filterText: "", filterNeedsAttention: false)
        var seenGroups: Set<ObjectIdentifier> = ownGroup.map { [ObjectIdentifier($0)] } ?? []
        for win in windows where !(ownGroup?.windows.contains(win) ?? (win === window)) {
            let group = Tako.CustomTabGroup.group(for: win)
            guard seenGroups.insert(ObjectIdentifier(group)).inserted else { continue }
            let listed = Set(windows.map(\.stableTabIdentifier))
            // A tab the sidebar lists, and the subagent rows under it.
            var keeping = false
            for item in items(for: win, filterText: "", filterNeedsAttention: false) {
                if !item.isChild { keeping = listed.contains(item.id) }
                if keeping { baseItems.append(item) }
            }
        }
        /// Whether `win` is in the window the sidebar is in: only there is a tab the selected one.
        func inOwnGroup(_ win: NSWindow) -> Bool { ownGroup?.windows.contains(win) ?? (win === window) }
        var baseTabById: [String: SessionSidebarItem] = [:]
        var subagentChildrenByTabId: [String: [SessionSidebarItem]] = [:]

        var currentParentTabId: String?
        for item in baseItems {
            if !item.isChild {
                baseTabById[item.id] = item
                currentParentTabId = item.id
            } else if let pTabId = currentParentTabId {
                subagentChildrenByTabId[pTabId, default: []].append(item)
            }
        }

        // Map each window to its workspace (defaulting unassigned tabs to activeWorkspace)
        let activeWs = workspaceStore.activeWorkspace
        var windowsByWorkspace: [UUID: [(index: Int, window: NSWindow)]] = [:]
        for (idx, win) in windows.enumerated() {
            let tabId = win.stableTabIdentifier
            let ws = workspaceStore.workspace(forTab: tabId) ?? activeWs
            windowsByWorkspace[ws.id, default: []].append((idx, win))
        }

        // Preserve workspaceStore order; include workspaces that own tabs or all workspaces when multiple exist
        let candidateWorkspaces: [Workspace] = {
            let all = workspaceStore.workspaces
            if all.isEmpty { return [activeWs] }
            if all.count > 1 { return all }
            return all
        }()

        var groups: [SessionSidebarWorkspaceGroup] = []
        for ws in candidateWorkspaces {
            let wsEntries = windowsByWorkspace[ws.id] ?? []
            if wsEntries.isEmpty && candidateWorkspaces.count == 1 && !windows.isEmpty {
                continue
            }

            // Order tabs according to workspace.tabIdentifiers when explicitly ordered, then remaining in group order
            let orderedEntries: [(index: Int, window: NSWindow)] = {
                guard !ws.tabIdentifiers.isEmpty else { return wsEntries }
                var rank: [String: Int] = [:]
                for (r, tid) in ws.tabIdentifiers.enumerated() { rank[tid] = r }
                return wsEntries.sorted { a, b in
                    let ra = rank[a.window.stableTabIdentifier] ?? (10_000 + a.index)
                    let rb = rank[b.window.stableTabIdentifier] ?? (10_000 + b.index)
                    return ra < rb
                }
            }()

            var totalPanesInWs = 0
            var attentionInWs = 0
            var unreadInWs = 0
            var dominantStatus: Tako.PaneStatus = .idle
            var visibleItems: [SessionSidebarItem] = []

            let wsMatchesQuery = !query.isEmpty && ws.name.lowercased().contains(query)
            let wsCollapsed = isWorkspaceCollapsed(ws.id) && !hasActiveFilter

            for entry in orderedEntries {
                let win = entry.window
                let tabId = win.stableTabIdentifier
                guard let rawTabItem = baseTabById[tabId] else { continue }

                let winSurfaces = surfaces(in: win)
                let paneCount = max(1, winSurfaces.count)
                totalPanesInWs += paneCount
                unreadInWs += rawTabItem.unreadCount
                if rawTabItem.needsAttention || rawTabItem.status == .error || rawTabItem.status == .needsApproval || rawTabItem.status == .waitingForInput {
                    attentionInWs += 1
                }
                if rawTabItem.status.priority > dominantStatus.priority {
                    dominantStatus = rawTabItem.status
                }

                let hasSplitChildren = includeSplitPanes && winSurfaces.count > 1
                let subagentKids = subagentChildrenByTabId[tabId] ?? []
                // Folded subagents are not listed, yet the tab still has them:
                // the chevron stays to unfold them.
                let hasAnyChildren = hasSplitChildren || !subagentKids.isEmpty || rawTabItem.hasChildren
                // Folded as either its splits or its subagents are: a split
                // that is also a subagent is folded by the one chevron.
                let tabCollapsed = (isTabSplitsCollapsed(tabId) || rawTabItem.isCollapsed) && !hasActiveFilter

                let summaryText: String? = {
                    if let existing = rawTabItem.childrenSummary, !existing.isEmpty {
                        return hasSplitChildren ? "\(winSurfaces.count) panes · \(existing)" : existing
                    }
                    return hasSplitChildren ? "\(winSurfaces.count) panes" : nil
                }()

                let tabItem = SessionSidebarItem(
                    id: rawTabItem.id,
                    surfaceId: rawTabItem.surfaceId,
                    surfaceIds: rawTabItem.surfaceIds,
                    index: rawTabItem.index,
                    totalCount: rawTabItem.totalCount,
                    isSelected: rawTabItem.isSelected && inOwnGroup(win),
                    title: rawTabItem.title,
                    status: rawTabItem.status,
                    crabState: rawTabItem.crabState,
                    progress: rawTabItem.progress,
                    progressState: rawTabItem.progressState,
                    live: rawTabItem.live,
                    workingDirectory: rawTabItem.workingDirectory,
                    gitBranch: rawTabItem.gitBranch,
                    gitDirty: rawTabItem.gitDirty,
                    gitChangedFiles: rawTabItem.gitChangedFiles,
                    latestNotification: rawTabItem.latestNotification,
                    userDescription: rawTabItem.userDescription,
                    listeningPorts: rawTabItem.listeningPorts,
                    unreadCount: rawTabItem.unreadCount,
                    needsAttention: rawTabItem.needsAttention,
                    isChild: false,
                    parentId: rawTabItem.parentId,
                    label: rawTabItem.label,
                    hasChildren: hasAnyChildren,
                    isCollapsed: tabCollapsed,
                    childrenSummary: summaryText,
                    indentationLevel: 1,
                    workspaceId: ws.id,
                    tabId: tabId,
                    paneCount: paneCount
                )

                // Build split-pane child nodes (Level 2)
                var childNodes: [SessionSidebarItem] = []
                if hasSplitChildren {
                    let controller = win.windowController as? BaseTerminalController
                    let focused = controller?.focusedSurface ?? (win.firstResponder as? Tako.SurfaceView) ?? winSurfaces.first
                    let isTabSelected = (win === selectedWindow)

                    for (paneIdx, paneSurface) in winSurfaces.enumerated() {
                        let paneTitle: String = {
                            if !paneSurface.titleText.isEmpty { return paneSurface.titleText }
                            if !paneSurface.title.isEmpty { return paneSurface.title }
                            if let d = paneSurface.pwd, !d.isEmpty { return Tako.titleForDirectory(d) }
                            return "Pane \(paneIdx + 1)"
                        }()
                        let pStatus = paneSurface.crab.paneStatus
                        let pUnread = AttentionManager.shared.isMuted(surfaceId: paneSurface.id)
                            ? 0
                            : NotificationStore.shared.unreadCount(for: paneSurface.id)
                        let pAttention = !AttentionManager.shared.isMuted(surfaceId: paneSurface.id) && (
                            pUnread > 0 ||
                            pStatus == .error ||
                            pStatus == .needsApproval ||
                            pStatus == .waitingForInput ||
                            (paneSurface.crab.unread && pStatus != .working && pStatus != .running && pStatus != .idle)
                        )
                        let subLabel = SubagentHierarchyStore.shared.label(for: paneSurface.id) ?? "pane \(paneIdx + 1)"

                        let childPwd: String? = (paneSurface.pwd == rawTabItem.workingDirectory) ? nil : paneSurface.pwd

                        let child = SessionSidebarItem(
                            id: "\(tabId)-pane-\(paneSurface.id.uuidString.lowercased())",
                            surfaceId: paneSurface.id,
                            surfaceIds: [paneSurface.id],
                            index: rawTabItem.index,
                            totalCount: rawTabItem.totalCount,
                            isSelected: isTabSelected && (focused === paneSurface),
                            title: paneTitle,
                            status: pStatus,
                            crabState: paneSurface.crab.state,
                            progress: paneSurface.activeProgressValue.map { Double($0) / 100.0 },
                            progressState: paneSurface.activeProgressState,
                            live: paneSurface.crab.live,
                            workingDirectory: childPwd,
                            unreadCount: pUnread,
                            needsAttention: pAttention,
                            isChild: true,
                            parentId: rawTabItem.surfaceId,
                            label: subLabel,
                            indentationLevel: 2,
                            workspaceId: ws.id,
                            tabId: tabId,
                            paneCount: 1
                        )
                        childNodes.append(child)
                    }
                } else if !subagentKids.isEmpty {
                    childNodes = subagentKids.map { kid in
                        let kidPwd: String? = (kid.workingDirectory == rawTabItem.workingDirectory) ? nil : kid.workingDirectory
                        return SessionSidebarItem(
                            id: kid.id,
                            surfaceId: kid.surfaceId,
                            surfaceIds: kid.surfaceIds,
                            index: kid.index,
                            totalCount: kid.totalCount,
                            isSelected: kid.isSelected && inOwnGroup(win),
                            title: kid.title,
                            status: kid.status,
                            crabState: kid.crabState,
                            progress: kid.progress,
                            progressState: kid.progressState,
                            workingDirectory: kidPwd,
                            unreadCount: kid.unreadCount,
                            needsAttention: kid.needsAttention,
                            isChild: true,
                            parentId: kid.parentId,
                            label: kid.label,
                            indentationLevel: 2,
                            workspaceId: ws.id,
                            tabId: tabId,
                            paneCount: 1
                        )
                    }
                }

                // Filter check for tab and its child panes
                let filteredChildren = childNodes.filter { child in
                    if effectiveNeedsAttention && !child.needsAttention { return false }
                    if !query.isEmpty && !wsMatchesQuery && !matchesFilter(item: child, query: query) { return false }
                    return true
                }

                let tabPassesAttention = !effectiveNeedsAttention || tabItem.needsAttention || !filteredChildren.isEmpty
                let tabPassesQuery = query.isEmpty || wsMatchesQuery || matchesFilter(item: tabItem, query: query) || !filteredChildren.isEmpty

                guard tabPassesAttention && tabPassesQuery else { continue }

                if !wsCollapsed {
                    visibleItems.append(tabItem)
                    if !tabCollapsed {
                        let kidsToAppend = hasActiveFilter ? filteredChildren : childNodes
                        visibleItems.append(contentsOf: kidsToAppend)
                    }
                }
            }

            if hasActiveFilter && visibleItems.isEmpty {
                continue
            }

            groups.append(
                SessionSidebarWorkspaceGroup(
                    id: ws.id,
                    name: ws.name,
                    color: ws.color,
                    icon: ws.icon,
                    isActive: ws.id == workspaceStore.activeWorkspaceId,
                    isCollapsed: wsCollapsed,
                    sessionCount: orderedEntries.count,
                    paneCount: totalPanesInWs,
                    attentionCount: attentionInWs,
                    unreadCount: unreadInWs,
                    dominantStatus: dominantStatus,
                    items: visibleItems
                )
            )
        }

        return groups
    }

    private func matchesFilter(item: SessionSidebarItem, query: String) -> Bool {
        if item.title.lowercased().contains(query) { return true }
        if item.workingDirectory?.lowercased().contains(query) == true { return true }
        if item.gitBranch?.lowercased().contains(query) == true { return true }
        if item.userDescription?.lowercased().contains(query) == true { return true }
        if item.label?.lowercased().contains(query) == true { return true }
        if item.status.rawValue.lowercased().contains(query) { return true }
        if item.status.sidebarBadgeLabel?.lowercased().contains(query) == true { return true }
        return false
    }
}

/// Tree header row for a Workspace in `SessionSidebarView` (Spec 1b §5.4).
struct SessionSidebarWorkspaceHeaderView: View {
    let group: SessionSidebarWorkspaceGroup
    var onToggleCollapse: () -> Void
    var onSelectWorkspace: () -> Void

    private typealias T = Tako.LivingTokens

    private var workspaceDotColor: NSColor {
        T.workspaceColor(for: group.color)
    }

    var body: some View {
        let rowContentHeight: CGFloat = group.attentionCount > 0 ? 15 : 13
        HStack(spacing: 7) {
            Button(action: onToggleCollapse) {
                Text(group.isCollapsed ? "▸" : "▾")
                    .font(Font(T.monoFont(size: 9, weight: .regular)))
                    .foregroundColor(Color(nsColor: T.faint))
                    .frame(width: 10, height: 13, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(group.isCollapsed ? "Expand workspace" : "Collapse workspace")

            HStack(spacing: 7) {
                Circle()
                    .fill(Color(nsColor: workspaceDotColor))
                    .frame(width: 7, height: 7)

                Text(group.name.uppercased())
                    .font(Font(T.monoFont(size: 10, weight: .bold)))
                    .tracking(0.8)
                    .foregroundColor(Color(nsColor: T.dim))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)

                Spacer(minLength: 4)

                HStack(spacing: 6) {
                    if group.attentionCount > 0 {
                        let countStr = group.attentionCount > 9 ? "9+" : "\(group.attentionCount)"
                        Text(countStr)
                            .font(Font(T.monoFont(size: 9.5, weight: .bold)))
                            .foregroundColor(Color(nsColor: T.ink))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: T.claw)))
                    }

                    Text("\(group.sessionCount)")
                        .font(Font(T.monoFont(size: 10, weight: .medium)))
                        .foregroundColor(Color(nsColor: T.dim))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelectWorkspace)
        }
        .frame(height: rowContentHeight)
        .padding(.top, 10)
        .padding(.horizontal, 14)
        .padding(.bottom, 5)
    }
}
