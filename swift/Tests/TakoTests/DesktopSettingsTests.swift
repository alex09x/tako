/*
 * tako — Native settings: geometry, lifecycle, themes, scopes, shortcuts, search, persistence
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Foundation
import Testing
@testable import Tako

@MainActor
struct DesktopSettingsTests {
    /// Isolated config, theme and appearance files under a fresh temp root.
    struct Sandbox {
        let root: URL
        let config: URL
        let userThemes: URL
        let builtin: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("tako-settings-\(UUID().uuidString)")
            config = root.appendingPathComponent("config")
            userThemes = root.appendingPathComponent("themes", isDirectory: true)
            builtin = root.appendingPathComponent("builtin", isDirectory: true)
            for dir in [userThemes, builtin] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
            try "# test\n".write(to: config, atomically: true, encoding: .utf8)
            try "background = #101010\nforeground = #eeeeee\n".write(to: builtin.appendingPathComponent("Base"), atomically: true, encoding: .utf8)
        }

        var configText: String { (try? String(contentsOf: config, encoding: .utf8)) ?? "" }

        func model(context: ScopedAppearanceContext? = nil, section: DesktopSettingsSection = .general) -> DesktopSettingsModel {
            DesktopSettingsModel(configPath: config.path, context: context, section: section, scopes: scopes(),
                                 themeStore: ThemePresetStore(directory: userThemes, searchPaths: [builtin.path]),
                                 fonts: ["Menlo", "Monaco"])
        }

        func scopes() -> ScopedAppearanceStore {
            ScopedAppearanceStore(fileURL: root.appendingPathComponent("Appearance.json"), themeSearchPaths: [builtin.path])
        }
    }

    // MARK: Geometry

    @Test func geometryIsCenteredAndClampedToHostMinusMargins() {
        let large = DesktopSettingsGeometry.frame(in: CGRect(x: 0, y: 0, width: 1600, height: 1000))
        #expect(large.size == CGSize(width: 820, height: 700))
        #expect(large.midX == 800 && large.midY == 500)

        let small = DesktopSettingsGeometry.frame(in: CGRect(x: 0, y: 0, width: 600, height: 480))
        #expect(small.size == CGSize(width: 552, height: 432))
        #expect(small.minX == 24 && small.minY == 24)
        #expect(DesktopSettingsGeometry.isCompact(small.size))
        #expect(!DesktopSettingsGeometry.isCompact(large.size))

        let tiny = DesktopSettingsGeometry.frame(in: CGRect(x: 0, y: 0, width: 30, height: 30))
        #expect(tiny.width == 0 && tiny.height == 0)
    }

    // MARK: Presentation lifecycle

    @Test func presentationCentersInHostAndRestoresPreviousFocusOnClose() throws {
        let sandbox = try Sandbox()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 900),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 900))
        window.contentView = content
        let terminal = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        content.addSubview(terminal)
        window.makeFirstResponder(terminal)
        #expect(window.firstResponder === terminal)

        let controller = DesktopSettingsController(model: sandbox.model(), host: window, content: content)
        #expect(controller.overlay.superview === content)
        #expect(controller.panelFrame == DesktopSettingsGeometry.frame(in: content.bounds))
        #expect(controller.panelFrame.midX == content.bounds.midX)

        content.setFrameSize(NSSize(width: 500, height: 400))
        controller.overlay.setFrameSize(content.bounds.size)
        controller.overlay.layout()
        #expect(controller.panelFrame == CGRect(x: 24, y: 24, width: 452, height: 352))

        controller.close()
        #expect(controller.overlay.superview == nil)
        #expect(window.firstResponder === terminal)
        #expect(DesktopSettingsController.current(in: window) == nil)
    }

    @Test func scopedModelOpensOnAppearanceAndHonorsInitialSection() throws {
        let sandbox = try Sandbox()
        #expect(sandbox.model(section: .keys).section == .keys)
        let context = ScopedAppearanceContext(scope: .workspace(UUID()), title: "W", store: sandbox.scopes(),
                                              globalTheme: { .takoDefault })
        #expect(sandbox.model(context: context).section == .terminalAppearance)
    }

    // MARK: Themes

    @Test func themeDraftCancelLeavesDiskAndSaveWritesNewCustomTheme() throws {
        let sandbox = try Sandbox()
        let library = DesktopThemeLibrary(store: ThemePresetStore(directory: sandbox.userThemes, searchPaths: [sandbox.builtin.path]),
                                          scopes: sandbox.scopes(), configFile: KeybindConfigFile(configPath: sandbox.config.path))
        #expect(library.entries.map(\.name) == ["Base"])
        #expect(library.entries.first?.isUser == false)

        var draft = try #require(library.beginDraft("Base"))
        #expect(draft.name == "Base копия")
        draft.set("background", "#202020")
        draft.setPalette(1, "#ff0000")
        #expect(draft.setFontSize(13.5))
        #expect(!draft.setFontSize(80))
        #expect(draft.value("font-size") == "13.5")
        #expect(draft.paletteColor(1) == "#ff0000")
        #expect(draft.isDirty)
        // Cancel = drop the value: nothing on disk.
        #expect(!FileManager.default.fileExists(atPath: sandbox.userThemes.appendingPathComponent("Base копия").path))

        let saved = try #require(library.save(draft), "\(library.lastError ?? "")")
        #expect(saved.isUser)
        let text = try String(contentsOf: sandbox.userThemes.appendingPathComponent(saved.name), encoding: .utf8)
        #expect(text.contains("#202020"))
        #expect(library.entries.contains { $0.name == saved.name && $0.isUser })
        // The builtin itself is immutable.
        let builtin = try String(contentsOf: sandbox.builtin.appendingPathComponent("Base"), encoding: .utf8)
        #expect(builtin.contains("#101010"))
        #expect(!library.delete("Base"))
    }

    @Test func referencedThemeIsNotDeletedOrRenamedAndReferencesAreListed() throws {
        let sandbox = try Sandbox()
        let file = KeybindConfigFile(configPath: sandbox.config.path)
        let library = DesktopThemeLibrary(store: ThemePresetStore(directory: sandbox.userThemes, searchPaths: [sandbox.builtin.path]),
                                          scopes: sandbox.scopes(), configFile: file)
        #expect(library.duplicate("Base", as: "Mine") != nil)
        #expect(DesktopPreferenceStore(configFile: file).set("theme", "Mine"))

        #expect(!library.delete("Mine"))
        #expect(library.lastError?.contains("Global settings") == true)
        #expect(library.rename("Mine", to: "Other") == nil)
        #expect(FileManager.default.fileExists(atPath: sandbox.userThemes.appendingPathComponent("Mine").path))
        #expect(sandbox.configText.contains("theme = Mine"))

        #expect(library.duplicate("Mine", as: "Spare") != nil)
        #expect(library.rename("Spare", to: "Renamed")?.name == "Renamed")
        #expect(library.delete("Renamed"))
        #expect(!library.entries.contains { $0.name == "Renamed" || $0.name == "Spare" })
    }

    // MARK: Scopes

    @Test func scopeOverrideShowsSourceAndResetsOnlyOwnLevel() throws {
        let sandbox = try Sandbox()
        let store = sandbox.scopes()
        let workspace = UUID()
        let parent = ScopedAppearanceContext(scope: .workspace(workspace), title: "W", store: store, globalTheme: { .takoDefault })
        let pane = ScopedAppearanceContext(scope: .pane(UUID()), title: "P", store: store, globalTheme: { .takoDefault },
                                           workspaceID: { workspace })
        let preferences = DesktopPreferenceStore(configFile: KeybindConfigFile(configPath: sandbox.config.path))
        let parentEditor = DesktopScopeEditor(context: parent, preferences: preferences)
        let editor = DesktopScopeEditor(context: pane, preferences: preferences)

        #expect(parentEditor.set("font-size", "15"))
        #expect(editor.source("font-size") == .inherited("session"))
        #expect(editor.effectiveValue("font-size") == "15")

        #expect(editor.set("font-size", "17.5"))
        #expect(editor.source("font-size") == .local)
        #expect(editor.sourceLabel("font-size") == "Custom value")
        #expect(editor.effectiveValue("font-size") == "17.5")
        #expect(!editor.set("font-size", "200"))
        #expect(editor.lastError != nil)

        #expect(editor.inherit("font-size"))
        #expect(editor.effectiveValue("font-size") == "15")

        #expect(editor.set("background", "#123456"))
        #expect(editor.selectPreset("Base"))
        #expect(editor.localValue("background") == nil)
        #expect(editor.localValue("theme") == "Base")
        #expect(editor.resetAll())
        #expect(editor.localValue("theme") == nil)
        #expect(parentEditor.localValue("font-size") == "15")
    }

    @Test func missingFontReportsActualFallback() {
        let missing = DesktopFontResolution.resolve("Nope Mono", inventory: ["Menlo"], fallback: "Menlo")
        #expect(missing.isFallback && missing.rendered == "Menlo")
        let present = DesktopFontResolution.resolve("Menlo", inventory: ["Menlo"], fallback: "Monaco")
        #expect(!present.isFallback && present.rendered == "Menlo")
        #expect(!DesktopFontResolution.resolve(nil, inventory: [], fallback: "Menlo").isFallback)
    }

    // MARK: Shortcuts

    @Test func recorderEscapeCancelsAndConflictNeedsExplicitReassign() throws {
        let sandbox = try Sandbox()
        let file = KeybindConfigFile(configPath: sandbox.config.path)
        let recorder = DesktopShortcutRecorder(configFile: file)

        recorder.begin("new_window", installMonitor: false)
        #expect(recorder.handle(keyCode: 53, modifiers: []))
        #expect(recorder.state == .idle)
        #expect(file.customOverrides.isEmpty)

        recorder.begin("new_window", installMonitor: false)
        #expect(recorder.handle(keyCode: 40, modifiers: []))
        #expect(recorder.lastError != nil)
        #expect(recorder.state == .recording(action: "new_window"))
        recorder.handle(keyCode: 40, modifiers: [.control, .option])
        #expect(recorder.state == .idle)
        #expect(file.customOverrides["new_window"] == "ctrl+opt+k")

        recorder.begin("new_tab", installMonitor: false)
        recorder.handle(keyCode: 40, modifiers: [.control, .option])
        guard case .conflict(_, let trigger, let holder) = recorder.state else {
            Issue.record("expected conflict, got \(recorder.state)"); return
        }
        #expect(trigger == "ctrl+opt+k" && holder.id == "new_window")
        recorder.cancel()
        #expect(file.customOverrides["new_window"] == "ctrl+opt+k")
        #expect(file.customOverrides["new_tab"] == nil)

        recorder.begin("new_tab", installMonitor: false)
        recorder.handle(keyCode: 40, modifiers: [.control, .option])
        recorder.confirmReassign()
        #expect(file.customOverrides["new_tab"] == "ctrl+opt+k")
        #expect(file.customOverrides["new_window"] == nil)
        #expect(recorder.isCustom("new_tab"))

        #expect(recorder.reset("new_tab"))
        #expect(!recorder.isCustom("new_tab"))
        recorder.begin("new_window", installMonitor: false)
        recorder.handle(keyCode: 40, modifiers: [.control, .option])
        #expect(recorder.resetAll())
        #expect(file.customOverrides.isEmpty)
    }

    @Test func recorderDetectsConflictWithBuiltinDefault() throws {
        let sandbox = try Sandbox()
        let recorder = DesktopShortcutRecorder(configFile: KeybindConfigFile(configPath: sandbox.config.path))
        let copy = try #require(KeybindRegistry.defaultShortcut(for: "copy_to_clipboard"))
        #expect(KeybindRegistry.trigger(for: copy) == "cmd+c")
        recorder.begin("new_window", installMonitor: false)
        recorder.handle(keyCode: 8, modifiers: [.command])
        guard case .conflict(_, _, let holder) = recorder.state else {
            Issue.record("expected default conflict, got \(recorder.state)"); return
        }
        #expect(holder.id == "copy_to_clipboard")
        recorder.cancel()
        #expect(recorder.display(for: "copy_to_clipboard") == "⌘C")
    }

    // MARK: Search

    @Test func searchCoversSectionsSettingsActionsAndFonts() {
        let fonts = ["Menlo", "JetBrains Mono"]
        #expect(DesktopSettingsSearch.results("", fonts: fonts).isEmpty)
        #expect(DesktopSettingsSearch.results("font", fonts: fonts).contains { $0.section == .terminalAppearance && $0.kind == .section })
        #expect(DesktopSettingsSearch.results("jetbrains", fonts: fonts).contains { $0.kind == .font("JetBrains Mono") })
        #expect(DesktopSettingsSearch.results("New Tab", fonts: fonts).contains { $0.kind == .action("new_tab") && $0.section == .keys })
        #expect(DesktopSettingsSearch.results("quick-terminal-position", fonts: fonts)
            .contains { $0.kind == .setting("quick-terminal-position") && $0.section == .quickTerminal })
        #expect(DesktopSettingsSearch.results("status-animate", fonts: fonts).first?.section == .status)
    }

    // MARK: Persistence

    @Test func preferencesPersistRealRegistryKeysAndRejectInvalidValues() throws {
        let sandbox = try Sandbox()
        let preferences = DesktopPreferenceStore(configFile: KeybindConfigFile(configPath: sandbox.config.path))
        #expect(preferences.desktopPreferences.appearance == .system)

        #expect(preferences.set("app-appearance", "dark"))
        #expect(preferences.set("status-animate", "false"))
        #expect(preferences.set("sidebar-count-done", "false"))
        #expect(sandbox.configText.contains("app-appearance = dark"))
        #expect(sandbox.configText.contains("status-animate = false"))
        let reread = DesktopPreferenceStore(configFile: KeybindConfigFile(configPath: sandbox.config.path)).desktopPreferences
        #expect(reread.appearance == .dark && !reread.animatesStatus && !reread.countsDone && reread.showsStatus)

        let before = sandbox.configText
        #expect(!preferences.set("app-appearance", "purple"))
        #expect(preferences.lastError != nil)
        #expect(!preferences.set("no-such-key", "1"))
        #expect(sandbox.configText == before)

        #expect(preferences.set("font-size", "13.5"))
        #expect(!preferences.set("font-size", "5"))
        #expect(preferences.reset("app-appearance"))
        #expect(!sandbox.configText.contains("app-appearance"))
        #expect(preferences.lastError == nil)
        #expect(!preferences.isOverridden("app-appearance"))
    }
}
