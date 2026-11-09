/*
 * tako — Desktop settings window: sidebar, page, footer
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import SwiftUI

/// The reference's settings window (pfWinHtml): a 232 pt section column and
/// the page with its title, level line, scrolling body and footer.
/// Accessibility: `DesktopSettingsRoot` (the panel), `DesktopSettingsSearch`,
/// `DesktopSettingsSection-<raw>`, `DesktopSettingsClose`.
struct DesktopSettingsView: View {
    @ObservedObject var model: DesktopSettingsModel
    @ObservedObject private var presentation = DesktopPresentation.shared
    @ObservedObject private var recorder: DesktopShortcutRecorder
    @FocusState private var searchFocused: Bool

    init(model: DesktopSettingsModel) {
        _model = ObservedObject(wrappedValue: model)
        _recorder = ObservedObject(wrappedValue: model.recorder)
    }

    private var palette: DesktopPalette { presentation.palette }
    private var searching: Bool { !model.query.trimmingCharacters(in: .whitespaces).isEmpty }
    private var editing: Bool { model.draft != nil }

    var body: some View {
        GeometryReader { proxy in
            let compact = DesktopSettingsGeometry.isCompact(proxy.size)
            HStack(spacing: 0) {
                if !compact {
                    sidebar.frame(width: DesktopMetrics.settingsSidebarWidth)
                        .background(Color(palette.background))
                        .overlay(alignment: .trailing) { Rectangle().fill(Color(palette.separator)).frame(width: 1) }
                }
                main(compact: compact)
            }
        }
        .font(.system(size: DesktopMetrics.bodyFontSize))
        .foregroundStyle(Color(palette.secondary))
        .background(Color(palette.popover))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("DesktopSettingsRoot")
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings").font(.system(size: DesktopSettingsStyle.sidebarTitleSize, weight: .semibold))
                .foregroundStyle(Color(palette.text))
                .padding(EdgeInsets(top: 4, leading: 8, bottom: 12, trailing: 8))
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Color(palette.muted))
                TextField("Search", text: $model.query).textFieldStyle(.plain)
                    .foregroundStyle(Color(palette.text))
                    .focused($searchFocused)
                    .accessibilityIdentifier("DesktopSettingsSearch")
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: DesktopMetrics.controlRadius).fill(Color(palette.field)))
            .overlay(RoundedRectangle(cornerRadius: DesktopMetrics.controlRadius)
                .strokeBorder(searchFocused ? Color(palette.accentBright) : Color(palette.separator), lineWidth: searchFocused ? 1.5 : 1))
            .disabled(editing)
            VStack(spacing: 1) {
                ForEach(DesktopSettingsSection.allCases) { navRow($0) }
            }
            .padding(.top, 8)
            Spacer(minLength: 0)
        }
        .padding(DesktopSettingsStyle.sidebarInsets)
    }

    private func navRow(_ section: DesktopSettingsSection) -> some View {
        let selected = !searching && model.section == section
        return Button { model.query = ""; model.section = section } label: {
            HStack(spacing: 10) {
                Image(systemName: section.symbol).font(.system(size: 13)).frame(width: 16, height: 16)
                Text(section.title).lineLimit(1)
                Spacer(minLength: 0)
                if let note = navNote(section) {
                    Text(note).font(.system(size: 11)).foregroundStyle(Color(palette.accentBright))
                }
            }
            .foregroundStyle(Color(selected ? palette.text : palette.secondary))
            .padding(.horizontal, 10)
            .frame(height: DesktopMetrics.navigationRowHeight)
            .background(RoundedRectangle(cornerRadius: DesktopMetrics.controlRadius).fill(selected ? Color(palette.border) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(editing)
        .accessibilityIdentifier("DesktopSettingsSection-\(section.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func navNote(_ section: DesktopSettingsSection) -> String? {
        switch section {
        case .terminalAppearance: model.scope.hasOwnOverrides ? "customized" : nil
        case .keys: recorder.configFile.customOverrides.isEmpty ? nil : String(recorder.configFile.customOverrides.count)
        default: nil
        }
    }

    // MARK: Page

    private func main(compact: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if compact && !editing {
                    Picker("", selection: $model.section) {
                        ForEach(DesktopSettingsSection.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(maxWidth: 240)
                } else {
                    Text(searching ? "Search: “\(model.query)”" : model.section.title)
                        .font(.system(size: DesktopMetrics.titleFontSize, weight: .semibold))
                        .foregroundStyle(Color(palette.text)).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button { model.onClose() } label: {
                    Text("✕").frame(width: DesktopSettingsStyle.closeSize, height: DesktopSettingsStyle.closeSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close · Esc")
                .accessibilityIdentifier("DesktopSettingsClose")
                .accessibilityLabel("Close")
            }
            .padding(DesktopSettingsStyle.topInsets)
            levelLine
            ScrollViewReader { proxy in
                ScrollView {
                    Group {
                        if searching { DesktopSettingsSearchList(model: model, palette: palette) }
                        else if editing { DesktopThemeDraftEditor(model: model, palette: palette) }
                        else { DesktopSettingsSectionBody(model: model, palette: palette) }
                    }
                    .padding(DesktopSettingsStyle.pageInsets)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // A field that takes keyboard focus (click or Tab) scrolls itself into view.
                .environment(\.desktopRevealField, DesktopRevealField { id in proxy.scrollTo(id) })
                .accessibilityIdentifier("DesktopSettingsPage")
            }
            if model.section == .keys, !searching, let status = recorder.status {
                Text(status).font(.system(size: DesktopSettingsStyle.captionSize)).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24).padding(.vertical, 8)
                    .background(Color(palette.background))
                    .accessibilityIdentifier("DesktopShortcutStatus")
            }
            footer
        }
    }

    /// The scope chain on the appearance page, the app-wide note elsewhere.
    @ViewBuilder private var levelLine: some View {
        if !searching && !editing {
            if model.section == .terminalAppearance {
                DesktopScopeChips(model: model, scope: model.scope, palette: palette)
                    .padding(EdgeInsets(top: 0, leading: 24, bottom: 12, trailing: 24))
            } else if let subtitle = model.section.subtitle {
                Text(subtitle).font(.system(size: DesktopSettingsStyle.captionSize)).foregroundStyle(Color(palette.muted))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(EdgeInsets(top: 0, leading: 24, bottom: 12, trailing: 24))
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if editing {
                DesktopThemeDraftFooter(model: model, palette: palette)
            } else {
                DesktopSettingsFooterStatus(model: model, preferences: model.preferences, scope: model.scope,
                                            themes: model.themes, recorder: model.recorder,
                                            showsReset: model.section == .terminalAppearance && !searching,
                                            palette: palette)
            }
        }
        .padding(DesktopSettingsStyle.footerInsets)
        .frame(minHeight: DesktopMetrics.footerHeight)
        .overlay(alignment: .top) { Rectangle().fill(Color(palette.separator)).frame(height: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("DesktopSettingsFooter")
    }
}

/// «For Global › workspace Default › session tako › terminal fish» (reference
/// pfCrumbs): each chip is a button that switches the edited level; «custom»
/// marks a level that stores its own appearance.
/// Accessibility: `DesktopScope-global|workspace|session|pane`; the edited
/// one is `DesktopScopeCurrent`.
struct DesktopScopeChips: View {
    @ObservedObject var model: DesktopSettingsModel
    @ObservedObject var scope: DesktopScopeEditor
    let palette: DesktopPalette

    var body: some View {
        let current = model.currentLevel?.id ?? DesktopScopeLevel.global.id
        HStack(spacing: 6) {
            Text("For").foregroundStyle(Color(palette.muted))
            ForEach(Array(model.levels.enumerated()), id: \.element.id) { index, level in
                if index > 0 { Text("›").foregroundStyle(Color(palette.faint)) }
                chip(level, on: level.id == current)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func chip(_ level: DesktopScopeLevel, on: Bool) -> some View {
        let own = level.hasOwnOverrides(store: model.themes.scopes, configFile: model.configFile)
        return Button { model.onSelectLevel(level) } label: {
            HStack(spacing: 5) {
                if let kind = level.kindTitle {
                    Text(kind).font(.system(size: 11)).foregroundStyle(Color(palette.muted))
                }
                Text(level.name).fontWeight(level.kindTitle == nil ? .regular : .semibold)
                    .foregroundStyle(Color(on ? palette.text : palette.secondary))
                if let note = level.note {
                    Text(note).font(.system(size: 11)).foregroundStyle(Color(palette.muted))
                }
                if own {
                    Text("custom").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color(palette.accentBright))
                }
            }
            .lineLimit(1)
            .padding(.horizontal, 10).frame(height: DesktopMetrics.controlHeight)
            .background(RoundedRectangle(cornerRadius: DesktopMetrics.controlRadius).fill(Color(palette.field)))
            .overlay(RoundedRectangle(cornerRadius: DesktopMetrics.controlRadius)
                .strokeBorder(on ? Color(palette.accentBright) : Color(palette.separator), lineWidth: on ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(on ? "DesktopScopeCurrent" : "DesktopScope-\(Self.kindKey(level.kind))")
        .accessibilityValue(own ? "custom" : "")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    static func kindKey(_ kind: DesktopScopeLevel.Kind) -> String {
        switch kind {
        case .global: "global"
        case .workspace: "workspace"
        case .session: "session"
        case .pane: "pane"
        }
    }
}

/// Search hits grouped by section; a keyboard action shows its keys.
struct DesktopSettingsSearchList: View {
    @ObservedObject var model: DesktopSettingsModel
    let palette: DesktopPalette

    var body: some View {
        let results = model.searchResults
        VStack(alignment: .leading, spacing: 12) {
            if results.isEmpty {
                DesktopHint(text: "No results for “\(model.query)”. You can also search configuration keys.", palette: palette)
            }
            ForEach(DesktopSettingsSection.allCases) { section in
                let hits = results.filter { $0.section == section }.prefix(8)
                if !hits.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Label(section.title, systemImage: section.symbol)
                            .font(.system(size: DesktopSettingsStyle.captionSize, weight: .semibold))
                            .foregroundStyle(Color(palette.text))
                        ForEach(Array(hits)) { hit in result(hit) }
                    }
                }
            }
        }
    }

    private func result(_ hit: DesktopSettingsSearchResult) -> some View {
        Button { model.open(hit) } label: {
            HStack(spacing: 8) {
                Text(hit.title).foregroundStyle(Color(palette.text)).lineLimit(1)
                Spacer(minLength: 8)
                if case .action(let id) = hit.kind {
                    DesktopShortcutCaps(text: model.recorder.display(for: id), palette: palette)
                } else {
                    Text(hit.detail).font(.system(size: DesktopSettingsStyle.keySize, design: .monospaced))
                        .foregroundStyle(Color(palette.faint)).lineLimit(1)
                }
            }
            .padding(.horizontal, 8).frame(minHeight: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(Self.identifier(hit))
    }

    /// An action hit carries its row id so a search can be followed straight to the shortcut.
    static func identifier(_ hit: DesktopSettingsSearchResult) -> String {
        switch hit.kind {
        case .action(let id): "DesktopShortcut-\(id)"
        case .setting(let key): "DesktopSearchSetting-\(key)"
        case .font(let family): "DesktopSearchFont-\(family)"
        case .section: "DesktopSearchSection-\(hit.section.rawValue)"
        }
    }
}
