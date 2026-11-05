/*
 * tako — Optional macOS permission guidance
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import SwiftUI

@MainActor
struct SetupPermissionsStep: View {
    @Environment(\.setupPalette) private var colors
    @ObservedObject var model: SetupModel
    @StateObject private var service = TerminalPermissionService.live()
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("These checks describe this copy of Tako. Terminal programs can have their own entries in macOS Settings. Allow only the access your work needs.")
                .foregroundStyle(colors.muted).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("SetupPermissionScopeNote")
            ForEach(service.rows) { permission in
                SetupCard {
                    HStack {
                        Label(permission.title, systemImage: symbol(permission.kind)).fontWeight(.medium)
                        Spacer()
                        SetupBadge(text: permission.status.title, ready: permission.isAllowed)
                    }
                    Text(permission.explanation).foregroundStyle(colors.muted)
                        .font(.system(size: 11, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        if permission.canRequest, permission.status == .notAsked {
                            Button("Request access") { Task { await model.requestPermission(permission.kind, service: service) } }
                                .buttonStyle(SetupButtonStyle(primary: true))
                                .accessibilityIdentifier("SetupRequestPermission-\(permission.id)")
                        }
                        Button("Open macOS Settings") {
                            if !service.openSettings(permission.kind) {
                                model.message = "macOS Settings couldn't be opened."
                            }
                        }.buttonStyle(SetupButtonStyle())
                            .accessibilityIdentifier("SetupPermissionSettings-\(permission.id)")
                    }.disabled(model.isBusy || model.isRefreshing || checking)
                }.accessibilityElement(children: .contain)
                    .accessibilityIdentifier("SetupPermission-\(permission.id)")
            }
            Button(checking ? "Checking…" : "Check again") { Task { await refresh() } }
                .buttonStyle(SetupButtonStyle()).disabled(checking || model.isBusy)
                .accessibilityIdentifier("SetupRefreshPermissions")
        }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
    }

    private func refresh() async {
        guard !checking, !model.isBusy else { return }
        checking = true
        await service.snapshot()
        checking = false
    }

    private func symbol(_ kind: TerminalPermissionKind) -> String {
        switch kind {
        case .protectedFolders: "folder.badge.lock"
        case .fullDiskAccess: "internaldrive"
        case .localNetwork: "network"
        case .microphone: "mic"
        case .screenCapture: "rectangle.dashed"
        case .systemAudio: "speaker.wave.2"
        case .automation: "applescript"
        }
    }
}
