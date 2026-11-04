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
                        .accessibilityValue(model.selectedTheme == choice.name ? "Selected" : "Not selected")
                        .accessibilityIdentifier("SetupTheme-\(choice.name)")
                }
            }
            Text("More presets, custom themes, fonts and sizes are in Settings (⌘,). Workspace and pane styles keep their priority.")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(SetupStyle.muted).lineSpacing(4)
        }.onAppear {
            guard choices.isEmpty else { return }
            let paths = model.configFile.appearanceThemePaths
            var names = TerminalAppearanceCatalog.themeNames(paths: paths)
            if let index = names.firstIndex(of: model.selectedTheme) {
                names.insert(names.remove(at: index), at: 0)
            }
            choices = names.prefix(8).map { name in
                Choice(name: name, theme: TerminalTheme.parse(config: "theme = \(name)",
                    configPath: model.configFile.configPath, darkAppearance: TakoSystemAppearance.isDark))
            }
        }
    }

    private func preview(_ choice: Choice) -> some View {
        let foreground = Color(nsColor: NSColor(cgColor: choice.theme.foreground) ?? Tako.Brand.text)
        let background = Color(nsColor: NSColor(cgColor: choice.theme.background) ?? Tako.Brand.surface)
        let selected = choice.name == model.selectedTheme
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(choice.name).font(.system(size: 11, weight: .semibold, design: .monospaced)).lineLimit(1)
                Spacer(minLength: 4)
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(SetupStyle.accent) }
            }.foregroundStyle(SetupStyle.text)
            VStack(alignment: .leading, spacing: 5) {
                Text("~/project ❯").opacity(0.65)
                Text("Hello, Tako.").fontWeight(.semibold)
                Text("Ready for your next idea.").opacity(0.8)
            }
            .font(.custom(choice.theme.fontFamily ?? "Menlo", size: 11))
            .foregroundStyle(foreground).padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: .rect(cornerRadius: 5))
        }
        .padding(12).background(SetupStyle.card, in: .rect(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? SetupStyle.accent : SetupStyle.border, lineWidth: selected ? 1.5 : 1))
    }
}
