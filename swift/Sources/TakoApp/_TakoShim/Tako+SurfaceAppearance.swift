/*
 * tako — Live scoped terminal appearance
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import SwiftUI

extension Tako.SurfaceView {
    func applyScopedTheme(_ global: TerminalTheme, store: ScopedAppearanceStore, workspaceID: UUID?) {
        let effective = store.effectiveTheme(global: global, workspaceID: workspaceID, paneID: id)
        configuredTheme = effective
        applyTheme(effective)
        derivedConfig.backgroundColor = Color(nsColor: NSColor(cgColor: effective.background) ?? .black)
    }

    var appearanceWorkspaceID: UUID? {
        let controller = window?.windowController as? TerminalController
            ?? TerminalController.all.first { $0.surfaceTree.contains { $0 === self } }
        guard let tab = controller?.window?.stableTabIdentifier else { return nil }
        return WorkspaceStore.shared.workspace(forTab: tab)?.id ?? WorkspaceStore.shared.activeWorkspaceId
    }
}

/// Held in the surface's existing configObserver slot. This keeps all tokens
/// tied to its lifetime, including panes that have not mounted in a window.
@MainActor final class SurfaceAppearanceObservation: NSObject {
    private weak var surface: Tako.SurfaceView?
    private var tokens: [NSObjectProtocol] = []
    private var lastOverrides: [String?]?
    private let initialTheme: TerminalTheme
    private let store: ScopedAppearanceStore
    private let workspace: () -> UUID?

    var hasScopedFontSize: Bool {
        guard let surface else { return false }
        return store.value(for: "font-size", scope: .pane(surface.id)) != nil
            || workspace().flatMap { store.value(for: "font-size", scope: .workspace($0)) } != nil
    }

    init(surface: Tako.SurfaceView, store: ScopedAppearanceStore = .shared, workspaceID: (() -> UUID?)? = nil) {
        self.surface = surface
        self.initialTheme = surface.theme
        self.store = store
        self.workspace = workspaceID ?? { [weak surface] in surface?.appearanceWorkspaceID }
        super.init()
        for name in [Notification.Name.takoConfigDidChange, .takoScopedAppearanceDidChange,
                     .takoWorkspaceDidChange, .takoTabsDidChange] {
            tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.receive(note) }
                } else {
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(note) } }
                }
            })
        }
        // The controller assigns a new pane to a workspace after constructing
        // it. Resolve after that assignment, before its first visible frame.
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    private func receive(_ note: Notification) {
        if note.name == .takoConfigDidChange {
            if let config = note.userInfo?[Notification.Name.TakoConfigChangeKey] as? Tako.Config {
                surface?.configDidReload(config)
            }
        } else if note.name == .takoScopedAppearanceDidChange {
            refresh()
        } else {
            refresh()
            DispatchQueue.main.async { [weak self] in self?.refresh() }
        }
    }

    private func refresh() {
        guard let surface else { return }
        let workspaceID = workspace()
        let keys = ScopedAppearanceContext.keys.sorted()
        let values = keys.map { key in workspaceID.flatMap { store.value(for: key, scope: .workspace($0)) } }
            + keys.map { store.value(for: $0, scope: .pane(surface.id)) }
        guard values != lastOverrides else { return }
        let hadOverrides = lastOverrides?.contains { $0 != nil } ?? false
        lastOverrides = values
        // Unstyled terminals retain transient zoom when unrelated tabs move.
        guard hadOverrides || values.contains(where: { $0 != nil }) else { return }
        surface.applyScopedTheme(surface.app?.config.theme ?? initialTheme, store: store, workspaceID: workspaceID)
        (surface.window?.windowController as? TerminalController)?.syncAppearance()
    }

    deinit { tokens.forEach { NotificationCenter.default.removeObserver($0) } }
}
