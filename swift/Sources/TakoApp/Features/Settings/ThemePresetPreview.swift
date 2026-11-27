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
import TakoCoreUI

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
    /// The editor this preview belongs to; once it is gone nothing is applied.
    private weak var owner: AnyObject?
    /// The level being edited, fixed when the preview opens (nil = global).
    private let scope: AppearanceScope?
    private var closeObserver: NSObjectProtocol?

    convenience init(owner: TerminalSettingsDialog, targets: [Tako.SurfaceView]? = nil) {
        self.init(owner: owner, scope: owner.scopedAppearance?.scope, window: owner.window, targets: targets)
    }

    /// Targets are chosen once, here: the live panes of `window`'s app that
    /// the scope reaches. Closing `window` restores them.
    init(owner: AnyObject, scope: AppearanceScope?, window: NSWindow?, targets: [Tako.SurfaceView]? = nil) {
        self.owner = owner
        self.scope = scope
        self.styles = ScopedAppearanceStore.shared.document
        let app = (window?.windowController as? TerminalController)?.tako
        let surfaces = targets ?? TerminalController.all.filter { app == nil || $0.tako === app }
            .flatMap { Array($0.surfaceTree) }.filter { surface in
                switch scope {
                case .workspace(let id): return surface.appearanceWorkspaceID == id
                case .session(let id): return surface.appearanceSessionID.map(AppearanceScope.sessionKey) == AppearanceScope.sessionKey(id)
                case .pane(let id): return surface.id == id
                case nil: return true
                }
            }
        snapshots = surfaces.map {
            Snapshot(surface: $0, theme: $0.theme, derived: $0.derivedConfig,
                     background: $0.backgroundColor, appConfig: $0.app?.config)
        }
        Self.active.add(self)
        // Without a window, object: nil would match every window's close.
        guard let window else { return }
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
            object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.restore() }
            }
    }

    @discardableResult func apply(_ draft: TerminalTheme) -> Int {
        guard owner != nil else { return 0 }
        var count = 0
        for snapshot in snapshots {
            guard let surface = snapshot.surface else { continue }
            let theme = resolved(draft, for: surface)
            surface.applyTheme(theme)
            surface.backgroundColor = nil
            surface.derivedConfig.backgroundColor = Color(nsColor: NSColor(cgColor: theme.background) ?? .black)
            (surface.window?.windowController as? TerminalController)?.syncAppearance()
            refreshTabs(for: surface.window)
            count += 1
        }
        applied = count > 0
        Tako.TabBarController.refreshAll()
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
            refreshTabs(for: surface.window)
        }
        Tako.TabBarController.refreshAll()
    }

    private func refreshTabs(for window: NSWindow?) {
        guard let window else { return }
        if let bar = Tako.TabBarController.bar(for: window) {
            bar.layoutTabs()
            bar.refresh()
        }
        if let contentView = window.contentView {
            for sub in contentView.subviews {
                if let bar = sub as? Tako.TabBarView {
                    bar.layoutTabs()
                    bar.refresh()
                }
            }
        }
    }

    /// Number of live panes this preview would change.
    var targetCount: Int { snapshots.filter { $0.surface != nil }.count }

    private func resolved(_ draft: TerminalTheme, for surface: Tako.SurfaceView) -> TerminalTheme {
        let store = ScopedAppearanceStore.shared
        let workspace = surface.appearanceWorkspaceID
        var workspaceFields = workspace.flatMap { store.document.overrides(for: .workspace($0)) }
        var sessionFields = surface.appearanceSessionID.flatMap { store.document.overrides(for: .session($0)) }
        var paneFields = store.document.overrides(for: .pane(surface.id))
        var global = surface.app?.config.theme ?? surface.configuredTheme ?? surface.theme
        var appearance = draft
        appearance.graphemeWidthMethod = global.graphemeWidthMethod
        let previewName = "__tako_unsaved_preview__"
        var replacements: [String: TerminalTheme] = [:]
        switch scope {
        case .workspace:
            workspaceFields = ["theme": previewName]
            replacements[previewName] = appearance
        case .session:
            sessionFields = ["theme": previewName]
            replacements[previewName] = appearance
        case .pane:
            paneFields = ["theme": previewName]
            replacements[previewName] = appearance
        case nil:
            global = appearance
        }
        return ScopedAppearanceResolver.resolve(global: global, workspaceOverrides: workspaceFields,
            sessionOverrides: sessionFields, paneOverrides: paneFields, themeOverrides: replacements)
    }

    deinit { if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) } }
}
