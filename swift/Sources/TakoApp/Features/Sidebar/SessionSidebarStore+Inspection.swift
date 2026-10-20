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

extension SessionSidebarStore {
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
                Self.rowChanges(of: s)
                    .sink { [weak self] in self?.objectWillChange.send() }
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
                            if let pid = s.foregroundProcess?.pid ?? s.shellProcessID {
                                self.invalidatePortsCache(for: pid)
                            }
                        }
                        self.objectWillChange.send()
                    }
            )
            surfaceSubscriptions[sid] = subs
        }
    }
}

extension SessionSidebarStore {
    /// A pane's changes that its row shows. A working pane's clock ticks
    /// twice a second and its output streams; passed on as they came, each
    /// rebuilt every row of the sidebar.
    static func rowChanges(of s: Tako.SurfaceView) -> AnyPublisher<Void, Never> {
        s.objectWillChange.map { _ in () }
            .merge(with: s.crab.objectWillChange.map { _ in () })
            .receive(on: RunLoop.main)
            .compactMap { [weak s] _ in MainActor.assumeIsolated { s.map(SidebarPaneSignature.init) } }
            .prepend(SidebarPaneSignature(s))
            .removeDuplicates()
            .dropFirst()
            .map { _ in () }
            .eraseToAnyPublisher()
    }
}

/// What a sidebar row shows of one pane. The sidebar shows no timer, so a
/// crab's elapsed time is not part of it, nor is the pane's output.
struct SidebarPaneSignature: Equatable {
    let title: String
    let pwd: String?
    let muted: Bool
    let progressState: TakoTerminalNSView.ProgressState
    let progressValue: Int?
    let paneStatus: Tako.PaneStatus
    let crabState: Tako.CrabState
    let crabProgressState: TakoTerminalNSView.ProgressState
    let crabProgress: Int?
    let unread: Bool
    let statusText: String?
    let live: Tako.LiveActivity?

    @MainActor init(_ s: Tako.SurfaceView) {
        title = s.title
        pwd = s.pwd
        muted = s.isAttentionMuted
        progressState = s.activeProgressState
        progressValue = s.activeProgressValue
        paneStatus = s.crab.paneStatus
        crabState = s.crab.state
        crabProgressState = s.crab.progressState
        crabProgress = s.crab.progress
        unread = s.crab.unread
        statusText = s.crab.statusText
        live = s.crab.live
    }
}
