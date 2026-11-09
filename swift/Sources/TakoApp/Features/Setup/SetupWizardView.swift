/*
 * tako — First-run wizard: five stages as the frozen reference draws them (A14–A16)
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import SwiftUI

/// Card padding from the reference: top bar 16/28, body 20/28/8, footer 12/28/18.
/// Accessibility: `SetupNext` (Get Started / Continue), `SetupBack`, `SetupLater`
/// (Finish Later / Close), `SetupFinish`, `SetupStep-<step>`, `SetupStepTitle`.
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
                    SetupStageBar(model: model)
                        .padding(EdgeInsets(top: 16, leading: compact ? 20 : 28, bottom: 0, trailing: compact ? 20 : 28))
                }
                VStack(alignment: .leading, spacing: 0) {
                    if !model.stage.isHero { header.padding(.bottom, 14) }
                    ScrollView {
                        content(compact: compact).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let message = model.message {
                        Text(message).font(.system(size: 12)).foregroundStyle(colors.message)
                            .padding(.top, 6).accessibilityIdentifier("SetupMessage")
                    }
                }
                .padding(EdgeInsets(top: 20, leading: compact ? 20 : 28, bottom: 8, trailing: compact ? 20 : 28))
                footer.padding(EdgeInsets(top: 12, leading: compact ? 20 : 28, bottom: 18, trailing: compact ? 20 : 28))
            }
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
            Text(subtitle).foregroundStyle(colors.faint).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button(model.stage == .ready ? "Close" : "Finish Later") { model.dismiss() }
                .buttonStyle(.plain).font(.system(size: 12.5, weight: .medium)).foregroundStyle(colors.faint)
                .keyboardShortcut(.cancelAction).accessibilityIdentifier("SetupLater")
            if model.isBusy || model.isRefreshing {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(model.isBusy ? "Applying" : "Checking")
            }
            Spacer()
            if model.stage != .welcome {
                Button("Back") { model.backStage() }
                    .buttonStyle(.plain).font(.system(size: 13, weight: .medium)).foregroundStyle(colors.muted)
                    .accessibilityIdentifier("SetupBack")
            }
            if !model.stage.isHero {
                Button("Continue") { model.nextStage() }
                    .buttonStyle(SetupButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("SetupNext")
            }
        }
        .disabled(model.isBusy)
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
        case .access: SetupPermissionPanel(model: model)
        case .ready: SetupReadyHero(model: model)
        }
    }

    private var title: String {
        switch model.stage {
        case .welcome, .ready: ""
        case .appearance: "Theme"
        case .agents: "Your Agents"
        case .access: "macOS Permissions"
        }
    }

    private var subtitle: String {
        switch model.stage {
        case .welcome, .ready: ""
        case .appearance: "Preview changes immediately. Your font settings stay unchanged."
        case .agents: "Discovered agents and their status support. Adding a skill is optional."
        case .access: "Enable the permissions you need for your work."
        }
    }
}
