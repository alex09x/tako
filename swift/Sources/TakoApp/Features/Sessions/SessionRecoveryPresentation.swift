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

/// Presents sessions that survived but were not represented by restored panes.
@MainActor
enum SessionRecoveryPresentation {
    private static var busy = false
    private static var warnedAboutWorkspacePersistence = false
    private static var warnedAboutLayoutPersistence = false

    /// A disconnected placeholder must remain discoverable so its missing
    /// or damaged record can be adopted without creating a duplicate pane.
    static func protectedSurfaceIDs(_ surfaces: [Tako.SurfaceView]) -> Set<UUID> {
        Set(surfaces.filter { ($0.sessionRetry == nil || $0.pty != nil) && $0.persistence == nil }.map(\.id))
    }

    static func protectedRuntimes(_ surfaces: [Tako.SurfaceView]) -> [UUID: String] {
        surfaces.reduce(into: [:]) { result, surface in
            if (surface.sessionRetry == nil || surface.pty != nil), let session = surface.persistence {
                result[surface.id] = session.namespace.runtimeID
            }
        }
    }

    static func scanAndPresent(app: Tako.App, openIDs: Set<UUID>, showEmpty: Bool = false) {
        guard !busy else { return }
        busy = true
        let records = SessionPlaces.records
        let registry = SessionPlaces.registry
        let home = SessionPlaces.home
        let openRuntimes = protectedRuntimes(TerminalController.all.flatMap { Array($0.surfaceTree) })
        Task { @MainActor in
            defer { busy = false }
            guard await warnIfNeeded(app: app) else { return }
            guard app.config.sessionPersistence || showEmpty else { return }
            let candidates: [SessionRecoveryInventory.Candidate] = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let client = try? registry.guardedClient(in: Bundle.main.bundleURL)
                    continuation.resume(returning: SessionRecoveryInventory.scan(
                        records: records, registry: registry, guardedRuntime: client, home: home,
                        openIDs: openIDs, openRuntimes: openRuntimes))
                }
            }
            await present(candidates, app: app, records: records, showEmpty: showEmpty)
        }
    }

    private static func warnIfNeeded(app: Tako.App) async -> Bool {
        let layoutWarning = !LayoutRecorder.persistenceAvailable && !warnedAboutLayoutPersistence
        let workspaceWarning = !WorkspaceStore.shared.persistenceAvailable && !warnedAboutWorkspacePersistence
        guard layoutWarning || workspaceWarning else { return true }
        guard let window = await noticeWindow() else { return false }
        if layoutWarning {
            warnedAboutLayoutPersistence = true
            _ = await TerminalDialogView.choose(in: window, title: "Window Layout Not Saved",
                lines: TUIText.plain("Tako could not safely preserve the previous layout. Window changes will not be saved; the previous layout was left untouched.", width: 56),
                choices: [.init(title: "OK", kind: .normal)], cancelIndex: 0, theme: app.config.theme)
            guard window.isVisible else { return false }
        }
        if workspaceWarning {
            warnedAboutWorkspacePersistence = true
            _ = await TerminalDialogView.choose(in: window, title: "Workspaces Not Saved",
                lines: TUIText.plain("Workspace data could not be safely loaded or backed up. Changes will not be saved. Fix storage and restart Tako; the original file was left untouched.", width: 56),
                choices: [.init(title: "OK", kind: .normal)], cancelIndex: 0, theme: app.config.theme)
        }
        return window.isVisible
    }

    private static func noticeWindow() async -> NSWindow? {
        var window = AppUpdater.noticeWindow(key: NSApp.keyWindow, windows: NSApp.windows)
            ?? TerminalController.preferredParent?.window
        for _ in 0..<150 where window == nil {
            if Task.isCancelled { return nil }
            try? await Task.sleep(nanoseconds: 100_000_000)
            window = AppUpdater.noticeWindow(key: NSApp.keyWindow, windows: NSApp.windows)
                ?? TerminalController.preferredParent?.window
        }
        return window
    }

    private static func present(_ candidates: [SessionRecoveryInventory.Candidate], app: Tako.App,
                                records: SessionRecordStore, showEmpty: Bool) async {
        // Windows may have appeared while the runtime scan was in flight.
        let surfaces = TerminalController.all.flatMap { Array($0.surfaceTree) }
        let current = protectedSurfaceIDs(surfaces)
        let currentRuntimes = protectedRuntimes(surfaces)
        let existing = Set(surfaces.map(\.id))
        let discovered = candidates.filter {
            $0.observedInRuntime && !current.contains($0.id) && currentRuntimes[$0.id] != $0.runtimeID &&
                !($0.identity == .unavailable && existing.contains($0.id)) &&
                (showEmpty || $0.identity != .unavailable || $0.record != nil)
        }
        guard (!discovered.isEmpty || showEmpty), let window = await noticeWindow() else { return }
        guard !discovered.isEmpty || showEmpty else { return }
        guard app.config.sessionPersistence else {
            _ = await TerminalDialogView.choose(in: window, title: "Session Recovery",
                lines: TUIText.plain("Session persistence is disabled. Enable it before reconnecting saved sessions.", width: 56),
                choices: [.init(title: "OK", kind: .normal)], cancelIndex: 0, theme: app.config.theme)
            return
        }
        let verified = discovered.filter { $0.identity == .verified && $0.record != nil }
        let adoptable = discovered.filter {
            $0.identity == .unverified &&
                ($0.observedGeneration.map(SessionRecoveryInventory.isGeneration) ?? false)
        }
        let uncertain = discovered.count - verified.count - adoptable.count
        var message = "Tako found \(verified.count) sessions matching saved records outside the restored windows."
        if !adoptable.isEmpty {
            message += " \(adoptable.count) sessions have no matching record and require individual confirmation."
        }
        if uncertain > 0 {
            message += " \(uncertain) more could not be verified; they will be kept untouched."
        }
        guard !verified.isEmpty || !adoptable.isEmpty else {
            _ = await TerminalDialogView.choose(in: window, title: "Session Recovery",
                lines: TUIText.plain(message, width: 56), choices: [.init(title: "OK", kind: .normal)],
                cancelIndex: 0, theme: app.config.theme)
            return
        }
        let answer = await TerminalDialogView.choose(in: window, title: "Session Recovery",
            lines: TUIText.plain(message + " Review and restore these sessions?", width: 56),
            choices: [.init(title: "Later", kind: .normal), .init(title: "Restore", kind: .primary)],
            selected: 0, cancelIndex: 0, theme: app.config.theme)
        guard answer == 1 else { return }
        for candidate in verified {
            if let saved = candidate.record {
                restore(saved, app: app, records: records)
                Tako.CustomTabGroup.hideAllInactiveWindows()
            }
        }
        for candidate in adoptable {
            guard let currentWindow = AppUpdater.noticeWindow(key: NSApp.keyWindow, windows: NSApp.windows)
                    ?? TerminalController.preferredParent?.window else { break }
            let process = candidate.processID.map { " PID \($0)." } ?? ""
            let command = candidate.executableName.map { " Program: \($0)." } ?? ""
            let detail = "Session \(candidate.id.uuidString). Runtime: \(candidate.runtimeID).\(process)\(command) It has no matching record. Adopt it and try to reconnect? Any previous record is kept in history."
            let choice = await TerminalDialogView.choose(in: currentWindow, title: "Unverified Session",
                lines: TUIText.plain(detail, width: 56),
                choices: [.init(title: "Leave Running", kind: .normal), .init(title: "Adopt", kind: .primary)],
                selected: 0, cancelIndex: 0, theme: app.config.theme)
            guard let choice else { break }
            guard choice == 1 else { continue }
            guard preparePlaceholderForAdoption(candidate) else {
                _ = await TerminalDialogView.choose(in: currentWindow, title: "Session Not Adopted",
                    lines: TUIText.plain("A session with this pane ID is open or still connecting. Close that tab before adopting this one. Both were left running.", width: 56),
                    choices: [.init(title: "OK", kind: .normal)], cancelIndex: 0, theme: app.config.theme)
                continue
            }
            let registry = SessionPlaces.registry, home = SessionPlaces.home
            let adopted: SessionRecord? = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let client = try? registry.guardedClient(in: Bundle.main.bundleURL)
                    let adopted = client.flatMap { try? SessionRecoveryInventory.adopt(
                        candidate, records: records, guardedRuntime: $0, home: home) }
                    continuation.resume(returning: adopted)
                }
            }
            if let adopted {
                restore(adopted, app: app, records: records)
                Tako.CustomTabGroup.hideAllInactiveWindows()
            } else {
                _ = await TerminalDialogView.choose(in: currentWindow, title: "Session Not Adopted",
                    lines: TUIText.plain("The session changed, is in use, or its record could not be saved. It was left running.", width: 56),
                    choices: [.init(title: "OK", kind: .normal)], cancelIndex: 0, theme: app.config.theme)
            }
        }
        Tako.CustomTabGroup.hideAllInactiveWindows()
    }

    /// Release only this app's disconnected placeholder; a live or foreign
    /// owner must never be displaced to adopt a candidate.
    static func preparePlaceholderForAdoption(_ candidate: SessionRecoveryInventory.Candidate) -> Bool {
        guard let existing = TerminalController.all.flatMap({ Array($0.surfaceTree) }).first(where: { $0.id == candidate.id }) else {
            return true
        }
        guard existing.pty == nil else { return false }
        guard let session = existing.persistence else { return true }
        guard !session.confirmedLive else { return false }
        let workingDirectory = session.record.workingDirectory
        let snapshot = (NSApp?.delegate as? AppDelegate)?.tako.config.windowSaveContent == true
            ? SessionSnapshotStore.shared.read(id: existing.id) : nil
        session.ended = true
        (NSApp?.delegate as? AppDelegate)?.sessionSaver.protect(id: existing.id)
        existing.persistence = nil
        existing.sessionRetry = { [weak existing] in
            guard let existing else { return }
            existing.sessionRetry = nil
            existing.launchPersistentSession(workingDir: workingDirectory, snapshot: snapshot,
                                             restored: true, hadPersistentSession: true)
        }
        return true
    }

    private static func restore(_ saved: SessionRecord, app: Tako.App, records: SessionRecordStore) {
        guard case .record(let current) = records.read(saved.id),
              current.runtimeID == saved.runtimeID, current.generation == saved.generation
        else { return }
        if let existing = TerminalController.all.flatMap({ Array($0.surfaceTree) }).first(where: { $0.id == saved.id }) {
            guard existing.pty == nil else { return }
            if let session = existing.persistence,
               session.record.runtimeID != saved.runtimeID || session.record.generation != saved.generation {
                session.ended = true
                existing.persistence = nil
                existing.sessionRetry = nil
                let snapshot = app.config.windowSaveContent ? SessionSnapshotStore.shared.read(id: saved.id) : nil
                // Release the previous owner's flock before opening the new identity.
                DispatchQueue.main.async { [weak existing] in
                    existing?.launchPersistentSession(workingDir: saved.workingDirectory, snapshot: snapshot,
                                                      restored: true, hadPersistentSession: true)
                }
            } else {
                existing.sessionRetry?()
            }
            return
        }
        var base = Tako.SurfaceConfiguration()
        base.isRestored = true
        base.hadPersistentSession = true
        base.workingDirectory = Tako.SurfaceView.restoredWorkingDirectory(
            saved.workingDirectory, fallback: Tako.resolvedWorkingDirectory(app.config))
        if app.config.windowSaveContent {
            base.restoredSnapshot = SessionSnapshotStore.shared.read(id: saved.id)
        }
        let surface = Tako.SurfaceView(app, baseConfig: base, uuid: saved.id)
        let controller = TerminalController(app, withSurfaceTree: SplitTree(view: surface))
        TerminalController.system.attachWindow(controller)
        guard let recovered = controller.window else {
            surface.persistence?.ended = true
            surface.close()
            return
        }
        if let tabID = saved.tabIdentifier,
           !TerminalController.all.contains(where: { $0.window !== recovered && $0.window?.stableTabIdentifier == tabID }) {
            let provisional = recovered.stableTabIdentifier
            recovered.stableTabIdentifier = tabID
            if provisional != tabID, WorkspaceStore.shared.workspace(forTab: provisional) != nil {
                WorkspaceStore.shared.removeTab(tabIdentifier: provisional)
            }
        }
        let workspaceID = saved.workspaceID.flatMap { WorkspaceStore.shared.workspace(for: $0)?.id }
            ?? WorkspaceStore.shared.activeWorkspaceId
        if WorkspaceStore.shared.workspace(forTab: recovered.stableTabIdentifier)?.id != workspaceID {
            WorkspaceStore.shared.assignTab(tabIdentifier: recovered.stableTabIdentifier, to: workspaceID)
        }
        controller.showWindow(nil)
    }
}
