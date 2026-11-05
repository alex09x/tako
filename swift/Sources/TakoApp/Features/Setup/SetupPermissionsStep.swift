// Tako — setup integrations and permissions
// Copyright (c) 2026 Alexander Panasenko
// Contact: alex@prod.codes
// Author: https://prod.codes/about/
// Project: https://github.com/alex09x/tako
// SPDX-License-Identifier: MIT

import SwiftUI

@MainActor
struct SetupPermissionsStep: View {
    @Environment(\.setupPalette) private var colors
    @ObservedObject var model: SetupModel
    @State private var showingPermissions = false

    var body: some View {
        HStack(alignment: .top, spacing: 1) {
            accessCard(title: "AI agents", caption: model.agents.contains(where: \.isReady) ? "Connected" : "Recommended",
                description: "Give your agents Tako's tools and live status.",
                action: model.agents.contains(where: \.isReady) ? "Manage agents" : "Connect agents",
                identifier: "SetupAgentsCard", onPress: { model.select(.agents) }) {
                HStack(spacing: -4) {
                    SetupAgentIcon(id: "claude", size: 28)
                    SetupAgentIcon(id: "codex", size: 28)
                    SetupAgentIcon(id: "gemini", size: 28)
                }.frame(height: 48)
            }
            accessCard(title: "System permissions", caption: "Optional",
                description: "Allow access to your files and task notifications.",
                action: "Review access", identifier: "SetupSystemPermissionsCard",
                onPress: { showingPermissions = true }) {
                Image(systemName: "hand.raised.fill").font(.system(size: 27, weight: .medium))
                    .foregroundStyle(.white).frame(width: 48, height: 48)
                    .background(Color.blue.gradient, in: .rect(cornerRadius: 12))
            }
        }
        .background(colors.text.opacity(0.035), in: .rect(cornerRadius: 14))
        .frame(maxWidth: 540)
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $showingPermissions) {
            SetupPermissionPanel(model: model)
                .environment(\.setupPalette, colors)
        }
    }

    private func accessCard<Icon: View>(title: String, caption: String, description: String,
        action: String, identifier: String, onPress: @escaping () -> Void,
        @ViewBuilder icon: () -> Icon) -> some View {
        VStack(spacing: 12) {
            icon().padding(.top, 8)
            VStack(spacing: 6) {
                Text(title).font(.system(size: 16, weight: .semibold))
                Text(caption).font(.system(size: 10, weight: .medium))
                    .foregroundStyle(colors.muted).padding(.horizontal, 8).padding(.vertical, 3)
                    .background(colors.text.opacity(0.06), in: .capsule)
            }
            Text(description).font(.system(size: 13)).foregroundStyle(colors.muted)
                .multilineTextAlignment(.center).frame(height: 42)
            Button(action, action: onPress).buttonStyle(SetupButtonStyle())
                .disabled(model.isBusy || model.isRefreshing)
                .accessibilityIdentifier(identifier)
        }
        .padding(18).frame(maxWidth: .infinity)
    }
}
