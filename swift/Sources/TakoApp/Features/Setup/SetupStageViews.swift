/*
 * tako — Setup stage bar, welcome hero and ready hero
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import SwiftUI

@MainActor
struct SetupStageBar: View {
    @Environment(\.setupPalette) private var colors
    @ObservedObject var model: SetupModel

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(SetupStage.allCases) { stage in
                Button { model.selectStage(stage) } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Rectangle().fill(fill(stage)).frame(height: 2)
                        Text(stage.title).font(.system(size: 12, weight: stage == model.stage ? .semibold : .regular))
                            .foregroundStyle(stage == model.stage ? colors.text : colors.muted).lineLimit(1)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.isBusy)
                .accessibilityIdentifier("SetupStep-\(stage.canonicalStep.rawValue)")
                .accessibilityAddTraits(stage == model.stage ? .isSelected : [])
            }
        }
    }

    private func fill(_ stage: SetupStage) -> Color {
        if stage == model.stage { return colors.accent }
        return stage.rawValue < model.stage.rawValue ? colors.accent.opacity(0.45) : colors.border
    }
}

@MainActor
struct SetupWelcomeHero: View {
    @Environment(\.setupPalette) private var colors
    @ObservedObject var model: SetupModel
    var compact: Bool

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        HStack(alignment: .center, spacing: 28) {
            VStack(alignment: .leading, spacing: 14) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().frame(width: 72, height: 72).accessibilityHidden(true)
                Text("Tako").font(.system(size: 30, weight: .bold))
                Text("A terminal that sees what your agents are doing: who is working, who is waiting for you, and what failed.")
                    .font(.system(size: 15)).foregroundStyle(colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Get started") { model.nextStage() }
                    .buttonStyle(SetupButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("SetupNext").padding(.top, 6)
                if !Self.appVersion.isEmpty {
                    Text("Version \(Self.appVersion)").font(.system(size: 11)).foregroundStyle(colors.muted)
                        .accessibilityIdentifier("SetupVersion")
                }
            }
            if !compact { sample.frame(width: 270) }
        }
        .padding(.top, 36)
    }

    /// Illustrative transcript of an agent waiting for approval; not live session data.
    private var sample: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "circle").foregroundStyle(colors.accent)
                Text("agent · tako").foregroundStyle(colors.muted)
            }
            Divider().overlay(colors.border)
            Text("~/tako main ❯ mitts test").foregroundStyle(colors.text)
            Text("● Reading src/auth/jwt.rs").foregroundStyle(colors.muted)
            Text("? Allow: mitts test -p auth").foregroundStyle(colors.accent)
            Text("  ❯ Yes   No").foregroundStyle(colors.text)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(14)
        .background(colors.card, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(colors.border))
        .accessibilityHidden(true)
    }
}

@MainActor
struct SetupReadyHero: View {
    @Environment(\.setupPalette) private var colors
    @ObservedObject var model: SetupModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark").font(.system(size: 26, weight: .semibold))
                .foregroundStyle(colors.success).frame(width: 64, height: 64)
                .background(colors.success.opacity(0.14), in: .circle)
                .overlay(Circle().stroke(colors.success.opacity(0.5)))
            Text("Tako is ready").font(.system(size: 26, weight: .bold)).accessibilityIdentifier("SetupStepTitle")
            Text(summary).foregroundStyle(colors.text).multilineTextAlignment(.center)
            Text("Other access can be granted when needed, in Settings › Access.")
                .font(.system(size: 12)).foregroundStyle(colors.muted).multilineTextAlignment(.center)
            Button("Start using Tako") { model.finishSetup() }
                .buttonStyle(SetupButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("SetupFinish").padding(.top, 8)
        }
        .frame(maxWidth: .infinity).padding(.top, 40)
    }

    private var summary: String {
        let connected = model.agents.filter(\.isReady).count
        let agents = connected > 0 ? "\(connected) agent skill\(connected == 1 ? "" : "s") added"
            : "no skill added — you can do it later"
        return "Theme \(model.selectedTheme) · \(agents)."
    }
}
