/*
 * tako — Shared appearance-menu metadata, independent of terminal status ticks
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Combine

/// Sidebar context-menu builders are evaluated even while their menus are closed.
/// Filesystem discovery must follow configuration/catalog changes, not each row's
/// status publication. Scope selection remains live; only disk metadata is cached.
@MainActor
final class DesktopAppearanceMenuCatalog {
    struct Snapshot: Equatable {
        let paths: [String]
        let names: [String]
        let globalTheme: String
    }

    static let shared = DesktopAppearanceMenuCatalog()
    private let load: (String?) -> Snapshot
    private var snapshots: [String: Snapshot] = [:]
    private var observations = Set<AnyCancellable>()

    init(notifications: NotificationCenter = .default,
         load: @escaping (String?) -> Snapshot = DesktopAppearanceMenuCatalog.read) {
        self.load = load
        for name in [Notification.Name.takoThemePresetsDidChange, .takoConfigDidChange] {
            notifications.publisher(for: name).sink { [weak self] _ in
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.snapshots.removeAll() }
                } else {
                    Task { @MainActor [weak self] in self?.snapshots.removeAll() }
                }
            }.store(in: &observations)
        }
    }

    func snapshot(configPath: String?) -> Snapshot {
        let key = configPath ?? "\0default"
        if let snapshot = snapshots[key] { return snapshot }
        let snapshot = load(configPath)
        // One runtime normally uses one config. Bound retained test/alternate profiles.
        if snapshots.count >= 8 { snapshots.removeAll() }
        snapshots[key] = snapshot
        return snapshot
    }

    private static func read(configPath: String?) -> Snapshot {
        let file = KeybindConfigFile(configPath: configPath)
        let paths = file.appearanceThemePaths
        let theme = DesktopPreferenceStore.item("theme").flatMap { file.getSettingValue(for: $0) } ?? "TakoCore"
        return Snapshot(paths: paths, names: TerminalAppearanceCatalog.themeNames(paths: paths), globalTheme: theme)
    }
}
