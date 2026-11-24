/*
 * tako — Desktop settings appearance levels: Global › workspace › session › terminal
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit

/// One level the appearance page can edit. The chain is taken once from the
/// terminal the settings were opened over and kept while switching levels.
struct DesktopScopeLevel: Identifiable, Equatable {
    enum Kind: Equatable {
        case global
        case workspace(UUID)
        case session(String)
        case pane(UUID)
    }

    let kind: Kind
    /// «workspace», «session», «terminal»; nil for Global.
    let kindTitle: String?
    let name: String
    /// A pane's session, shown after its name («in session tako»).
    var note: String?

    var id: String {
        switch kind {
        case .global: "global"
        case .workspace(let id): "workspace:\(id.uuidString.lowercased())"
        case .session(let id): "session:\(id)"
        case .pane(let id): "pane:\(id.uuidString.lowercased())"
        }
    }

    var scope: AppearanceScope? {
        switch kind {
        case .global: nil
        case .workspace(let id): .workspace(id)
        case .session(let id): .session(id)
        case .pane(let id): .pane(id)
        }
    }

    static let global = DesktopScopeLevel(kind: .global, kindTitle: nil, name: "Global")

    /// Global › workspace › session › terminal for `surface`, levels it has.
    @MainActor
    static func chain(for surface: Tako.SurfaceView?, window: NSWindow?) -> [DesktopScopeLevel] {
        guard let surface else { return [.global] }
        var levels: [DesktopScopeLevel] = [.global]
        let sessionTitle = window?.title.isEmpty == false ? window!.title : nil
        if let ws = surface.appearanceWorkspaceID, let workspace = WorkspaceStore.shared.workspace(for: ws) {
            levels.append(.init(kind: .workspace(ws), kindTitle: "workspace", name: workspace.name))
        }
        if let session = surface.appearanceSessionID {
            levels.append(.init(kind: .session(session), kindTitle: "session", name: sessionTitle ?? "session"))
        }
        let paneTitle = surface.title.isEmpty ? "terminal" : surface.title
        levels.append(.init(kind: .pane(surface.id), kindTitle: "terminal", name: paneTitle,
                            note: sessionTitle.map { "in session \($0)" }))
        return levels
    }

    /// The editing context for this level; nil for Global (the config file).
    @MainActor
    func context(app: Tako.App?, store: ScopedAppearanceStore = .shared) -> ScopedAppearanceContext? {
        let global: () -> TerminalTheme = { [weak app] in app?.config.theme ?? .takoDefault }
        let title = kindTitle.map { "\($0) «\(name)»" } ?? name
        switch kind {
        case .global:
            return nil
        case .workspace(let id):
            return ScopedAppearanceContext(scope: .workspace(id), title: title, store: store, globalTheme: global,
                                           isAvailable: { WorkspaceStore.shared.workspace(for: id) != nil })
        case .session(let id):
            let surface = Self.liveSurface { $0.appearanceSessionID.map(AppearanceScope.sessionKey) == AppearanceScope.sessionKey(id) }
            return ScopedAppearanceContext(scope: .session(id), title: title, store: store, globalTheme: global,
                                           workspaceID: { [weak surface] in surface?.appearanceWorkspaceID },
                                           isAvailable: { [weak surface] in surface != nil })
        case .pane(let id):
            let surface = Self.liveSurface { $0.id == id }
            return ScopedAppearanceContext(scope: .pane(id), title: title, store: store,
                globalTheme: { [weak surface] in surface?.app?.config.theme ?? global() },
                workspaceID: { [weak surface] in surface?.appearanceWorkspaceID },
                sessionID: { [weak surface] in surface?.appearanceSessionID },
                isAvailable: { [weak surface] in surface != nil && Self.liveSurface({ $0.id == id }) != nil })
        }
    }

    @MainActor
    private static func liveSurface(_ match: (Tako.SurfaceView) -> Bool) -> Tako.SurfaceView? {
        TerminalController.all.lazy.flatMap { Array($0.surfaceTree) }.first(where: match)
    }

    /// Whether this level stores anything of its own (theme or fields).
    @MainActor
    func hasOwnOverrides(store: ScopedAppearanceStore, configFile: KeybindConfigFile) -> Bool {
        guard let scope else {
            return ScopedAppearanceContext.keys.contains { key in
                DesktopPreferenceStore.item(key).flatMap { configFile.getSettingValue(for: $0) } != nil
            }
        }
        return store.document.overrides(for: scope)?.isEmpty == false
    }
}
