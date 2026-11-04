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
    private let items = [
        ("paintpalette", "A look that feels right", "Choose a theme with its own colors and type."),
        ("terminal", "Your tools, connected", "Use takoctl in scripts and connect the agents you choose."),
        ("bell", "Stay in the flow", "Decide whether Tako should notify you about finished work.")
    ]
    var body: some View {
        SetupCard {
            ForEach(items, id: \.0) { item in
                HStack(alignment: .top, spacing: 16) {
                    Image(systemName: item.0).font(.system(size: 20)).foregroundStyle(SetupStyle.accent).frame(width: 28)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.1).fontWeight(.semibold)
                        Text(item.2).foregroundStyle(SetupStyle.muted).lineSpacing(4)
                    }
                }.padding(.vertical, 9)
            }
        }
    }
}

@MainActor
struct SetupCommandLineStep: View {
    @ObservedObject var model: SetupModel
    var body: some View {
        SetupCard {
            HStack { Label("takoctl", systemImage: "terminal").fontWeight(.semibold); Spacer()
                SetupBadge(text: model.cli.installed ? "Installed link" : "Optional", ready: model.cli.installed)
            }
            Text(model.cli.detail).foregroundStyle(SetupStyle.muted).textSelection(.enabled)
            Text("takoctl split right\ntakoctl workspace list\ntakoctl theme list")
                .font(.system(size: 12, design: .monospaced)).lineSpacing(7)
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.25), in: .rect(cornerRadius: 5))
            Text("Installation creates a link to this copy of Tako. It won't replace another program. If your shell doesn't include the chosen directory in PATH, add it there.")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(SetupStyle.muted).lineSpacing(4)
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
    @ObservedObject var model: SetupModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SetupCard {
                if model.agents.isEmpty {
                    Text(model.isRefreshing ? "Looking for installed agents…" : "No supported agents found.")
                        .foregroundStyle(SetupStyle.muted)
                }
                ForEach(model.agents) { agent in
                    HStack(alignment: .top, spacing: 12) {
                        Toggle(isOn: Binding(get: { model.selectedAgents.contains(agent.id) }, set: { selected in
                            if selected { model.selectedAgents.insert(agent.id) } else { model.selectedAgents.remove(agent.id) }
                        })) { Text(agent.name).fontWeight(.medium) }
                        .toggleStyle(.checkbox)
                        .disabled(!agent.isDetected || agent.isReady || model.isBusy || model.isRefreshing)
                        .accessibilityIdentifier("SetupAgent-\(agent.id)")
                        Spacer(minLength: 0)
                        SetupBadge(text: agent.isReady ? "Connected" : agent.isDetected ? "Not connected" : "Not found", ready: agent.isReady)
                    }
                    if agent.isDetected {
                        Text(agent.detail ?? "Hooks: \(agent.hooksInstalled ? "ready" : "not installed") · Skill: \(agent.skillInstalled ? "ready" : "not installed")")
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(SetupStyle.muted)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("SetupAgentStatus-\(agent.id)")
                    }
                    if agent.id != model.agents.last?.id { Divider().overlay(SetupStyle.border) }
                }
            }
            Text("Connect installs Tako's lifecycle hooks and skill in each selected agent's configuration. Existing unrelated settings are preserved.")
                .foregroundStyle(SetupStyle.muted).font(.system(size: 11, design: .monospaced)).lineSpacing(4)
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
    @ObservedObject var model: SetupModel
    var body: some View {
        SetupCard {
            HStack { Label("macOS notifications", systemImage: "bell").fontWeight(.semibold); Spacer()
                SetupBadge(text: model.notifications.title,
                           ready: model.notifications.access == .allowed && model.notifications.alerts)
            }
            Text("Enable alerts for completed work and requests for your attention. You can keep using Tako with notifications off.")
                .foregroundStyle(SetupStyle.muted).lineSpacing(4)
            if model.notifications.access == .allowed {
                Text("Alerts: \(model.notifications.alerts ? "on" : "off")  ·  Sound: \(model.notifications.sounds ? "on" : "off")  ·  Badge: \(model.notifications.badges ? "on" : "off")")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(SetupStyle.muted)
                    .accessibilityIdentifier("SetupNotificationDetails")
            }
            HStack {
                if model.notifications.access == .notAsked {
                    Button("Enable notifications") { Task { await model.enableNotifications() } }
                        .buttonStyle(SetupButtonStyle(primary: true)).accessibilityIdentifier("SetupEnableNotifications")
                } else if model.notifications.access != .unavailable {
                    Button("Open macOS Settings") { model.services.openNotificationSettings() }
                        .buttonStyle(SetupButtonStyle()).accessibilityIdentifier("SetupNotificationSettings")
                }
                Button("Check again") { Task { await model.refresh() } }
                    .buttonStyle(SetupButtonStyle()).accessibilityIdentifier("SetupRefreshNotifications")
            }.disabled(model.isBusy || model.isRefreshing)
        }
    }
}

@MainActor
struct SetupReadyStep: View {
    @ObservedObject var model: SetupModel
    var body: some View {
        SetupCard {
            summary("Terminal", detail: "Ready to use", ready: true)
            summary("Command line", detail: model.cli.installed ? "Installed link" : "Not installed", ready: model.cli.installed)
            let count = model.agents.filter(\.isReady).count
            summary("AI agents", detail: count > 0 ? "\(count) connected" : "None connected", ready: count > 0)
            summary("Notifications", detail: model.notifications.title,
                    ready: model.notifications.access == .allowed && model.notifications.alerts)
            Divider().overlay(SetupStyle.border)
            Text("⌘T  new tab     ⌘D  split pane\n⌘,  settings    ⇧⌘P  command palette")
                .font(.system(size: 11, design: .monospaced)).lineSpacing(8).foregroundStyle(SetupStyle.muted)
            Text("Return here any time: Tako → Set Up Tako…")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(SetupStyle.muted)
        }
    }
    private func summary(_ title: String, detail: String, ready: Bool) -> some View {
        HStack { Text(title); Spacer(); SetupBadge(text: detail, ready: ready) }
    }
}
