/*
 * tako — Native settings shell: sidebar, search, section body and footer
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import SwiftUI

struct DesktopSettingsView: View {
    @ObservedObject var model: DesktopSettingsModel
    @ObservedObject private var presentation = DesktopPresentation.shared

    private var palette: DesktopPalette { presentation.palette }

    var body: some View {
        GeometryReader { proxy in
            let compact = DesktopSettingsGeometry.isCompact(proxy.size)
            HStack(spacing: 0) {
                if !compact {
                    sidebar.frame(width: DesktopMetrics.settingsSidebarWidth)
                    Rectangle().fill(Color(palette.separator)).frame(width: 1)
                }
                VStack(spacing: 0) {
                    header(compact: compact)
                    ScrollView {
                        DesktopSettingsSectionBody(model: model, palette: palette)
                            .padding(DesktopMetrics.contentInset)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    footer
                }
                .background(Color(palette.background))
            }
        }
        .font(.system(size: DesktopMetrics.bodyFontSize))
        .foregroundStyle(Color(palette.text))
        .background(Color(palette.panel))
        .sheet(isPresented: Binding(get: { model.draft != nil }, set: { if !$0 { model.cancelDraft() } })) {
            DesktopThemeDraftEditor(model: model, palette: palette)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Поиск настроек, действий, шрифтов", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .frame(height: DesktopMetrics.controlHeight)
                .padding(.horizontal, 12).padding(.top, 14)
            ScrollView {
                VStack(spacing: 2) {
                    if model.query.isEmpty {
                        ForEach(DesktopSettingsSection.allCases) { section in row(section) }
                    } else {
                        searchResults
                    }
                }.padding(.horizontal, 8)
            }
        }
        .background(Color(palette.panel))
    }

    @ViewBuilder private var searchResults: some View {
        let results = model.searchResults
        if results.isEmpty {
            Text("Ничего не найдено").foregroundStyle(Color(palette.muted)).padding(8)
        }
        ForEach(results) { result in
            Button { model.open(result) } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(result.title).lineLimit(1)
                    Text("\(result.section.title) · \(result.detail)").font(.system(size: 11))
                        .foregroundStyle(Color(palette.muted)).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.vertical, 4)
            }.buttonStyle(.plain)
        }
    }

    private func row(_ section: DesktopSettingsSection) -> some View {
        let selected = model.section == section
        return Button { model.section = section } label: {
            HStack(spacing: 8) {
                Image(systemName: section.symbol).frame(width: 18)
                Text(section.title).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: DesktopMetrics.navigationRowHeight)
            .background(RoundedRectangle(cornerRadius: DesktopMetrics.controlRadius)
                .fill(selected ? Color(palette.raised) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings-section-\(section.rawValue)")
    }

    private func header(compact: Bool) -> some View {
        HStack {
            if compact {
                Picker("", selection: $model.section) {
                    ForEach(DesktopSettingsSection.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().frame(maxWidth: 260)
            } else {
                Text(model.section.title).font(.system(size: DesktopMetrics.titleFontSize, weight: .semibold))
            }
            Spacer()
            Text(model.scope.title).foregroundStyle(Color(palette.secondary)).lineLimit(1)
        }
        .padding(.horizontal, DesktopMetrics.contentInset)
        .frame(height: 56)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            DesktopSettingsErrorLine(preferences: model.preferences, scope: model.scope,
                                     themes: model.themes, recorder: model.recorder, palette: palette)
            Spacer()
            Button("Done") { model.onClose() }
                .keyboardShortcut(.cancelAction)
                .controlSize(.regular)
        }
        .padding(.horizontal, DesktopMetrics.contentInset)
        .frame(height: DesktopMetrics.footerHeight)
        .overlay(alignment: .top) { Rectangle().fill(Color(palette.separator)).frame(height: 1) }
    }
}
