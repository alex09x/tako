/*
 * tako — Branded first-run setup sheet (five visible stages)
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import SwiftUI

@MainActor
struct SetupWizardView: View {
    @ObservedObject var model: SetupModel
    @ObservedObject var presentation: DesktopPresentation = .shared
    private var colors: SetupPalette { SetupPalette(desktop: presentation.palette, isDark: presentation.isDark) }

    var body: some View {
        GeometryReader { proxy in
            let compact = SetupSheetGeometry.isCompact(proxy.size)
            VStack(alignment: .leading, spacing: 0) {
                if model.stage != .welcome {
                    SetupStageBar(model: model).padding(.top, 18).padding(.bottom, 14)
                }
                if ![.welcome, .ready].contains(model.stage) {
                    header.padding(.bottom, 14)
                }
                ScrollView {
                    content(compact: compact).frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 12)
                }
                if let message = model.message {
                    Text(message).font(.system(size: 12)).foregroundStyle(colors.message)
                        .padding(.vertical, 6).accessibilityIdentifier("SetupMessage")
                }
                footer
            }
            .padding(.horizontal, compact ? 20 : 28)
        }
        .font(.system(size: 13))
        .foregroundStyle(colors.text)
        .tint(colors.accent)
        .background(colors.background)
        .environment(\.setupPalette, colors)
        .preferredColorScheme(colors.isDark ? .dark : .light)
        .frame(minWidth: SetupSheetGeometry.minimum.width, minHeight: SetupSheetGeometry.minimum.height)
        // Passive refresh reads detection and notification state only; no prompts, no folder probes.
        .task { await model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 20, weight: .semibold)).accessibilityIdentifier("SetupStepTitle")
            Text(subtitle).foregroundStyle(colors.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button(model.stage == .ready ? "Close" : "Finish later") { model.dismiss() }
                .buttonStyle(.plain).foregroundStyle(colors.muted)
                .keyboardShortcut(.cancelAction).accessibilityIdentifier("SetupLater")
            if model.isBusy || model.isRefreshing {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(model.isBusy ? "Applying setup" : "Checking current setup")
            }
            Spacer()
            if model.stage != .welcome {
                Button("Back") { model.backStage() }.buttonStyle(.plain).foregroundStyle(colors.muted)
                    .accessibilityIdentifier("SetupBack")
            }
            if ![.welcome, .ready].contains(model.stage) {
                Button("Skip") { model.nextStage(skipping: true) }
                    .buttonStyle(.plain).foregroundStyle(colors.muted).accessibilityIdentifier("SetupSkip")
                Button("Continue") { model.nextStage() }
                    .buttonStyle(SetupButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("SetupNext")
            }
        }
        .disabled(model.isBusy)
        .padding(.vertical, 16)
    }

    @ViewBuilder private func content(compact: Bool) -> some View {
        switch model.stage {
        case .welcome: SetupWelcomeHero(model: model, compact: compact)
        case .appearance: SetupAppearanceStep(model: model)
        case .agents:
            VStack(alignment: .leading, spacing: 16) {
                SetupAgentsStep(model: model)
                SetupCommandLineStep(model: model)
            }
        case .access:
            VStack(alignment: .leading, spacing: 16) {
                SetupNotificationsStep(model: model)
                SetupPermissionPanel(model: model)
            }
        case .ready: SetupReadyHero(model: model)
        }
    }

    private var title: String {
        switch model.stage {
        case .welcome, .ready: ""
        case .appearance: "Find your colors"
        case .agents: "Your agents"
        case .access: "macOS access"
        }
    }

    private var subtitle: String {
        switch model.stage {
        case .welcome, .ready: ""
        case .appearance: "The window updates immediately; fonts stay as you configured them."
        case .agents: "Detected agents and how Tako sees their status. Adding a skill is optional."
        case .access: "Choose the access your work needs. Statuses apply to Tako, not to other processes or remote hosts."
        }
    }
}
