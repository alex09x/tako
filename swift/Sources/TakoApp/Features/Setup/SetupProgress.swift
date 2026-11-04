/*
 * tako — First-run setup progress
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation

enum SetupStep: String, CaseIterable, Codable, Identifiable {
    case welcome, appearance, commandLine, agents, notifications, ready
    var id: String { rawValue }
    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .appearance: "Appearance"
        case .commandLine: "Command line"
        case .agents: "AI agents"
        case .notifications: "Notifications"
        case .ready: "Ready"
        }
    }
    var symbol: String {
        switch self {
        case .welcome: "hand.wave"
        case .appearance: "paintpalette"
        case .commandLine: "terminal"
        case .agents: "cpu"
        case .notifications: "bell"
        case .ready: "checkmark.circle"
        }
    }
}

struct SetupProgress: Codable, Equatable {
    var version = 1
    var hasPresented = false
    var completed = false
    var step = SetupStep.welcome
    var skipped: Set<SetupStep> = []
}

/// Intent is persisted; installation and permission states are always probed again.
final class SetupProgressStore {
    static let key = "TakoSetupProgressV1"
    static let notificationOptInKey = "TakoSetupNotificationsOptIn"
    let defaults: UserDefaults
    private(set) var canWrite = true

    init(defaults: UserDefaults = .tako) { self.defaults = defaults }

    func load() -> SetupProgress {
        guard let data = defaults.data(forKey: Self.key) else { return SetupProgress() }
        guard let progress = try? JSONDecoder().decode(SetupProgress.self, from: data), progress.version == 1 else {
            // Don't replace an unknown document or keep reopening setup on every launch.
            canWrite = false
            return SetupProgress(hasPresented: true)
        }
        return progress
    }

    func save(_ progress: SetupProgress) {
        guard canWrite, let data = try? JSONEncoder().encode(progress) else { return }
        defaults.set(data, forKey: Self.key)
    }

    static func allowsLaunch(arguments: [String], environment: [String: String], isTesting: Bool) -> Bool {
        !isTesting && !arguments.contains(where: {
            $0.hasPrefix("--selftest") || $0 == "--no-launch-notices"
        }) && environment["TAKO_NO_LAUNCH_NOTICES"] != "1"
    }
}
