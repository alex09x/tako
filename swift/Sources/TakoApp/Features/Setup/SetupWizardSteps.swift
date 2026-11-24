/*
 * tako — Optional setup integration cards
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import SwiftUI

struct SetupWelcomeStep: View {
    @Environment(\.setupPalette) private var colors
    private let items = [
        ("paintpalette", "A look that feels right", "Choose a theme with its own colors and type."),
        ("terminal", "Your tools, connected", "Use takoctl in scripts and connect the agents you choose."),
        ("bell", "Stay in the flow", "Decide whether Tako should notify you about finished work.")
    ]
    var body: some View {
        SetupCard {
            ForEach(items, id: \.0) { item in
                HStack(alignment: .top, spacing: 16) {
                    Image(systemName: item.0).font(.system(size: 20)).foregroundStyle(colors.accent).frame(width: 28)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.1).fontWeight(.semibold)
                        Text(item.2).foregroundStyle(colors.muted).lineSpacing(4)
                    }
                }.padding(.vertical, 9)
            }
        }
    }
}

@MainActor
struct SetupCommandLineStep: View {
    @Environment(\.setupPalette) private var colors
    @ObservedObject var model: SetupModel
    var body: some View {
        SetupCard {
            HStack { Label("takoctl", systemImage: "terminal").fontWeight(.semibold); Spacer()
                SetupBadge(text: model.cli.installed ? "Installed link" : "Optional", ready: model.cli.installed)
            }
            Text(model.cli.detail).foregroundStyle(colors.muted).textSelection(.enabled)
            Text("takoctl split right\ntakoctl workspace list\ntakoctl theme list")
                .font(.system(size: 12, design: .monospaced)).lineSpacing(7)
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.25), in: .rect(cornerRadius: 5))
            Text("Installation creates a link to this copy of Tako. It won't replace another program. If your shell doesn't include the chosen directory in PATH, add it there.")
                .font(.system(size: 13)).foregroundStyle(colors.muted).lineSpacing(4)
            Button(model.cli.installed ? "Check again" : "Install takoctl") {
                if model.cli.installed { Task { await model.refresh() } } else { model.installCLI() }
            }
            .buttonStyle(SetupButtonStyle(primary: !model.cli.installed))
            .accessibilityIdentifier("SetupInstallCLI")
        }
    }
}

@MainActor
struct SetupAgentsStep: View {
    @Environment(\.setupPalette) private var colors
    @ObservedObject var model: SetupModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SetupCard {
                if model.agents.isEmpty {
                    Text(model.isRefreshing ? "Looking for installed agents…" : "No supported agents found.")
                        .foregroundStyle(colors.muted)
                }
                ForEach(model.agents) { agent in
                    HStack(alignment: .top, spacing: 12) {
                        Button {
                            if model.selectedAgents.contains(agent.id) { model.selectedAgents.remove(agent.id) }
                            else { model.selectedAgents.insert(agent.id) }
                        } label: {
                            HStack(spacing: 8) {
                                SetupAgentIcon(id: agent.id)
                                    .overlay(alignment: .bottomTrailing) {
                                        if !agent.isReady && model.selectedAgents.contains(agent.id) {
                                            Image(systemName: "checkmark").font(.system(size: 6, weight: .bold))
                                                .foregroundStyle(colors.background).frame(width: 8, height: 8)
                                                .background(colors.accent, in: .circle).offset(x: 3, y: 3)
                                        }
                                    }
                                Text(agent.name).fontWeight(.medium)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(agent.name)
                        .accessibilityValue(agent.isReady ? "Connected" : model.selectedAgents.contains(agent.id) ? "Selected" : "Not selected")
                        .disabled(!agent.isDetected || agent.isReady || model.isBusy || model.isRefreshing)
                        .accessibilityIdentifier("SetupAgent-\(agent.id)")
                        Spacer(minLength: 0)
                        SetupBadge(text: agent.isReady ? "Connected" : agent.isDetected ? "Not connected" : "Not found",
                                   ready: agent.isReady, showsSymbol: false)
                    }
                    if agent.isDetected {
                        let statusSummary = agent.usesNativeStatus
                            ? "Status: built-in (OSC 7501) · Skill: \(agent.skillInstalled ? "ready" : "not installed")"
                            : "Hooks: \(agent.hooksInstalled ? "ready" : "not installed") · Skill: \(agent.skillInstalled ? "ready" : "not installed")"
                        Text(agent.detail ?? statusSummary)
                            .font(.system(size: 12)).foregroundStyle(colors.muted)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("SetupAgentStatus-\(agent.id)")
                    }
                    if agent.id != model.agents.last?.id { Divider().overlay(colors.border) }
                }
            }
            Text("Connect installs Tako's skill for selected agents and configures lifecycle hooks where needed. Existing unrelated settings are preserved.")
                .foregroundStyle(colors.muted).font(.system(size: 13)).lineSpacing(4)
            HStack {
                Button("Connect selected") { Task { await model.connectSelected() } }
                    .buttonStyle(SetupButtonStyle(primary: true))
                    .disabled(model.selectedDetectedAgents.isEmpty || model.isBusy || model.isRefreshing)
                    .accessibilityIdentifier("SetupConnectAgents")
                Button("Check again") { Task { await model.refresh() } }.buttonStyle(SetupButtonStyle())
                    .disabled(model.isBusy || model.isRefreshing).accessibilityIdentifier("SetupRefreshAgents")
            }
        }
    }
}

@MainActor
struct SetupNotificationsStep: View {
    @Environment(\.setupPalette) private var colors
    @ObservedObject var model: SetupModel
    var body: some View {
        VStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "bell.badge.fill").font(.system(size: 23))
                        .foregroundStyle(.white).frame(width: 44, height: 44)
                        .background(Color.orange.gradient, in: .rect(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Tako").font(.system(size: 14, weight: .semibold))
                        Text("Notification preview").font(.system(size: 11)).foregroundStyle(colors.muted)
                    }
                    Spacer()
                    Text("now").font(.system(size: 11)).foregroundStyle(colors.muted)
                }
                Text("Your task is ready").font(.system(size: 16, weight: .semibold))
                Text("Know when work finishes or an agent needs you.")
                    .font(.system(size: 13)).foregroundStyle(colors.muted)
            }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(colors.text.opacity(0.045), in: .rect(cornerRadius: 14))
            HStack {
                Label(model.notifications.title, systemImage: model.notifications.access == .allowed ? "checkmark.circle.fill" : "bell.slash")
                    .foregroundStyle(model.notifications.access == .allowed ? colors.success : colors.muted)
                Spacer()
                if model.notifications.access == .allowed {
                    Label(model.notifications.alerts ? "Banners on" : "Banners off", systemImage: "rectangle.topthird.inset.filled")
                        .foregroundStyle(colors.muted)
                }
            }
            .font(.system(size: 12)).accessibilityIdentifier("SetupNotificationDetails")
            HStack(spacing: 12) {
                if model.notifications.access == .notAsked {
                    Button("Enable notifications") { Task { await model.enableNotifications() } }
                        .buttonStyle(SetupButtonStyle(primary: true)).accessibilityIdentifier("SetupEnableNotifications")
                } else if model.notifications.access != .unavailable {
                    Button("Settings…") { model.services.openNotificationSettings() }
                        .buttonStyle(SetupButtonStyle()).accessibilityIdentifier("SetupNotificationSettings")
                }
                Button(model.isBusy ? "Sending…" : "Send test notification") { Task { await model.checkNotificationsAndSendTest() } }
                    .buttonStyle(SetupButtonStyle(primary: model.notifications.access == .allowed))
                    .accessibilityIdentifier("SetupRefreshNotifications")
            }.disabled(model.isBusy || model.isRefreshing)
            Text("No banner? macOS can hide notifications during Focus or screen sharing.")
                .font(.system(size: 12)).foregroundStyle(colors.muted).multilineTextAlignment(.center)
                .accessibilityIdentifier("SetupNotificationPresentationHint")
        }
        .frame(maxWidth: 440).frame(maxWidth: .infinity)
    }
}

@MainActor
struct SetupReadyStep: View {
    @Environment(\.setupPalette) private var colors
    @ObservedObject var model: SetupModel
    var body: some View {
        SetupCard {
            summary("Terminal", detail: "Ready to use", ready: true)
            summary("Command line", detail: model.cli.installed ? "Installed link" : "Not installed", ready: model.cli.installed)
            let count = model.agents.filter(\.isReady).count
            summary("AI agents", detail: count > 0 ? "\(count) connected" : "None connected", ready: count > 0)
            summary("Notifications", detail: model.notifications.title,
                    ready: model.notifications.access == .allowed && model.notifications.alerts)
            Divider().overlay(colors.border)
            Text("⌘T  new tab     ⌘D  split pane\n⌘,  settings    ⇧⌘P  command palette")
                .font(.system(size: 11, design: .monospaced)).lineSpacing(8).foregroundStyle(colors.muted)
            Text("Return here any time: Tako → Set Up Tako…")
                .font(.system(size: 12)).foregroundStyle(colors.muted)
        }
    }
    private func summary(_ title: String, detail: String, ready: Bool) -> some View {
        HStack { Text(title); Spacer(); SetupBadge(text: detail, ready: ready) }
    }
}
