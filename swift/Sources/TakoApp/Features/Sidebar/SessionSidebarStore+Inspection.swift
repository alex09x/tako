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
}
