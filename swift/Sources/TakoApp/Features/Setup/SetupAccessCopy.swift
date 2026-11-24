/*
 * tako — Wording and action choice for the macOS access rows (reference A15)
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import SwiftUI

/// What one access row says and offers, from the real status only: an
/// unknown status is never shown as allowed, and the action never prompts
/// on its own.
@MainActor
struct SetupAccessCopy {
    enum Style { case primary, alternate, link }

    let title: String
    let purpose: String
    let symbol: String
    let tint: Color
    let status: String
    let action: String
    let style: Style
    let allowed: Bool
    let help: String

    /// Whether the row's action opens System Settings instead of asking.
    static func opensSettings(_ kind: TerminalPermissionKind, model: SetupModel, service: TerminalPermissionService) -> Bool {
        let status = service.permission(for: kind)?.status ?? .unknown
        if [.denied, .restricted, .allowed, .notAllowed].contains(status) { return true }
        return kind == .localNetwork && model.permissionRequests.contains(.localNetwork)
            || kind == .screenCapture && model.permissionRequests.contains(.screenCapture)
    }

    static func of(_ row: SetupPermissionPanel.Row, model: SetupModel, service: TerminalPermissionService) -> SetupAccessCopy {
        guard case .kind(let kind) = row else { return notifications(model) }
        let status = service.permission(for: kind)?.status ?? .unknown
        let settings = opensSettings(kind, model: model, service: service)
        switch kind {
        case .protectedFolders:
            let checked = model.folderAccess
            let readable = checked.filter(\.readable).count
            return .init(title: "Folders", purpose: "Desktop, Documents and Downloads", symbol: "folder.fill", tint: .blue,
                         status: checked.isEmpty ? "Not Checked" : "\(readable) of \(checked.count) accessible",
                         action: checked.isEmpty ? "Check" : "Check Again", style: .alternate,
                         allowed: !checked.isEmpty && readable == checked.count,
                         help: "Tako checks these folders only when you ask. Checking opens each folder, and macOS may request permission.")
        case .microphone:
            return .init(title: "Microphone", purpose: "Voice input for agents", symbol: "mic.fill", tint: .orange,
                         status: statusText(status), action: settings ? "Open Settings" : "Allow",
                         style: settings ? .link : .primary, allowed: status == .allowed,
                         help: "For voice tools running in the terminal. macOS grants this permission to Tako.")
        case .fullDiskAccess:
            return .init(title: "Full Disk Access", purpose: "Protected files, such as ~/Library",
                         symbol: "internaldrive.fill", tint: .gray,
                         status: status == .allowed ? "Allowed" : "Managed in macOS", action: "Open Settings",
                         style: .link, allowed: status == .allowed,
                         help: "Enable in System Settings → Privacy & Security → Full Disk Access.")
        case .localNetwork:
            return .init(title: "Local Network", purpose: "SSH and development servers on your local network", symbol: "network",
                         tint: .blue, status: status == .allowed ? "Allowed" : "Managed in macOS",
                         action: settings ? "Open Settings" : "Allow", style: settings ? .link : .primary,
                         allowed: status == .allowed,
                         help: "macOS asks when a tool first connects to a device on your local network.")
        case .screenCapture:
            return .init(title: "Screen Recording", purpose: "Capture other applications. Tako’s own screenshot command works without this permission.",
                         symbol: "rectangle.dashed.badge.record", tint: .purple,
                         status: status == .allowed ? "Allowed" : "Not allowed or not yet requested",
                         action: settings ? "Open Settings" : "Request Access", style: settings ? .link : .alternate,
                         allowed: status == .allowed, help: "For tools that capture other applications.")
        case .systemAudio:
            return .init(title: "System Audio Recording", purpose: "macOS asks when a tool starts recording",
                         symbol: "speaker.wave.2.fill", tint: .pink, status: "Managed in macOS",
                         action: "Open Settings", style: .link, allowed: false,
                         help: "Playing audio needs no permission. This applies only to recording audio from other applications.")
        case .automation:
            return .init(title: "Automation", purpose: "macOS asks separately for each target application",
                         symbol: "applescript.fill", tint: .gray, status: "Managed in macOS",
                         action: "Open Settings", style: .link, allowed: false,
                         help: "macOS asks when a script first controls another application.")
        }
    }

    private static func notifications(_ model: SetupModel) -> SetupAccessCopy {
        let access = model.notifications.access
        let base = (title: "Notifications", purpose: "When work finishes or an agent needs your attention", symbol: "bell.fill", tint: Color.red,
                    help: "Manage banners, sounds and badges in System Settings. Focus or screen sharing may suppress banners.")
        switch access {
        case .notAsked:
            return .init(title: base.title, purpose: base.purpose, symbol: base.symbol, tint: base.tint, status: "",
                         action: "Enable", style: .primary, allowed: false, help: base.help)
        case .allowed:
            return .init(title: base.title, purpose: base.purpose, symbol: base.symbol, tint: base.tint,
                         status: model.notifications.alerts ? "Enabled" : "Banners Disabled",
                         action: "Check", style: .alternate, allowed: model.notifications.alerts, help: base.help)
        case .denied:
            return .init(title: base.title, purpose: base.purpose, symbol: base.symbol, tint: base.tint, status: "Disabled",
                         action: "Open Settings", style: .link, allowed: false, help: base.help)
        case .unavailable:
            return .init(title: base.title, purpose: base.purpose, symbol: base.symbol, tint: base.tint, status: "Unavailable",
                         action: "Open Settings", style: .link, allowed: false, help: base.help)
        }
    }

    private static func statusText(_ status: TerminalPermissionStatus) -> String {
        switch status {
        case .allowed: "Allowed"
        case .denied, .notAllowed: "Denied"
        case .restricted: "Restricted"
        case .notAsked: "Not Yet Requested"
        case .managedInSettings, .unknown: "Managed in macOS"
        }
    }
}
