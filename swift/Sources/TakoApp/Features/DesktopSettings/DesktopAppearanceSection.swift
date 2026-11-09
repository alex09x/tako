/*
 * tako — Desktop settings «Terminal Appearance»: level preview, theme catalog, font and size
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import SwiftUI

/// pfPageLook: what this level renders, the 10 built-in and the user themes
/// as cards, the font from the real inventory and the fractional base size.
/// Accessibility: `DesktopTheme-<name>`, `DesktopThemeDuplicate`,
/// `DesktopThemeMenu-<name>`, `DesktopThemeFilter`, `DesktopFont-<family>`,
/// `DesktopFontSize`, `DesktopInherit-<key>`.
struct DesktopAppearanceSection: View {
    @ObservedObject var model: DesktopSettingsModel
    @ObservedObject var scope: DesktopScopeEditor
    @ObservedObject var themes: DesktopThemeLibrary
    let palette: DesktopPalette
    @State private var themeQuery = ""
    @State private var fontQuery = ""
    @State private var facts: [DesktopThemeFacts] = []
    @State private var renaming: String?
    @State private var newName = ""

    private var selectedTheme: String? { scope.effectiveValue("theme") }

    var body: some View {
        let rendered = scope.renderedTheme
        VStack(alignment: .leading, spacing: 0) {
            DesktopTerminalPreview(title: "\(selectedTheme ?? "TakoCore") · \(Self.fontLine(rendered))", theme: rendered)
                .padding(.top, 0)
            DesktopBlock(title: "Theme", note: scope.isGlobal ? "Global terminal theme" : scope.sourceLabel("theme"), palette: palette) {
                DesktopHint(text: "A full Tako preset includes colors, ANSI colors, font and size. Applying it replaces these settings and clears overrides at this level. Legacy color-only themes preserve font overrides.",
                            palette: palette)
                HStack(spacing: 8) {
                    TextField("Search themes", text: $themeQuery).desktopField(palette)
                        .accessibilityIdentifier("DesktopThemeFilter")
                    Button("New Theme…") { model.editTheme(selectedTheme ?? "TakoCore", asCopy: true) }
                        .buttonStyle(DesktopButtonStyle(palette: palette))
                        .help("Create an editable copy of the selected theme without changing the original")
                        .accessibilityIdentifier("DesktopThemeDuplicate")
                }
                .padding(.vertical, 4)
                if let renaming { renameBar(renaming) }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(visibleFacts, id: \.name) { card($0) }
                }
                if scope.source("theme") == .local, !scope.isGlobal {
                    Button("Inherit Theme") { scope.inherit("theme") }
                        .buttonStyle(DesktopButtonStyle(palette: palette)).padding(.top, 8)
                        .accessibilityIdentifier("DesktopInherit-theme")
                }
            }
            fontBlock(rendered)
        }
        .onAppear(perform: refreshFacts)
        .onChange(of: themes.entries) { refreshFacts() }
        .onChange(of: scope.revision) { refreshFacts() }
    }

    static func fontLine(_ theme: TerminalTheme) -> String {
        "\(theme.fontFamily ?? TerminalAppearanceCatalog.defaultFont) \(DesktopStepper.render(Double(theme.fontSize)))"
    }

    private var visibleFacts: [DesktopThemeFacts] {
        let q = themeQuery.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? facts : facts.filter { $0.name.lowercased().contains(q) }
    }

    /// Parses each preset and counts its assignments once, not per frame.
    private func refreshFacts() {
        let paths = [themes.store.directory.path] + themes.store.searchPaths
        facts = themes.entries.map { entry in
            DesktopThemeFacts(name: entry.name, isUser: entry.isUser,
                              theme: TerminalTheme.takoDefault.applyingTheme(named: entry.name, searchPaths: paths),
                              uses: themes.references(to: entry.name).count)
        }
    }

    private func card(_ f: DesktopThemeFacts) -> some View {
        DesktopThemeCard(facts: f, selected: selectedTheme == f.name, palette: palette,
                         select: { scope.selectPreset(f.name) }) {
            Menu {
                Button(f.isUser ? "Edit…" : "Duplicate…") { model.editTheme(f.name) }
                if f.isUser {
                    Button("Duplicate…") { model.editTheme(f.name, asCopy: true) }
                    Button("Rename…") { renaming = f.name; newName = f.name }
                    Button(f.uses > 0 ? "Delete… (used in \(f.uses) \(DesktopThemeFacts.places(f.uses)))" : "Delete…",
                           role: .destructive) { themes.delete(f.name) }
                        .disabled(f.uses > 0)
                }
            } label: { Text("⋯").frame(width: 24, height: 22) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityIdentifier("DesktopThemeMenu-\(f.name)")
        }
    }

    private func renameBar(_ name: String) -> some View {
        HStack(spacing: 8) {
            TextField("New name", text: $newName).desktopField(palette)
                .accessibilityIdentifier("DesktopThemeRenameField")
            Button("Rename") { if themes.rename(name, to: newName) != nil { renaming = nil } }
                .buttonStyle(DesktopButtonStyle(primary: true, palette: palette))
                .disabled(newName.isEmpty || newName == name)
                .accessibilityIdentifier("DesktopThemeRenameConfirm")
            Button("Cancel") { renaming = nil }.buttonStyle(DesktopButtonStyle(palette: palette))
        }
        .padding(.vertical, 4)
    }

    // MARK: Font and size

    private func fontBlock(_ rendered: TerminalTheme) -> some View {
        let resolution = model.fontResolution()
        return DesktopBlock(title: "Font & Size", note: scope.sourceLabel("font-family"), palette: palette) {
            DesktopPrefRow(title: "Font", detail: fontDetail(resolution), key: "font-family", palette: palette) {
                inheritButton("font-family")
            }
            TextField("Search fonts", text: $fontQuery).desktopField(palette)
                .accessibilityIdentifier("DesktopFontFilter")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filteredFonts, id: \.self) { fontRow($0, selected: $0 == resolution.rendered) }
                }
            }
            .frame(height: 200)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color(palette.field)))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(palette.separator)))
            DesktopPrefRow(title: "Size", detail: "Base terminal size, including fractional values from 6–72 pt. ⌘+ / ⌘− temporarily zoom the current terminal without changing this setting.",
                           key: "font-size · immediately", palette: palette) {
                HStack(spacing: 8) {
                    DesktopStepper(value: Double(scope.effectiveValue("font-size") ?? "") ?? 13, range: 6...72, step: 0.5,
                                   unit: "pt", identifier: "DesktopFontSize", palette: palette) {
                        scope.set("font-size", DesktopStepper.render($0))
                    }
                    inheritButton("font-size")
                }
            }
            DesktopPaneZoomRow(paneID: paneID, palette: palette)
        }
    }

    /// The terminal this level is, at «terminal»; nil at other levels.
    private var paneID: UUID? {
        if case .pane(let id) = scope.context?.scope { return id }
        return nil
    }

    private func fontDetail(_ resolution: DesktopFontResolution) -> String {
        guard resolution.isFallback, let requested = resolution.requested else {
            return "\(resolution.rendered) — \(scope.sourceLabel("font-family").lowercased())."
        }
        return "“\(requested)” is not installed. The terminal uses \(resolution.rendered)."
    }

    @ViewBuilder private func inheritButton(_ key: String) -> some View {
        if scope.source(key) == .local {
            Button { scope.inherit(key) } label: { Text("↺") }
                .buttonStyle(.plain).foregroundStyle(Color(palette.muted))
                .help(scope.isGlobal ? "Restore Default" : "Inherit from \(scope.parentTitle)")
                .accessibilityIdentifier("DesktopInherit-\(key)")
        }
    }

    private var filteredFonts: [String] {
        let q = fontQuery.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? model.fonts : model.fonts.filter { $0.lowercased().contains(q) }
    }

    private func fontRow(_ family: String, selected: Bool) -> some View {
        Button { scope.set("font-family", family) } label: {
            HStack(spacing: 12) {
                Text(family).foregroundStyle(Color(palette.text)).frame(width: 170, alignment: .leading).lineLimit(1)
                Text("~/tako ❯ mitts test").font(.custom(family, size: DesktopMetrics.bodyFontSize))
                    .foregroundStyle(Color(palette.secondary)).lineLimit(1)
                Spacer(minLength: 0)
                if selected { Image(systemName: "checkmark").foregroundStyle(Color(palette.accentBright)) }
            }
            .padding(.horizontal, 12).frame(height: DesktopMetrics.navigationRowHeight)
            .background(selected ? Color(palette.border) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("DesktopFont-\(family)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
