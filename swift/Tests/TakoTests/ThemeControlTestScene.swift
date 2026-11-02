/*
 * tako — Isolated CLI theme control fixtures
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Foundation
@testable import Tako

@MainActor final class ThemeControlTestScene {
    final class Counter { var value = 0 }
    let root: URL
    let config: URL
    let builtins: URL
    let workspaces: WorkspaceStore
    let styles: ScopedAppearanceStore
    let service: ThemeControlService
    let counter: Counter

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        config = root.appendingPathComponent("config")
        builtins = root.appendingPathComponent("builtins")
        try FileManager.default.createDirectory(at: builtins, withIntermediateDirectories: true)
        try ThemePresetConfig.configuration(from: .takoDefault).write(to: builtins.appendingPathComponent("TakoCore"), atomically: true, encoding: .utf8)
        try (ThemePresetConfig.marker + "\nbackground = #010203\nfont-size = 15\n").write(to: builtins.appendingPathComponent("Readonly"), atomically: true, encoding: .utf8)
        try "command = /bin/sh\ngrapheme-width-method = legacy\n# preserve\n".write(to: config, atomically: true, encoding: .utf8)
        workspaces = WorkspaceStore(storeURL: root.appendingPathComponent("workspaces.json"), isTesting: true)
        styles = ScopedAppearanceStore(fileURL: root.appendingPathComponent("Appearance.json"))
        let calls = Counter(); counter = calls
        service = ThemeControlService(configURL: config, appearances: styles, workspaces: workspaces,
                                      themePaths: [builtins.path], reload: { calls.value += 1 })
    }

    @discardableResult
    func call(_ action: String, _ args: [String: JSON] = [:], scope: ThemeControlScope? = nil) throws -> [String: JSON] {
        try service.handle(args.merging(["action": .string(action)]) { _, new in new }, scope: scope)
    }

    func create(_ name: String = "Mine") throws {
        try call("create", ["name": .string(name), "config": .string("background = #123456\nfont-family = Monaco\nfont-size = 19\npalette = 1=#ff1122\n")])
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}
