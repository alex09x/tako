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
import TakoKit

extension SessionSidebarStore {
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

            let parentSurface = winSurfaces.first(where: { SubagentHierarchyStore.shared.hasChildren($0.id) }) ?? surface
            let pId = parentSurface?.id
            let hasKids = pId != nil && SubagentHierarchyStore.shared.hasChildren(pId!)
            let isCollapsed = pId != nil && SubagentHierarchyStore.shared.isCollapsed(pId!)
            let kidsSummary = pId != nil ? SubagentHierarchyStore.shared.statusSummary(for: pId!) : nil

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
                needsAttention: needsAttention,
                hasChildren: hasKids,
                isCollapsed: isCollapsed,
                childrenSummary: kidsSummary
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

            // Subagent child items when not collapsed (C5)
            if hasKids && !isCollapsed, let pId {
                for cid in SubagentHierarchyStore.shared.children(of: pId) {
                    let cSurface = winSurfaces.first(where: { $0.id == cid })
                    let cLabel = SubagentHierarchyStore.shared.label(for: cid)
                    let cTitle = cSurface?.title ?? cLabel ?? "subagent"
                    let cStatus = cSurface?.crab.paneStatus ?? .idle
                    let cCrabState = cSurface?.crab.state ?? .idle
                    let cElapsed = cSurface?.crab.elapsedLabel
                    let cPwd = cSurface?.pwd
                    let cIsSelected = isSelected && (focused?.id == cid)
                    let cNeedsAttention = cSurface != nil && (
                        cSurface!.crab.unread ||
                        cSurface!.crab.paneStatus == .needsApproval ||
                        cSurface!.crab.paneStatus == .waitingForInput
                    )
                    let cItem = SessionSidebarItem(
                        id: "\(id)-child-\(cid.uuidString.lowercased())",
                        surfaceId: cid,
                        surfaceIds: [cid],
                        index: index,
                        totalCount: windows.count,
                        isSelected: cIsSelected,
                        title: cTitle,
                        status: cStatus,
                        crabState: cCrabState,
                        elapsed: cElapsed,
                        workingDirectory: cPwd,
                        needsAttention: cNeedsAttention,
                        isChild: true,
                        parentId: pId,
                        label: cLabel,
                        indentationLevel: 1
                    )
                    if effectiveNeedsAttention && !cItem.needsAttention {
                        continue
                    }
                    if !effectiveFilterText.isEmpty {
                        let query = effectiveFilterText.lowercased()
                        let matchesTitle = cItem.title.lowercased().contains(query)
                        let matchesPwd = cItem.workingDirectory?.lowercased().contains(query) ?? false
                        let matchesLabel = cLabel?.lowercased().contains(query) ?? false
                        if !matchesTitle && !matchesPwd && !matchesLabel {
                            continue
                        }
                    }
                    result.append(cItem)
                }
            }
        }

        return result
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
