/*
 * tako — macOS access list (reference A15): notifications, folders, microphone, disk, network, extras
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import SwiftUI

/// The reference's access list: one field-coloured group of 49 pt rows
/// (icon, what it is for, the real status, one action, ?), then the extra
/// accesses behind a disclosure. Statuses are read passively; nothing is
/// requested until the person presses a row's action.
/// Accessibility: `SetupPermissionRow-<kind>`, actions `SetupPermission-<kind>`,
/// `SetupPermissionExtras`, `SetupPermissionScopeNote`.
@MainActor
struct SetupPermissionPanel: View {
    @Environment(\.setupPalette) private var colors
    @ObservedObject var model: SetupModel
    @StateObject private var service = TerminalPermissionService.live()
    @State private var showDiskHelp = false
    @State private var showsExtras = false
    @State private var help: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Checked when opened · permissions apply to Tako, not to other processes or remote hosts")
                .font(.system(size: 11.5)).foregroundStyle(colors.faint)
                .accessibilityIdentifier("SetupPermissionScopeNote")
            group([.notifications, .kind(.protectedFolders), .kind(.microphone), .kind(.fullDiskAccess), .kind(.localNetwork)])
            Button { showsExtras.toggle() } label: {
                HStack(spacing: 8) {
                    Text(showsExtras ? "▾" : "▸").foregroundStyle(colors.muted)
                    Text("Additional Permissions").font(.system(size: 13, weight: .semibold)).foregroundStyle(colors.muted)
                    Text("Screen recording, system audio and automation")
                        .font(.system(size: 12)).foregroundStyle(colors.faint)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6).padding(.horizontal, 2).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("SetupPermissionExtras")
            .accessibilityValue(showsExtras ? "expanded" : "collapsed")
            if showsExtras { group([.kind(.screenCapture), .kind(.systemAudio), .kind(.automation)]) }
            if showDiskHelp { SetupDiskAccessGuide() }
            if let help {
                Text(help).font(.system(size: 12)).foregroundStyle(colors.muted)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("SetupPermissionHelp")
            }
        }
        .disabled(model.isBusy || model.isRefreshing)
        .task { await service.snapshot() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await service.snapshot() }
        }
    }

    /// A notifications row or one of the TerminalPermission kinds.
    enum Row: Hashable {
        case notifications
        case kind(TerminalPermissionKind)
        var id: String { if case .kind(let k) = self { k.id } else { "notifications" } }
    }

    private func group(_ rows: [Row]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element) { index, row in
                if index > 0 { Rectangle().fill(colors.border).frame(height: 1) }
                self.row(row)
            }
        }
        .background(colors.card, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(colors.border))
    }

    private func row(_ row: Row) -> some View {
        let c = SetupAccessCopy.of(row, model: model, service: service)
        return HStack(spacing: 11) {
            Image(systemName: c.symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 28, height: 28).background(c.tint.gradient, in: .rect(cornerRadius: 7))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(c.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(colors.text)
                Text(c.purpose).font(.system(size: 11.5)).foregroundStyle(colors.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !c.status.isEmpty {
                Text(c.status).font(.system(size: 12)).foregroundStyle(c.allowed ? colors.success : colors.faint)
                    .lineLimit(1)
            }
            actionButton(row, c)
            Button { help = help == c.help ? nil : c.help } label: {
                Text("?").font(.system(size: 11, weight: .semibold)).foregroundStyle(colors.faint)
                    .frame(width: 19, height: 19).overlay(Circle().stroke(colors.border))
            }
            .buttonStyle(.plain).help(c.help).accessibilityIdentifier("SetupPermissionHelp-\(row.id)")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(minHeight: 49)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SetupPermissionRow-\(row.id)")
        .accessibilityValue(c.status)
    }

    @ViewBuilder private func actionButton(_ row: Row, _ c: SetupAccessCopy) -> some View {
        let id = row == .notifications ? "SetupEnableNotifications" : "SetupPermission-\(row.id)"
        switch c.style {
        case .primary:
            Button(c.action) { perform(row) }.buttonStyle(SetupSmallButtonStyle(primary: true)).accessibilityIdentifier(id)
        case .alternate:
            Button(c.action) { perform(row) }.buttonStyle(SetupSmallButtonStyle(primary: false)).accessibilityIdentifier(id)
        case .link:
            Button(c.action) { perform(row) }.buttonStyle(.plain)
                .font(.system(size: 12.5, weight: .medium)).foregroundStyle(colors.muted).accessibilityIdentifier(id)
        }
    }

    private func perform(_ row: Row) {
        model.message = nil
        guard case .kind(let kind) = row else {
            switch model.notifications.access {
            case .notAsked: Task { await model.enableNotifications() }
            case .allowed: Task { await model.checkNotificationsAndSendTest() }
            default: model.services.openNotificationSettings()
            }
            return
        }
        if kind != .fullDiskAccess { showDiskHelp = false }
        switch kind {
        case .protectedFolders: Task { await model.checkFolderAccess() }
        case .fullDiskAccess:
            showDiskHelp = true
            if !service.openSettings(kind) { model.message = "Could not open System Settings. Please try again." }
        case .systemAudio, .automation:
            if service.openSettings(kind) {
                model.message = kind == .systemAudio
                    ? "macOS asks for audio recording permission when a tool starts recording."
                    : "macOS asks separately when a script first controls an application."
            } else { model.message = "Could not open System Settings. Please try again." }
        case .microphone, .screenCapture, .localNetwork:
            if SetupAccessCopy.opensSettings(kind, model: model, service: service) {
                if kind == .localNetwork { model.message = "Privacy & Security → Local Network" }
                _ = service.openSettings(kind)
            } else {
                Task { await model.requestPermission(kind, service: service) }
            }
        }
    }
}

/// Small row actions (reference `.pb.sm` / `.pb.sm.alt`): 25 pt, radius 6.
struct SetupSmallButtonStyle: ButtonStyle {
    @Environment(\.setupPalette) private var colors
    let primary: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12).frame(height: 25)
            .foregroundStyle(primary ? colors.primaryText : colors.text)
            .background(primary ? colors.accent.opacity(configuration.isPressed ? 0.7 : 1) : colors.field,
                        in: .rect(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(primary ? Color.clear : colors.border))
    }
}
