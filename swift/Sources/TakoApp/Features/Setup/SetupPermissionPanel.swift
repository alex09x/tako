// Tako — system access panel
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
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: SetupModel
    @StateObject private var service = TerminalPermissionService.live()
    @State private var showDiskHelp = false

    var body: some View {
        VStack(spacing: 14) {
            ScrollView {
            VStack(spacing: 18) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().frame(width: 64, height: 64)
            Text("Manage permissions").font(.system(size: 25, weight: .bold))
            VStack(spacing: 0) {
                fileAccess
                divider
                row(title: "Protected files", detail: "Let tools work with files beyond your standard folders.",
                    symbol: "internaldrive", status: .managedInSettings) {
                    showDiskHelp = true
                }
                .accessibilityIdentifier("SetupPermission-fullDiskAccess")
                divider
                row(title: "Notifications", detail: "Know when work finishes or needs your attention.",
                    symbol: "bell.badge", status: notificationPermission) {
                    if model.notifications.access == .notAsked {
                        Task { await model.enableNotifications() }
                    } else { model.services.openNotificationSettings() }
                }
            }
            .padding(.horizontal, 14)
            .background(colors.text.opacity(0.045), in: .rect(cornerRadius: 12))

            DisclosureGroup("More permissions") {
                VStack(spacing: 0) {
                    ForEach(service.rows.filter { ![.protectedFolders, .fullDiskAccess].contains($0.kind) }) { permission in
                        row(title: permission.title, detail: permission.explanation,
                            symbol: symbol(permission.kind), status: permission.status) {
                            if permission.canRequest && ![.denied, .restricted].contains(permission.status) {
                                Task { await model.requestPermission(permission.kind, service: service) }
                            } else { _ = service.openSettings(permission.kind) }
                        }
                    }
                }
            }
            .font(.system(size: 12)).foregroundStyle(colors.muted)
            Text("Checks apply to Tako. Terminal programs can have separate permissions.")
                .font(.system(size: 11)).foregroundStyle(colors.muted)
                .accessibilityIdentifier("SetupPermissionScopeNote")
            if let message = model.message {
                Text(message).font(.system(size: 12)).foregroundStyle(colors.message)
            }
            }
            }.scrollIndicators(.hidden)
            Button("Done") { dismiss() }.buttonStyle(SetupButtonStyle())
                .keyboardShortcut(.cancelAction).accessibilityIdentifier("SetupPermissionsDone")
        }
        .padding(24).frame(width: 500, height: 580)
        .font(.system(size: 13)).foregroundStyle(colors.text).background(colors.background)
        .disabled(model.isBusy || model.isRefreshing)
        .interactiveDismissDisabled(model.isBusy)
        .task { await service.snapshot() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await service.snapshot() }
        }
        .alert("Allow access to protected files", isPresented: $showDiskHelp) {
            Button("Open Settings") { _ = service.openSettings(.fullDiskAccess) }
            Button("Show Tako in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Turn on Tako in Full Disk Access. If it isn't listed, press + and add this app.")
        }
    }

    private var fileAccess: some View {
        VStack(spacing: 0) {
            row(title: "Your files", detail: "Desktop, Documents and Downloads. No folder picking.",
                symbol: "folder", status: .unknown, actionTitle: "Check access") {
                Task { await model.checkFolderAccess() }
            }
            .accessibilityIdentifier("SetupPermission-protectedFolders")
            ForEach(model.folderAccess, id: \.folder) { result in
                HStack {
                    Text(result.folder.lastPathComponent)
                    Spacer()
                    SetupBadge(text: result.status == .unknown ? "Unavailable" : result.status.title,
                               ready: result.readable, showsSymbol: false)
                }
                .font(.system(size: 12)).padding(.leading, 44).padding(.bottom, 8)
            }
        }
    }

    private var divider: some View { Rectangle().fill(colors.border).frame(height: 1) }

    private var notificationPermission: TerminalPermissionStatus {
        switch model.notifications.access {
        case .allowed: .allowed
        case .denied: .denied
        case .notAsked: .notAsked
        case .unavailable: .unknown
        }
    }

    private func row(title: String, detail: String, symbol: String,
                     status: TerminalPermissionStatus, actionTitle: String = "Allow…",
                     action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 19))
                .foregroundStyle(colors.muted).frame(width: 34, height: 34)
                .background(colors.text.opacity(0.06), in: .rect(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 2)
            if status == .allowed { SetupBadge(text: "Allowed", ready: true) }
            else {
                VStack(spacing: 4) {
                    Button(actionTitle, action: action).buttonStyle(SetupButtonStyle()).fixedSize()
                    if ![.unknown, .managedInSettings].contains(status) {
                        Text(status.title).font(.system(size: 10)).foregroundStyle(colors.muted)
                    }
                }
            }
        }
        .padding(.vertical, 14)
        .accessibilityElement(children: .contain)
    }

    private func symbol(_ kind: TerminalPermissionKind) -> String {
        switch kind {
        case .protectedFolders: "folder"
        case .fullDiskAccess: "internaldrive"
        case .localNetwork: "network"
        case .microphone: "mic"
        case .screenCapture: "rectangle.dashed"
        case .systemAudio: "speaker.wave.2"
        case .automation: "applescript"
        }
    }
}
