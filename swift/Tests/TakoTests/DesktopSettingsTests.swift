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
    @MainActor struct Sandbox {
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
            // A full preset (versioned marker): choosing it replaces the level's own fields.
            try "# tako-preset-version: 1\nbackground = #202020\nfont-family = Menlo\nfont-size = 15\n"
                .write(to: builtin.appendingPathComponent("Typed"), atomically: true, encoding: .utf8)
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

    /// The frozen reference: min(820, host − 24) × min(700, max(320, host − 24)),
    /// centred, 12 pt per side, top never closer than 12 pt.
    @Test func geometryFollowsTheReferencePlacement() {
        let large = DesktopSettingsGeometry.frame(in: CGRect(x: 0, y: 0, width: 1600, height: 1000))
        #expect(large.size == CGSize(width: 820, height: 700))
        #expect(large.midX == 800 && large.midY == 500)

        // Series A: the 1400×880 app window.
        let reference = DesktopSettingsGeometry.frame(in: CGRect(x: 0, y: 0, width: 1400, height: 880))
        #expect(reference == CGRect(x: 290, y: 90, width: 820, height: 700))

        let small = DesktopSettingsGeometry.frame(in: CGRect(x: 0, y: 0, width: 600, height: 480))
        #expect(small == CGRect(x: 12, y: 12, width: 576, height: 456))
        #expect(DesktopSettingsGeometry.isCompact(small.size))
        #expect(!DesktopSettingsGeometry.isCompact(large.size))

        let offset = DesktopSettingsGeometry.frame(in: CGRect(x: 100, y: 50, width: 900, height: 600))
        #expect(offset == CGRect(x: 140, y: 62, width: 820, height: 576))

        // Under 344 pt the 320 pt minimum keeps 12 pt at the top and runs past the bottom.
        let tiny = DesktopSettingsGeometry.frame(in: CGRect(x: 0, y: 0, width: 30, height: 300))
        #expect(tiny.width == 6 && tiny.height == 320 && tiny.maxY == 288)
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
        #expect(controller.panelFrame == CGRect(x: 12, y: 12, width: 476, height: 376))

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
        #expect(library.entries.map(\.name) == ["Base", "Typed"])
        #expect(library.entries.first?.isUser == false)

        var draft = try #require(library.beginDraft("Base"))
        #expect(draft.name == "Base Copy")
        #expect(draft.isCopy && draft.canSave)
        draft.replaceText("theme = Base\n")
        #expect(draft.configError != nil && !draft.canSave, "a nested theme is refused before saving")
        draft.replaceText("background = #101010\nforeground = #eeeeee\n")
        draft.name = " bad"
        #expect(draft.nameError != nil)
        draft.name = "Base Copy"
        draft.set("background", "#202020")
        draft.setPalette(1, "#ff0000")
        let fractional = draft.setFontSize(13.5)
        let outOfRange = draft.setFontSize(80)
        #expect(fractional)
        #expect(!outOfRange)
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

    /// Delete is refused while assigned and names where; rename is the native
    /// transaction: the file moves and every reference follows it.
    @Test func deleteRefusesAssignedThemesAndRenameMovesEveryReference() throws {
        let sandbox = try Sandbox()
        let file = KeybindConfigFile(configPath: sandbox.config.path)
        let scopes = sandbox.scopes()
        var reloads = 0
        let library = DesktopThemeLibrary(store: ThemePresetStore(directory: sandbox.userThemes, searchPaths: [sandbox.builtin.path]),
                                          scopes: scopes, configFile: file, reloadApp: { reloads += 1 })
        #expect(library.duplicate("Base", as: "Mine") != nil)
        #expect(DesktopPreferenceStore(configFile: file).set("theme", "Mine"))
        let workspace = UUID()
        try scopes.setValue("Mine", for: "theme", scope: .workspace(workspace))

        #expect(!library.delete("Mine"))
        let refusal = try #require(library.lastError)
        #expect(refusal.contains("Global settings") && refusal.contains("workspace"))
        #expect(FileManager.default.fileExists(atPath: sandbox.userThemes.appendingPathComponent("Mine").path))
        #expect(library.references(to: "Mine").count == 2)

        #expect(library.rename("Mine", to: "Other")?.name == "Other", "\(library.lastError ?? "")")
        #expect(!FileManager.default.fileExists(atPath: sandbox.userThemes.appendingPathComponent("Mine").path))
        #expect(sandbox.configText.contains("theme = Other") && !sandbox.configText.contains("theme = Mine"))
        #expect(scopes.document.workspaces[workspace.uuidString.lowercased()]?["theme"] == "Other"
                || scopes.document.workspaces[workspace.uuidString]?["theme"] == "Other")
        #expect(library.references(to: "Mine").isEmpty)
        #expect(reloads == 1)

        #expect(library.duplicate("Other", as: "Spare") != nil)
        #expect(library.delete("Spare"))
        #expect(!library.entries.contains { $0.name == "Spare" || $0.name == "Mine" })
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
        let parentEditor = DesktopScopeEditor(context: parent, preferences: preferences, themePaths: [sandbox.builtin.path])
        let editor = DesktopScopeEditor(context: pane, preferences: preferences, themePaths: [sandbox.builtin.path])

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

        // Colours-only preset: selected, the level's own colour stays (526 rule).
        #expect(editor.set("background", "#123456"))
        #expect(editor.selectPreset("Base"))
        #expect(editor.localValue("background") == "#123456")
        #expect(editor.localValue("theme") == "Base")
        // Full preset: replaces this level's own fields only.
        #expect(editor.selectPreset("Typed"))
        #expect(editor.localValue("background") == nil)
        #expect(editor.localValue("theme") == "Typed")
        #expect(parentEditor.localValue("font-size") == "15")
        #expect(editor.resetAll())
        #expect(editor.localValue("theme") == nil)
        #expect(parentEditor.localValue("font-size") == "15")
    }

    /// Global level: a full preset drops stale appearance lines (as
    /// applyFullThemePreset does) and the shown value is the resolved one.
    @Test func globalFullPresetDropsStaleLinesAndShowsResolvedValues() throws {
        let sandbox = try Sandbox()
        try "# tako-preset-version: 1\nbackground = #303030\nfont-family = Monaco\nfont-size = 17\n"
            .write(to: sandbox.userThemes.appendingPathComponent("Wide"), atomically: true, encoding: .utf8)
        let preferences = DesktopPreferenceStore(configFile: KeybindConfigFile(configPath: sandbox.config.path))
        let global = DesktopScopeEditor(context: nil, preferences: preferences)
        #expect(global.set("font-size", "13.5"))
        #expect(global.set("background", "#111111"))
        #expect(global.effectiveValue("font-size") == "13.5")

        #expect(global.selectPreset("Wide"), "\(global.lastError ?? "")")
        let text = sandbox.configText
        #expect(text.contains("theme = Wide"))
        #expect(!text.contains("font-size = 13.5") && !text.contains("background = #111111"))
        #expect(global.effectiveValue("font-size") == "17", "the preset's size, not the registry default")
        #expect(global.effectiveValue("font-family") == "Monaco")
        #expect(global.effectiveValue("theme") == "Wide")
        #expect(global.localValue("font-size") == nil)
        #expect(global.renderedTheme.fontSize == 17)
    }

    /// The draft previews on live panes chosen when it opens; cancel and
    /// close restore, save restores first, writes, selects and reloads.
    @Test func draftPreviewIsOpenedRestoredAndSaveReloadsTheApp() throws {
        let sandbox = try Sandbox()
        let model = sandbox.model(section: .terminalAppearance)
        var reloads = 0
        model.reloadApp = { reloads += 1 }

        model.editTheme("Base")
        #expect(model.draft?.name == "Base Copy")
        #expect(model.preview != nil)
        model.updateDraft { $0.set("background", "#222222") }
        #expect(!FileManager.default.fileExists(atPath: sandbox.userThemes.appendingPathComponent("Base Copy").path))
        model.cancelDraft()
        #expect(model.draft == nil && model.preview == nil)

        model.editTheme("Base")
        model.updateDraft { $0.replaceText("theme = Base\n") }
        #expect(!model.saveDraft(), "an invalid draft is not written")
        #expect(model.draft != nil && model.draftError != nil)
        model.updateDraft { $0.replaceText("background = #222222\n") }
        #expect(model.saveDraft(), "\(model.draftError ?? model.scope.lastError ?? "")")
        #expect(model.draft == nil && model.preview == nil)
        #expect(reloads == 1)
        #expect(sandbox.configText.contains("theme = Base Copy"))

        model.editTheme("Base Copy")
        #expect(model.draft?.isCopy == false, "a user theme opens in place")
        model.editTheme("Base Copy", asCopy: true)
        #expect(model.draft?.name == "Base Copy Copy")
        model.cancelDraft()
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

    /// Reference keys: ⌫ returns the default; in a conflict Enter reassigns
    /// and Esc cancels; every outcome is written to the status line.
    @Test func recorderBackspaceResetsAndConflictTakesEnterOrEscape() throws {
        let sandbox = try Sandbox()
        let file = KeybindConfigFile(configPath: sandbox.config.path)
        let recorder = DesktopShortcutRecorder(configFile: file)
        recorder.begin("new_window", installMonitor: false)
        recorder.handle(keyCode: 40, modifiers: [.control, .option])
        #expect(file.customOverrides["new_window"] == "ctrl+opt+k")

        recorder.begin("new_window", installMonitor: false)
        #expect(recorder.handle(keyCode: 51, modifiers: []))
        #expect(recorder.state == .idle && file.customOverrides["new_window"] == nil)
        #expect(recorder.status?.contains("Restored the default") == true)

        // ⇧⌘D belongs to «Разделить вниз» by default.
        recorder.begin("new_split:right", installMonitor: false)
        recorder.handle(keyCode: 2, modifiers: [.command, .shift])
        guard case .conflict(_, _, let holder) = recorder.state else { Issue.record("no conflict: \(recorder.state)"); return }
        #expect(holder.title == "Split Down")
        #expect(recorder.status?.contains("Enter to reassign") == true)
        #expect(recorder.handle(keyCode: 0, modifiers: []), "other keys are swallowed while asking")
        #expect(recorder.handle(keyCode: 53, modifiers: []))
        #expect(recorder.state == .idle && file.customOverrides.isEmpty)

        recorder.begin("new_split:right", installMonitor: false)
        recorder.handle(keyCode: 2, modifiers: [.command, .shift])
        #expect(recorder.handle(keyCode: 36, modifiers: []))
        #expect(recorder.state == .idle)
        #expect(file.customOverrides["new_split:right"] == "shift+cmd+d")
    }

    @Test func recorderDetectsConflictWithBuiltinDefault() throws {
        let sandbox = try Sandbox()
        let recorder = DesktopShortcutRecorder(configFile: KeybindConfigFile(configPath: sandbox.config.path))
        let copy = try #require(KeybindRegistry.defaultShortcut(for: "copy_to_clipboard"))
        #expect(DesktopKeysCopy.trigger(for: copy) == "cmd+c")
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

    @Test func searchCoversSectionsSettingsActionsAndFonts() throws {
        let fonts = ["Menlo", "JetBrains Mono"]
        #expect(DesktopSettingsSearch.results("", fonts: fonts).isEmpty)
        #expect(DesktopSettingsSearch.results("font", fonts: fonts).contains { $0.section == .terminalAppearance && $0.kind == .section })
        #expect(DesktopSettingsSearch.results("jetbrains", fonts: fonts).contains { $0.kind == .font("JetBrains Mono") })
        #expect(DesktopSettingsSearch.results("New Tab", fonts: fonts).contains { $0.kind == .action("new_tab") && $0.section == .keys })
        #expect(DesktopSettingsSearch.results("quick-terminal-position", fonts: fonts)
            .contains { $0.kind == .setting("quick-terminal-position") && $0.section == .quickTerminal })
        #expect(DesktopSettingsSearch.results("status-animate", fonts: fonts).first?.section == .status)
        // By shortcut, either spelling, with the reference's Russian title.
        let split = DesktopSettingsSearch.results("cmd+d", fonts: fonts).first { $0.kind == .action("new_split:right") }
        #expect(split?.title == "Split Right")
        #expect(DesktopSettingsSearch.results("⇧⌘D", fonts: fonts).contains { $0.kind == .action("new_split:down") })
        #expect(DesktopSettingsSearch.results("cmd+shift+d", fonts: fonts).contains { $0.kind == .action("new_split:down") })
        // Rows live where the reference shows them, whatever the registry category.
        #expect(DesktopSettingsSearch.results("confirm-close-surface", fonts: fonts).first?.section == .general)
        #expect(DesktopSettingsSearch.results("sidebar-count-done", fonts: fonts).first?.section == .status)
        #expect(DesktopSettingsSection.terminalAppearance.rawValue == "appearance")
        #expect(DesktopSettingsSection.status.rawValue == "activity")
        let hit = try #require(split)
        #expect(DesktopSettingsSearchList.identifier(hit) == "DesktopShortcut-new_split:right")
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
