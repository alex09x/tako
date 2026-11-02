/*
 * tako — Reversible live theme preview
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import SwiftUI

@MainActor final class ThemePresetPreview {
    private static let active = NSHashTable<ThemePresetPreview>.weakObjects()
    static func restoreAll() { active.allObjects.forEach { $0.restore() } }

    private struct Snapshot {
        weak var surface: Tako.SurfaceView?
        let theme: TerminalTheme
        let derived: Tako.SurfaceView.DerivedConfig
        let background: Color?
        let appConfig: Tako.Config?
    }
    private let snapshots: [Snapshot]
    private let styles: AppearanceDocument
    private var applied = false
    private weak var owner: TerminalSettingsDialog?
    private var closeObserver: NSObjectProtocol?

    init(owner: TerminalSettingsDialog, targets: [Tako.SurfaceView]? = nil) {
        self.owner = owner
        self.styles = ScopedAppearanceStore.shared.document
        let scope = owner.scopedAppearance?.scope
        let app = (owner.window?.windowController as? TerminalController)?.tako
        let surfaces = targets ?? TerminalController.all.filter { app == nil || $0.tako === app }
            .flatMap { Array($0.surfaceTree) }.filter { surface in
                switch scope {
                case .workspace(let id): return surface.appearanceWorkspaceID == id
                case .pane(let id): return surface.id == id
                case nil: return true
                }
            }
        snapshots = surfaces.map {
            Snapshot(surface: $0, theme: $0.theme, derived: $0.derivedConfig,
                     background: $0.backgroundColor, appConfig: $0.app?.config)
        }
        Self.active.add(self)
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
            object: owner.window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restore() }
            }
    }

    @discardableResult func apply(_ draft: TerminalTheme) -> Int {
        guard let owner else { return 0 }
        var count = 0
        for snapshot in snapshots {
            guard let surface = snapshot.surface else { continue }
            let theme = resolved(draft, for: surface, owner: owner)
            surface.applyTheme(theme)
            surface.backgroundColor = nil
            surface.derivedConfig.backgroundColor = Color(nsColor: NSColor(cgColor: theme.background) ?? .black)
            (surface.window?.windowController as? TerminalController)?.syncAppearance()
            count += 1
        }
        applied = count > 0
        return count
    }

    func restore() {
        guard applied else { return }
        applied = false
        for snapshot in snapshots {
            guard let surface = snapshot.surface else { continue }
            if surface.app?.config === snapshot.appConfig, styles == ScopedAppearanceStore.shared.document {
                surface.applyTheme(snapshot.theme)
                surface.backgroundColor = snapshot.background
                surface.derivedConfig = snapshot.derived
            } else if let config = surface.app?.config {
                surface.updateTheme(config.theme)
            }
            (surface.window?.windowController as? TerminalController)?.syncAppearance()
        }
    }

    private func resolved(_ draft: TerminalTheme, for surface: Tako.SurfaceView, owner: TerminalSettingsDialog) -> TerminalTheme {
        let store = ScopedAppearanceStore.shared
        let workspace = surface.appearanceWorkspaceID
        var workspaceFields = workspace.flatMap { store.document.overrides(for: .workspace($0)) }
        var paneFields = store.document.overrides(for: .pane(surface.id))
        var global = surface.app?.config.theme ?? .takoDefault
        let previewName = "__tako_unsaved_preview__"
        var replacements: [String: TerminalTheme] = [:]
        switch owner.scopedAppearance?.scope {
        case .workspace:
            workspaceFields = ["theme": previewName]
            replacements[previewName] = draft
        case .pane:
            paneFields = ["theme": previewName]
            replacements[previewName] = draft
        case nil:
            global = draft
        }
        return ScopedAppearanceResolver.resolve(global: global, workspaceOverrides: workspaceFields,
            paneOverrides: paneFields, themeOverrides: replacements)
    }

    deinit { if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) } }
}
