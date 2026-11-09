/*
 * tako — «Appearance ▸» in workspace, session, pane and terminal context menus
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import SwiftUI

/// What the reference's «Appearance ▸» offers for one level (spec «inheritance»):
/// up to six presets with the level's own first and ✓, «Inherit» (drop
/// this level's own appearance; the parent shows through), «All Themes…» and
/// «Customize…» into Settings at this level. Choosing a preset follows the
/// same rule as Settings (DesktopScopeEditor.applyPreset). Building the menu
/// reads only; nothing is written until an item is chosen.
@MainActor
struct DesktopAppearanceMenu {
    let level: DesktopScopeLevel
    let context: ScopedAppearanceContext
    let presets: [String]
    let themePaths: [String]
    /// The level's own theme, nil while it inherits.
    let selected: String?
    /// What the level shows while it inherits («Inherit · TakoCore»).
    let inherited: String
    var openSettings: (_ edit: Bool) -> Void = { _ in }
    var reportError: (String) -> Void = { NSSound.beep(); _ = $0 }

    static let maxPresets = 6

    /// The level, its live context and the catalog; nil for Global or a level
    /// that is gone.
    static func make(for level: DesktopScopeLevel, app: Tako.App?, store: ScopedAppearanceStore = .shared,
                     window: NSWindow?, catalog: DesktopAppearanceMenuCatalog = .shared) -> DesktopAppearanceMenu? {
        guard let context = level.context(app: app, store: store), context.isAvailable() else { return nil }
        let metadata = catalog.snapshot(configPath: app?.activeConfigPath)
        let paths = metadata.paths
        let names = metadata.names
        let own = context.value(for: "theme")
        let inherited = Self.inheritedName(context: context, globalTheme: metadata.globalTheme)
        var menu = DesktopAppearanceMenu(level: level, context: context, presets: Self.choices(names, selected: own),
                                         themePaths: paths, selected: own, inherited: inherited)
        // «Customize…» edits what the level shows: its own theme, else the inherited one.
        menu.openSettings = { [weak window] edit in
            DesktopSettingsController.showAppearance(for: level, editing: edit ? own ?? inherited : nil, in: window)
        }
        return menu
    }

    /// The level's own preset first, then the catalog order, six at most.
    static func choices(_ names: [String], selected: String?) -> [String] {
        var out: [String] = []
        if let selected, let match = names.first(where: { $0.caseInsensitiveCompare(selected) == .orderedSame }) {
            out.append(match)
        }
        for name in names where !out.contains(name) && out.count < maxPresets { out.append(name) }
        return out
    }

    private static func inheritedName(context: ScopedAppearanceContext, globalTheme: String) -> String {
        let parentTheme: String?
        switch context.scope {
        case .workspace: parentTheme = nil
        case .session: parentTheme = context.workspaceID().flatMap { context.store.value(for: "theme", scope: .workspace($0)) }
        case .pane:
            parentTheme = context.sessionID().flatMap { context.store.value(for: "theme", scope: .session($0)) }
                ?? context.workspaceID().flatMap { context.store.value(for: "theme", scope: .workspace($0)) }
        }
        if let parentTheme { return parentTheme }
        return globalTheme
    }

    var inherits: Bool { context.store.document.overrides(for: context.scope)?.isEmpty != false }

    func isSelected(_ name: String) -> Bool { selected?.caseInsensitiveCompare(name) == .orderedSame }

    func choose(_ name: String) {
        guard context.isAvailable() else { reportError("This terminal or workspace is no longer available."); return }
        do {
            let full = TerminalTheme.presetContainsTypography(named: name, searchPaths: themePaths)
            try DesktopScopeEditor.applyPreset(name, full: full, to: context)
        } catch { reportError(error.localizedDescription) }
    }

    func inherit() {
        guard context.isAvailable() else { reportError("This terminal or workspace is no longer available."); return }
        do { try context.store.reset(context.scope) } catch { reportError(error.localizedDescription) }
    }

    // MARK: AppKit (terminal and pane header)

    /// Accessibility identifiers: `DesktopAppearanceMenu`, `DesktopAppearanceInherit`,
    /// `DesktopAppearancePreset-<name>`, `DesktopAppearanceAllThemes`, `DesktopAppearanceEdit`.
    func menuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        parent.identifier = .init("DesktopAppearanceMenu")
        let menu = NSMenu(title: "Appearance")
        menu.autoenablesItems = false
        let inheritItem = Self.action("Inherit · \(inherited)", id: "DesktopAppearanceInherit") { self.inherit() }
        inheritItem.state = inherits ? .on : .off
        menu.addItem(inheritItem)
        menu.addItem(.separator())
        for name in presets {
            let item = Self.action(name, id: "DesktopAppearancePreset-\(name)") { self.choose(name) }
            item.state = isSelected(name) ? .on : .off
            item.image = Self.swatch(TerminalTheme.takoDefault.applyingTheme(named: name, searchPaths: themePaths))
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(Self.action("All Themes…", id: "DesktopAppearanceAllThemes") { self.openSettings(false) })
        menu.addItem(Self.action("Customize…", id: "DesktopAppearanceEdit") { self.openSettings(true) })
        parent.submenu = menu
        return parent
    }

    private static func action(_ title: String, id: String, perform: @escaping () -> Void) -> NSMenuItem {
        let target = MenuAction(perform)
        let item = NSMenuItem(title: title, action: #selector(MenuAction.invoke), keyEquivalent: "")
        item.identifier = .init(id)
        item.target = target
        item.representedObject = target  // NSMenuItem does not retain its target.
        return item
    }

    /// Background, text and three ANSI colours of a preset.
    static func swatch(_ theme: TerminalTheme) -> NSImage {
        let colors = [theme.background, theme.foreground] + [1, 2, 4].compactMap { $0 < theme.palette.count ? theme.palette[$0] : nil }
        return NSImage(size: NSSize(width: 30, height: 12), flipped: false) { rect in
            let width = rect.width / CGFloat(colors.count)
            for (index, color) in colors.enumerated() {
                (NSColor(cgColor: color) ?? .clear).setFill()
                NSRect(x: CGFloat(index) * width, y: 0, width: width, height: rect.height).fill()
            }
            return true
        }
    }

    private final class MenuAction: NSObject {
        let perform: () -> Void
        init(_ perform: @escaping () -> Void) { self.perform = perform }
        @objc func invoke() { perform() }
    }
}

/// The same menu for SwiftUI context menus (sidebar rows and workspace headers).
struct DesktopAppearanceSubmenu: View {
    let menu: DesktopAppearanceMenu

    var body: some View {
        Menu("Appearance") {
            Toggle("Inherit · \(menu.inherited)", isOn: Binding(get: { menu.inherits }, set: { if $0 { menu.inherit() } }))
                .accessibilityIdentifier("DesktopAppearanceInherit")
            Divider()
            ForEach(menu.presets, id: \.self) { name in
                Toggle(name, isOn: Binding(get: { menu.isSelected(name) }, set: { if $0 { menu.choose(name) } }))
                    .accessibilityIdentifier("DesktopAppearancePreset-\(name)")
            }
            Divider()
            Button("All Themes…") { menu.openSettings(false) }.accessibilityIdentifier("DesktopAppearanceAllThemes")
            Button("Customize…") { menu.openSettings(true) }.accessibilityIdentifier("DesktopAppearanceEdit")
        }
        .accessibilityIdentifier("DesktopAppearanceMenu")
    }
}
