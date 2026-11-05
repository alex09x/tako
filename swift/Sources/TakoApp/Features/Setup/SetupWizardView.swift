/*
 * tako — Branded first-run setup wizard
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
    private var colors: SetupPalette { SetupPalette(theme: model.previewTheme) }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(colors.border).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                header.padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 20)
                ScrollView {
                    content.padding(.horizontal, 28).padding(.bottom, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let message = model.message {
                    Text(message).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(colors.message)
                        .padding(.horizontal, 28).padding(.vertical, 10)
                        .accessibilityIdentifier("SetupMessage")
                }
                footer
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(colors.text)
        .tint(colors.accent)
        .background(colors.background)
        .environment(\.setupPalette, colors)
        .preferredColorScheme(colors.isDark ? .dark : .light)
        .frame(minWidth: 760, minHeight: 560)
        .task { await model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refresh() }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 36, height: 36)
                Text("tako").font(.system(size: 22, weight: .semibold, design: .monospaced))
            }.padding(.bottom, 12)
            VStack(spacing: 6) {
                ForEach(SetupStep.allCases) { step in
                    Button { model.select(step) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: step.symbol).frame(width: 16)
                            Text(step.title).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(step == model.step ? colors.text : colors.muted)
                        .padding(.horizontal, 11).padding(.vertical, 11)
                        .background(step == model.step ? colors.accent.opacity(0.12) : Color.clear,
                                    in: .rect(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("SetupStep-\(step.rawValue)")
                    .accessibilityAddTraits(step == model.step ? .isSelected : [])
                }
            }
            Spacer()
            Text("Make it yours.\nKeep your flow.")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(colors.muted)
            Button("Finish later") { model.dismiss() }
                .buttonStyle(.plain).foregroundStyle(colors.muted)
                .disabled(model.isBusy).accessibilityIdentifier("SetupLater")
                .keyboardShortcut(.cancelAction)
        }.padding(20).frame(width: 208)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("SET UP TAKO").font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.5).foregroundStyle(colors.muted)
                Spacer()
                Text("\(model.stepIndex + 1) / \(SetupStep.allCases.count)")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(colors.muted)
            }
            Text(title).font(.system(size: 25, weight: .semibold, design: .monospaced))
                .accessibilityIdentifier("SetupStepTitle")
            Text(subtitle).foregroundStyle(colors.muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if model.step != .welcome {
                Button("Back") { model.back() }.buttonStyle(SetupButtonStyle())
                    .accessibilityIdentifier("SetupBack")
            }
            if model.isBusy || model.isRefreshing {
                ProgressView().controlSize(.small)
                    .accessibilityLabel(model.isBusy ? "Applying setup" : "Checking current setup")
            }
            Spacer()
            if ![.welcome, .ready].contains(model.step) {
                Button("Skip for now") { model.next(skipping: true) }
                    .buttonStyle(.plain).foregroundStyle(colors.muted)
                    .accessibilityIdentifier("SetupSkip")
            }
            Button(model.step == .ready ? "Start using Tako" : "Continue") { model.next() }
                .buttonStyle(SetupButtonStyle(primary: true))
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("SetupNext")
        }
        .disabled(model.isBusy)
        .padding(.horizontal, 28).padding(.vertical, 18)
        .overlay(alignment: .top) { Rectangle().fill(colors.border).frame(height: 1) }
    }

    @ViewBuilder private var content: some View {
        switch model.step {
        case .welcome: SetupWelcomeStep()
        case .appearance: SetupAppearanceStep(model: model)
        case .commandLine: SetupCommandLineStep(model: model)
        case .agents: SetupAgentsStep(model: model)
        case .notifications: SetupNotificationsStep(model: model)
        case .ready: SetupReadyStep(model: model)
        }
    }

    private var title: String {
        switch model.step {
        case .welcome: "Your terminal. Your way."
        case .appearance: "Find your colors."
        case .commandLine: "Tako, from the command line."
        case .agents: "Bring your agents along."
        case .notifications: "Know when you're needed."
        case .ready: "You're ready to go."
        }
    }
    private var subtitle: String {
        switch model.step {
        case .welcome: "Choose a look and connect the tools you use. Every step is optional, and you can return from the Tako menu."
        case .appearance: "Choose your colors. The entire window updates immediately; fonts stay as you configured them."
        case .commandLine: "Open tabs, split panes and control Tako from scripts or another terminal."
        case .agents: "Choose which installed agents can use Tako's commands and report their activity."
        case .notifications: "Get a macOS alert when work finishes or an agent needs your attention."
        case .ready: "Your terminal is ready. Optional integrations can be changed whenever you need them."
        }
    }
}
