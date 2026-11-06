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
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                ForEach([TerminalPermissionKind.protectedFolders, .fullDiskAccess, .localNetwork,
                         .microphone, .screenCapture, .systemAudio]) { kind in
                    tile(title: title(kind), symbol: symbol(kind), tint: tint(kind),
                         purpose: purpose(kind), status: statusText(kind),
                         action: actionText(kind), allowed: isAllowed(kind),
                         identifier: "SetupPermission-\(kind.id)") { activate(kind) }
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
            HStack {
                Text("Optional. Checks apply to Tako.")
                    .help("Terminal programs can have separate permissions. Only enable the access your work needs.")
                    .accessibilityIdentifier("SetupPermissionScopeNote")
                Spacer()
                Button("App control…") { explaining = .automation }
                    .buttonStyle(.plain).accessibilityIdentifier("SetupPermission-automation")
            }
            .font(.system(size: 12)).foregroundStyle(colors.muted)
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

    private func tile(title: String, symbol: String, tint: Color, purpose: String, status: String,
                      action: String, allowed: Bool, identifier: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            VStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 25, weight: .medium)).foregroundStyle(.white)
                    .frame(width: 46, height: 46).background(tint.gradient, in: .rect(cornerRadius: 12))
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(colors.text)
                    .lineLimit(1)
                Text(purpose).font(.system(size: 11)).foregroundStyle(colors.muted)
                    .multilineTextAlignment(.center).lineLimit(2).frame(height: 28)
                HStack(spacing: 4) {
                    Text(action)
                    Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                }.font(.system(size: 11, weight: .semibold)).foregroundStyle(colors.accent)
            }
            .padding(.horizontal, 10).padding(.vertical, 14).frame(maxWidth: .infinity)
            .background(colors.text.opacity(0.04), in: .rect(cornerRadius: 12))
            .overlay(alignment: .topTrailing) {
                if allowed {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(colors.success)
                        .font(.system(size: 14)).padding(10).accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(title).accessibilityValue(status).accessibilityHint(purpose)
        .accessibilityIdentifier(identifier)
    }

    private func isAllowed(_ kind: TerminalPermissionKind) -> Bool {
        if kind == .protectedFolders { return !model.folderAccess.isEmpty && model.folderAccess.allSatisfy(\.readable) }
        return service.permission(for: kind)?.status == .allowed
    }

    private func actionText(_ kind: TerminalPermissionKind) -> String {
        switch kind {
        case .protectedFolders: return model.folderAccess.isEmpty ? "Check access" : "Check again"
        case .fullDiskAccess: return "Set up access"
        case .systemAudio, .automation: return "Set up"
        case .microphone, .screenCapture, .localNetwork:
            let status = service.permission(for: kind)?.status ?? .unknown
            if status == .allowed { return "Manage" }
            if [.denied, .restricted].contains(status) || kind == .localNetwork && networkRequested { return "Open Settings" }
            return "Allow access"
        }
    }

    private func statusText(_ kind: TerminalPermissionKind) -> String {
        if kind == .protectedFolders {
            return model.folderAccess.isEmpty ? "Check access" : "\(model.folderAccess.filter(\.readable).count) of \(model.folderAccess.count) readable"
        }
        if kind == .systemAudio { return "Configure" }
        if kind == .automation { return "Per app" }
        let status = service.permission(for: kind)?.status ?? .unknown
        if status == .managedInSettings {
            return kind == .localNetwork ? networkRequested ? "Open Settings" : "Allow access" : "Open Settings"
        }
        return status.title
    }

    private func title(_ kind: TerminalPermissionKind) -> String {
        switch kind {
        case .protectedFolders: "Folder access"
        case .fullDiskAccess: "Full file access"
        default: kind.title
        }
    }

    private func purpose(_ kind: TerminalPermissionKind) -> String {
        switch kind {
        case .protectedFolders: "Desktop, Documents and Downloads"
        case .fullDiskAccess: "Files beyond standard folders"
        case .localNetwork: "Nearby computers and services"
        case .microphone: "Audio from your microphone"
        case .screenCapture: "Capture windows and displays"
        case .systemAudio: "Record sound from other apps"
        case .automation: "Control another app"
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
