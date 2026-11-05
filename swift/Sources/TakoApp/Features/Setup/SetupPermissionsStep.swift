// Tako — macOS permission setup
// Copyright (c) 2026 Alexander Panasenko
// Contact: alex@prod.codes
// Author: https://prod.codes/about/
// Project: https://github.com/alex09x/tako
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

@MainActor
struct SetupPermissionsStep: View {
    @Environment(\.setupPalette) private var colors
    @ObservedObject var model: SetupModel
    @StateObject private var service = TerminalPermissionService.live()
    @State private var checking = false
    @State private var showDiskHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 0) {
                fileAccessRow
                Divider().overlay(colors.border)
                permissionRow(.fullDiskAccess)
            }
            .padding(.horizontal, 16)
            .background(colors.card, in: .rect(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(colors.border))
            DisclosureGroup("Other permissions") {
                VStack(spacing: 0) {
                    ForEach(service.rows.filter { ![.protectedFolders, .fullDiskAccess].contains($0.kind) }) { permission in
                        permissionRow(permission.kind)
                        if permission.kind != .automation { Divider().overlay(colors.border) }
                    }
                }
            }
            Text("Checks apply to Tako. Terminal programs can have separate permissions.")
                .font(.system(size: 12)).foregroundStyle(colors.muted)
                .accessibilityIdentifier("SetupPermissionScopeNote")
            Button(checking ? "Checking…" : "Refresh status") { Task { await refresh() } }
                .buttonStyle(SetupButtonStyle()).disabled(checking || model.isBusy)
                .accessibilityIdentifier("SetupRefreshPermissions")
        }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
        .alert("Enable Full Disk Access", isPresented: $showDiskHelp) {
            Button("Open Settings") { _ = service.openSettings(.fullDiskAccess) }
            Button("Show Tako in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Turn on Tako in Full Disk Access. If it isn't listed, press + and add this app. macOS requires this step in Settings.")
        }
    }

    private var fileAccessRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Image(systemName: "folder").frame(width: 20).foregroundStyle(colors.muted)
                VStack(alignment: .leading, spacing: 4) {
                    Text("File access").fontWeight(.medium)
                    Text("Desktop, Documents and Downloads")
                        .font(.system(size: 12)).foregroundStyle(colors.muted)
                }
                Spacer(minLength: 8)
                Button(model.folderAccess.isEmpty ? "Check file access" : "Check again") {
                    Task { await model.checkFolderAccess() }
                }
                .buttonStyle(SetupButtonStyle())
                .help("Check folder access. macOS may ask you to allow it. No files are read.")
                .accessibilityIdentifier("SetupCheckFileAccess")
            }
            if !model.folderAccess.isEmpty {
                ForEach(model.folderAccess, id: \.folder) { result in
                    HStack {
                        Text(result.folder.lastPathComponent)
                        Spacer()
                        SetupBadge(text: result.status == .unknown ? "Unavailable" : result.status.title,
                                   ready: result.readable, showsSymbol: false)
                    }
                    .font(.system(size: 12)).padding(.leading, 34)
                    .accessibilityIdentifier("SetupFolderResult-\(result.folder.lastPathComponent)")
                }
            }
        }
        .padding(.vertical, 16)
        .disabled(model.isBusy || model.isRefreshing || checking)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SetupPermission-protectedFolders")
    }

    private func permissionRow(_ kind: TerminalPermissionKind) -> some View {
        let status = service.permission(for: kind)?.status ?? .unknown
        return HStack(spacing: 14) {
            Image(systemName: symbol(kind)).frame(width: 20).foregroundStyle(colors.muted)
            VStack(alignment: .leading, spacing: 4) {
                Text(kind.title).fontWeight(.medium)
                Text(kind.explanation).font(.system(size: 12)).foregroundStyle(colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if status == .allowed {
                SetupBadge(text: "Allowed", ready: true)
            } else {
                if ![.managedInSettings, .unknown].contains(status) {
                    SetupBadge(text: status.title, showsSymbol: false)
                }
                Button(kind.canRequestDirectly && ![.denied, .restricted].contains(status) ? "Allow…" : "Settings…") {
                    if kind.canRequestDirectly && ![.denied, .restricted].contains(status) {
                        Task { await model.requestPermission(kind, service: service) }
                    } else if kind == .fullDiskAccess {
                        showDiskHelp = true
                    } else if !service.openSettings(kind) {
                        model.message = "macOS Settings couldn't be opened."
                    }
                }
                .buttonStyle(SetupButtonStyle())
                .accessibilityIdentifier("SetupPermissionAction-\(kind.id)")
            }
        }
        .padding(.vertical, 16)
        .disabled(model.isBusy || model.isRefreshing || checking)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SetupPermission-\(kind.id)")
    }

    private func refresh() async {
        guard !checking, !model.isBusy else { return }
        checking = true
        await service.snapshot()
        checking = false
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
