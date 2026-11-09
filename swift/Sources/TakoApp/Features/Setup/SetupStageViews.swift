/*
 * tako — First-run stage bar, welcome and ready cards (reference A14, A16)
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import SwiftUI

/// Five columns, each a 2 pt bar over an 11 pt label: the current stage in
/// accent, passed ones dimmed accent, coming ones the line colour.
@MainActor
struct SetupStageBar: View {
    @Environment(\.setupPalette) private var colors
    @ObservedObject var model: SetupModel

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(SetupStage.allCases) { stage in
                Button { model.selectStage(stage) } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Rectangle().fill(fill(stage)).frame(height: 2)
                        Text(stage.title).font(.system(size: 11, weight: .medium))
                            .foregroundStyle(label(stage)).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
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

    private func label(_ stage: SetupStage) -> Color {
        if stage == model.stage { return colors.text }
        return stage.rawValue < model.stage.rawValue ? colors.muted : colors.faint
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
        HStack(alignment: .center, spacing: 27) {
            VStack(alignment: .leading, spacing: 0) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().frame(width: 73, height: 73).accessibilityHidden(true)
                Text("Tako").font(.system(size: 30, weight: .bold)).foregroundStyle(colors.text).padding(.top, 13)
                Text("A terminal that shows which agents are working, waiting for you or need attention.")
                    .font(.system(size: 15)).foregroundStyle(colors.muted).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 5)
                Button("Get Started") { model.nextStage() }
                    .buttonStyle(SetupButtonStyle(primary: true, big: true)).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("SetupNext").padding(.top, 21)
                    .help(Self.appVersion.isEmpty ? "" : "Tako \(Self.appVersion)")
            }
            .frame(width: compact ? nil : 266, alignment: .leading)
            if !compact { sample.frame(width: 306) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 17)
    }

    /// An illustration of an agent asking for approval — labelled as a
    /// sample, never live session data.
    private var sample: some View {
        let term = Color(red: 0x14 / 255, green: 0x10 / 255, blue: 0x0e / 255)
        let fg = Color(red: 0xed / 255, green: 0xe6 / 255, blue: 0xdf / 255)
        let claw = Color(nsColor: Tako.LivingTokens.claw)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().strokeBorder(claw, lineWidth: 1.5).frame(width: 9, height: 9)
                Text("claude · tako").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(red: 0x8b / 255, green: 0x86 / 255, blue: 0x81 / 255))
            }
            .frame(height: 28)
            Group {
                (Text("~/tako").foregroundColor(Color(red: 0x8a / 255, green: 0xbe / 255, blue: 0xb7 / 255)).fontWeight(.medium)
                    + Text(" main ❯ ").foregroundColor(fg.opacity(0.6)) + Text("claude \"fix auth tests\"").foregroundColor(fg))
                Text("● Reading src/auth/jwt.rs").foregroundColor(fg.opacity(0.6))
                (Text("● Edit src/auth/jwt.rs ").foregroundColor(fg.opacity(0.6))
                    + Text("+12 ").foregroundColor(Color(nsColor: Tako.LivingTokens.ok)) + Text("−3").foregroundColor(Color(nsColor: Tako.LivingTokens.error)))
                Text("? Allow: mitts test -p auth").foregroundColor(claw)
                (Text("  ❯ Yes   ").foregroundColor(claw) + Text("No").foregroundColor(fg))
            }
            .font(.system(size: 12, design: .monospaced)).lineSpacing(3)
        }
        .padding(EdgeInsets(top: 0, leading: 12, bottom: 14, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(term, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(colors.border))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Example: an agent requests approval")
        .accessibilityIdentifier("SetupSample")
    }
}

@MainActor
struct SetupReadyHero: View {
    @Environment(\.setupPalette) private var colors
    @ObservedObject var model: SetupModel

    var body: some View {
        VStack(spacing: 0) {
            Image(systemName: "checkmark").font(.system(size: 22, weight: .semibold))
                .foregroundStyle(colors.success).frame(width: 46, height: 46)
                .background(colors.success.opacity(0.14), in: .circle)
                .overlay(Circle().stroke(colors.success.opacity(0.5), lineWidth: 1.5))
            Text("Tako Is Ready").font(.system(size: 26, weight: .bold)).padding(.top, 16)
                .accessibilityIdentifier("SetupStepTitle")
            Text(summary).font(.system(size: 13)).foregroundStyle(colors.text).multilineTextAlignment(.center)
                .padding(.top, 10)
            Text("You can enable more permissions later in Settings → Notifications & Permissions.")
                .font(.system(size: 12)).foregroundStyle(colors.muted).multilineTextAlignment(.center).padding(.top, 6)
            Button("Start Working") { model.finishSetup() }
                .buttonStyle(SetupButtonStyle(primary: true, big: true)).keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("SetupFinish").padding(.top, 20)
        }
        .frame(maxWidth: .infinity).padding(.top, 34)
    }

    private var summary: String {
        let connected = model.agents.filter(\.isReady).count
        let agents = connected == 0 ? "No skills added — you can add them later"
            : connected == 1 ? "Skill added to one agent" : "Skills added to \(connected) agents"
        return "Theme: \(model.selectedTheme) · \(agents)."
    }
}
