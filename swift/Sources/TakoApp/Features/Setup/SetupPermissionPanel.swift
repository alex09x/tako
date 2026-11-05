// Tako — permission action tiles
// Copyright (c) 2026 Alexander Panasenko
// Contact: alex@prod.codes
// Author: https://prod.codes/about/
// Project: https://github.com/alex09x/tako
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

@MainActor
struct SetupPermissionPanel: View {
    @Environment(\.setupPalette) private var colors
    @ObservedObject var model: SetupModel
    @StateObject private var service = TerminalPermissionService.live()
    @State private var showDiskHelp = false
    @State private var explaining: TerminalPermissionKind?
    private var networkRequested: Bool { model.permissionRequests.contains(.localNetwork) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                ForEach(TerminalPermissionKind.allCases) { kind in
                    tile(title: title(kind), symbol: symbol(kind), tint: tint(kind),
                         status: statusText(kind), identifier: "SetupPermission-\(kind.id)") { activate(kind) }
                }
                tile(title: "Notifications", symbol: "bell.badge.fill", tint: .orange,
                     status: model.notifications.title, identifier: "SetupPermission-notifications") {
                    if model.notifications.access == .notAsked {
                        Task { await model.enableNotifications() }
                    } else { model.services.openNotificationSettings() }
                }
            }
            if !model.folderAccess.isEmpty {
                HStack {
                    ForEach(model.folderAccess, id: \.folder) { result in
                        Label(result.folder.lastPathComponent, systemImage: result.readable ? "checkmark.circle" : "questionmark.circle")
                            .foregroundStyle(result.readable ? colors.success : colors.muted)
                    }
                }.font(.system(size: 11))
            }
            Text("Choose a permission to request or configure it. Checks apply to Tako; terminal programs can have separate permissions.")
                .font(.system(size: 12)).foregroundStyle(colors.muted)
                .accessibilityIdentifier("SetupPermissionScopeNote")
        }
        .disabled(model.isBusy || model.isRefreshing)
        .task { await service.snapshot() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await service.snapshot() }
        }
        .sheet(isPresented: $showDiskHelp) {
            SetupDiskAccessGuide(openSettings: { service.openSettings(.fullDiskAccess) })
                .environment(\.setupPalette, colors)
        }
        .sheet(item: $explaining) { kind in
            VStack(alignment: .leading, spacing: 16) {
                Label(kind.title, systemImage: symbol(kind)).font(.system(size: 20, weight: .semibold))
                Text(kind == .systemAudio
                    ? "macOS asks when a tool starts recording another app's audio. Playing sound and notification alerts do not need this recording permission."
                    : "macOS asks when a script first controls another app. In Automation settings, enable the target app for the program named in that request.")
                    .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                Button("Open Settings") { _ = service.openSettings(kind) }.buttonStyle(SetupButtonStyle())
                Button("Back") { explaining = nil }.buttonStyle(SetupButtonStyle())
                    .keyboardShortcut(.cancelAction).accessibilityIdentifier("SetupExplanationBack")
            }
            .padding(24).frame(width: 380).foregroundStyle(colors.text).background(colors.background)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("SetupPermissionExplanation-\(kind.id)")
        }
    }

    private func activate(_ kind: TerminalPermissionKind) {
        switch kind {
        case .protectedFolders: Task { await model.checkFolderAccess() }
        case .fullDiskAccess: showDiskHelp = true
        case .systemAudio, .automation: explaining = kind
        case .microphone, .screenCapture, .localNetwork:
            let status = service.permission(for: kind)?.status ?? .unknown
            if [.denied, .restricted, .allowed].contains(status) || kind == .localNetwork && networkRequested {
                _ = service.openSettings(kind)
            } else {
                Task { await model.requestPermission(kind, service: service) }
            }
        }
    }

    private func tile(title: String, symbol: String, tint: Color, status: String,
                      identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 9) {
                Image(systemName: symbol).font(.system(size: 25, weight: .medium)).foregroundStyle(.white)
                    .frame(width: 46, height: 46).background(tint.gradient, in: .rect(cornerRadius: 12))
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(colors.text)
                    .lineLimit(2).multilineTextAlignment(.center).frame(height: 30)
                Text(status).font(.system(size: 10)).foregroundStyle(colors.muted).lineLimit(1)
            }
            .padding(.vertical, 14).frame(maxWidth: .infinity)
            .background(colors.text.opacity(0.04), in: .rect(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(title).accessibilityValue(status)
        .accessibilityIdentifier(identifier)
    }

    private func statusText(_ kind: TerminalPermissionKind) -> String {
        if kind == .protectedFolders {
            return model.folderAccess.isEmpty ? "Check access" : "\(model.folderAccess.filter(\.readable).count) of \(model.folderAccess.count) readable"
        }
        if kind == .systemAudio { return "When recording" }
        if kind == .automation { return "Per app" }
        let status = service.permission(for: kind)?.status ?? .unknown
        if status == .managedInSettings {
            return kind == .localNetwork ? networkRequested ? "Open Settings" : "Request access" : "Set up"
        }
        return status.title
    }

    private func title(_ kind: TerminalPermissionKind) -> String {
        switch kind {
        case .protectedFolders: "Your files"
        case .fullDiskAccess: "Protected files"
        default: kind.title
        }
    }

    private func symbol(_ kind: TerminalPermissionKind) -> String {
        switch kind {
        case .protectedFolders: "folder.fill"
        case .fullDiskAccess: "internaldrive.fill"
        case .localNetwork: "network"
        case .microphone: "mic.fill"
        case .screenCapture: "rectangle.inset.filled"
        case .systemAudio: "speaker.wave.2.fill"
        case .automation: "applescript.fill"
        }
    }

    private func tint(_ kind: TerminalPermissionKind) -> Color {
        switch kind {
        case .protectedFolders: .blue
        case .fullDiskAccess: .indigo
        case .localNetwork: .teal
        case .microphone: .red
        case .screenCapture: .purple
        case .systemAudio: .pink
        case .automation: .gray
        }
    }
}
