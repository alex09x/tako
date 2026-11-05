/*
 * tako — Live theme choices in setup
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import SwiftUI

@MainActor
struct SetupAppearanceStep: View {
    @Environment(\.setupPalette) private var colors
    @ObservedObject var model: SetupModel
    @State private var choices: [Choice] = []
    struct Choice: Identifiable {
        let name: String
        let theme: TerminalTheme
        var id: String { name }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(choices) { choice in
                    Button { model.chooseTheme(choice.name) } label: { preview(choice) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(choice.name)
                        .accessibilityValue(Self.isSelected(choice.name, current: model.selectedTheme) ? "Selected" : "Not selected")
                        .accessibilityIdentifier("SetupTheme-\(choice.name)")
                }
            }
            Text("This step changes colors only. Fonts and sizes are in Settings (⌘,). Workspace and pane styles keep their priority.")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(colors.muted).lineSpacing(4)
        }.onAppear {
            guard choices.isEmpty else { return }
            let paths = model.configFile.appearanceThemePaths
            let available = TerminalAppearanceCatalog.themeNames(paths: paths)
            choices = Self.choiceNames(available: available, current: model.selectedTheme).map { name in
                Choice(name: name, theme: TerminalTheme.parse(config: "theme = \(name)",
                    configPath: model.configFile.configPath, darkAppearance: TakoSystemAppearance.isDark))
            }
        }
    }

    private func preview(_ choice: Choice) -> some View {
        let foreground = Color(nsColor: NSColor(cgColor: choice.theme.foreground) ?? Tako.Brand.text)
        let background = Color(nsColor: NSColor(cgColor: choice.theme.background) ?? Tako.Brand.surface)
        let selected = Self.isSelected(choice.name, current: model.selectedTheme)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(choice.name).font(.system(size: 11, weight: .semibold, design: .monospaced)).lineLimit(1)
                Spacer(minLength: 4)
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(colors.accent) }
            }.foregroundStyle(colors.text)
            VStack(alignment: .leading, spacing: 5) {
                Text("~/project ❯").opacity(0.65)
                Text("Hello, Tako.").fontWeight(.semibold)
                Text("Ready for your next idea.").opacity(0.8)
            }
            .font(.custom(model.previewTheme.fontFamily ?? "Menlo", size: 11))
            .foregroundStyle(foreground).padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: .rect(cornerRadius: 5))
        }
        .padding(12).background(colors.card, in: .rect(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? colors.accent : colors.border, lineWidth: selected ? 1.5 : 1))
        .contentShape(Rectangle())
    }

    /// Start with Tako's own presets, while retaining an existing custom selection.
    /// The full user catalog belongs in Settings rather than this short first-run list.
    static func choiceNames(available: [String], current: String) -> [String] {
        let recommended = ["TakoCore", "Tako Forest", "Tako Night", "Tako Ocean", "Tako Slate",
                           "Tako Ember", "Tako Paper", "Tako Dawn", "Tako Ink", "Tako Violet"]
        var names = recommended.filter { available.contains($0) }
        if let selected = available.first(where: { isSelected($0, current: current) }), !names.contains(selected) {
            names.insert(selected, at: 0)
        }
        return names
    }

    static func isSelected(_ name: String, current: String) -> Bool {
        name.caseInsensitiveCompare(current) == .orderedSame
            || (current.lowercased() == "tako" && name == "TakoCore")
    }
}
