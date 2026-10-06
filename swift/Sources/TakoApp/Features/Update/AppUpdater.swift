/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Security
import Foundation
import UserNotifications
import OSLog

/// Lightweight in-app updater for Tako that checks GitHub Releases,
/// downloads new versions, and applies updates in-place without disrupting
/// existing running terminal sessions.
final class AppUpdater: @unchecked Sendable {
    static let shared = AppUpdater()

    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.tako-core.terminal",
        category: "AppUpdater"
    )

    private let repoOwner = "alex09x"
    private let repoName = "tako"

    var isUpdating = false
    private(set) var notifiedVersionsInSession: Set<String> = []
    private var periodicTimer: Timer?

    /// Flag set when the user confirms an in-place update relaunch.
    /// Bypasses interactive quit confirmation so AppKit terminates immediately.
    @MainActor static var isRelaunching: Bool = false

    private init() {}

    // MARK: - Public API

    /// Checks for updates. When `silent` is true, errors and "up to date" dialogs
    /// are suppressed (suitable for automatic background checks at startup).
    /// Whether a launch checks for updates on its own. Not when the user set
    /// `auto-update = off`; not during a self-test, where a dialog would take
    /// the keystrokes the test types; and not for an unversioned local build
    /// (0.0.0), which every release is newer than, so it asked to be
    /// replaced on every start.
    static func checksAtLaunch(arguments: [String], version: String?, enabled: Bool) -> Bool {
        guard enabled else { return false }
        if arguments.contains(where: { $0.hasPrefix("--selftest") }) { return false }
        guard let version, !version.isEmpty, version != "0.0.0" else { return false }
        return true
    }


    /// Determines whether a found update should be presented to the user.
    /// In silent background mode, updates already presented in this session
    /// are suppressed so the user is not repeatedly prompted every hour.
    /// Non-silent checks (e.g. manual menu invocation) always present.
    @MainActor
    func shouldPresentUpdate(version: String, silent: Bool) -> Bool {
        if silent && notifiedVersionsInSession.contains(version) {
            return false
        }
        notifiedVersionsInSession.insert(version)
        return true
    }

    /// Resets the session-notified versions (primarily for testing or simulated app restart).
    @MainActor
    func resetSessionNotifiedVersions() {
        notifiedVersionsInSession.removeAll()
    }

    /// Starts periodic background update checks at the given interval (defaults to 1 hour / 3600s).
    @MainActor
    func startPeriodicChecks(interval: TimeInterval = 3600) {
        if let existing = periodicTimer, existing.isValid, existing.timeInterval == interval {
            return
        }
        stopPeriodicChecks()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.checkForUpdates(silent: true)
        }
        timer.tolerance = min(300, max(1, interval * 0.1))
        RunLoop.main.add(timer, forMode: .common)
        self.periodicTimer = timer
        Self.logger.info("Started periodic update checks every \(Int(interval))s")
    }

    /// Stops periodic background update checks.
    @MainActor
    func stopPeriodicChecks() {
        if periodicTimer != nil {
            periodicTimer?.invalidate()
            periodicTimer = nil
            Self.logger.info("Stopped periodic update checks")
        }
    }

    /// Whether periodic checks are currently scheduled.
    @MainActor
    var isPeriodicCheckActive: Bool {
        periodicTimer?.isValid == true
    }

    func checkForUpdates(silent: Bool = false) {
        guard !isUpdating else { return }

        Task {
            do {
                guard let release = try await fetchLatestRelease() else {
                    if !silent {
                        await MainActor.run {
                            self.showUpToDateAlert()
                        }
                    }
                    return
                }

                let currentVersionString = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
                let currentVersion = SemanticVersion(currentVersionString)
                let remoteVersion = SemanticVersion(release.tagName)

                if remoteVersion > currentVersion {
                    let shouldPresent = await MainActor.run {
                        self.shouldPresentUpdate(version: release.tagName, silent: silent)
                    }
                    if shouldPresent {
                        Self.logger.info("Found update: \(release.tagName) (current: \(currentVersionString))")
                        await MainActor.run {
                            self.presentUpdateFound(release: release, currentVersion: currentVersionString)
                        }
                    } else {
                        Self.logger.info("Update \(release.tagName) already presented in this session, suppressing repeated background prompt")
                    }
                } else if !silent {
                    await MainActor.run {
                        self.showUpToDateAlert(version: currentVersionString)
                    }
                }
            } catch {
                Self.logger.error("Failed to check for updates: \(error.localizedDescription)")
                if !silent {
                    await MainActor.run {
                        self.showErrorAlert(error)
                    }
                }
            }
        }
    }

    // MARK: - Network

    private func fetchLatestRelease() async throws -> GitHubRelease? {
        guard let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.setValue("Tako-Terminal", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        return try Self.release(from: data, status: (response as? HTTPURLResponse)?.statusCode)
    }

    /// The latest release in a GitHub API response. Only a 404 means there
    /// is none; any other failure -- rate limiting, a server error -- is an
    /// error, not "you're up to date".
    static func release(from data: Data, status: Int?) throws -> GitHubRelease? {
        switch status {
        case 200:
            return try JSONDecoder().decode(GitHubRelease.self, from: data)
        case 404:
            return nil
        default:
            throw UpdateError.message("GitHub answered the update check with HTTP \(status.map(String.init) ?? "nothing")")
        }
    }

    // MARK: - UI Alerts

    /// The terminal window an update notice is drawn in: the key window if
    /// it is a terminal's, else the first visible terminal window -- never
    /// Settings or another window that is not a terminal's.
    @MainActor
    static func noticeWindow(key: NSWindow?, windows: [NSWindow]) -> NSWindow? {
        func isTerminal(_ window: NSWindow) -> Bool {
            window.windowController is BaseTerminalController && window.isVisible
        }
        if let key, isTerminal(key) { return key }
        return windows.first(where: isTerminal)
    }

    @MainActor
    private func presentUpdateFound(release: GitHubRelease, currentVersion: String) {
        // In the terminal window, drawn as the terminal UI is; the alert
        // below only when no terminal window is open to draw in.
        if let window = Self.noticeWindow(key: NSApp.keyWindow, windows: NSApp.windows) {
            var lines = [TUIText.Line(runs: [TUIText.Run(text: "v\(currentVersion)", kind: .muted),
                                             TUIText.Run(text: "  →  ", kind: .muted),
                                             TUIText.Run(text: release.tagName, kind: .bold)]),
                         TUIText.Line(runs: [])]
            // All of it: the card scrolls.
            lines += TUIText.markdown(release.body ?? "", width: 64, maxLines: 400)
            Task { @MainActor in
                let answer = await TerminalDialogView.choose(
                    in: window, title: "Tako \(release.tagName) is available", lines: lines,
                    choices: [.init(title: "Later", kind: .normal),
                              .init(title: "View on GitHub", kind: .normal),
                              .init(title: "Download & Install", kind: .primary)],
                    selected: 2, cancelIndex: 0,
                    theme: (NSApp.delegate as? AppDelegate)?.tako.config.theme)
                switch answer {
                case 2: self.performDownloadAndInstall(release: release)
                case 1: if let url = URL(string: release.htmlUrl) { NSWorkspace.shared.open(url) }
                default: break
                }
            }
            return
        }
        let alert = NSAlert()
        alert.messageText = "Tako \(release.tagName) is Available!"

        var details = "A newer version of Tako is ready to install.\n\n"
        details += "• Current version: v\(currentVersion)\n"
        details += "• New version: \(release.tagName)\n"

        if let body = release.body, !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let truncated = body.prefix(400)
            details += "\nRelease notes:\n\(truncated)\(body.count > 400 ? "..." : "")\n"
        }

        alert.informativeText = details
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download & Install")
        alert.addButton(withTitle: "View on GitHub")
        alert.addButton(withTitle: "Later")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            performDownloadAndInstall(release: release)
        case .alertSecondButtonReturn:
            if let url = URL(string: release.htmlUrl) {
                NSWorkspace.shared.open(url)
            }
        default:
            break
        }
    }

    @MainActor
    private func showUpToDateAlert(version: String? = nil) {
        let current = version ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.8")
        if let window = Self.noticeWindow(key: NSApp.keyWindow, windows: NSApp.windows) {
            let lines = [
                TUIText.Line(runs: [
                    TUIText.Run(text: "Tako v\(current) is currently the newest version available.", kind: .plain)
                ]),
                TUIText.Line(runs: []),
                TUIText.Line(runs: [
                    TUIText.Run(text: "You are running the latest release.", kind: .muted)
                ])
            ]
            Task { @MainActor in
                _ = await TerminalDialogView.choose(
                    in: window,
                    title: "You're Up to Date",
                    lines: lines,
                    choices: [.init(title: "OK", kind: .primary)],
                    selected: 0,
                    cancelIndex: 0,
                    theme: (NSApp.delegate as? AppDelegate)?.tako.config.theme
                )
            }
            return
        }

        let alert = NSAlert()
        alert.messageText = "You're up to date!"
        alert.informativeText = "Tako v\(current) is currently the newest version available."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @MainActor
    func showErrorAlert(_ error: Error) {
        if let window = Self.noticeWindow(key: NSApp.keyWindow, windows: NSApp.windows) {
            let lines = [
                TUIText.Line(runs: [
                    TUIText.Run(text: "Could not check for updates:", kind: .bold)
                ]),
                TUIText.Line(runs: []),
                TUIText.Line(runs: [
                    TUIText.Run(text: error.localizedDescription, kind: .plain)
                ])
            ]
            Task { @MainActor in
                _ = await TerminalDialogView.choose(
                    in: window,
                    title: "Update Check Failed",
                    lines: lines,
                    choices: [.init(title: "OK", kind: .primary)],
                    selected: 0,
                    cancelIndex: 0,
                    theme: (NSApp.delegate as? AppDelegate)?.tako.config.theme
                )
            }
            return
        }

        let alert = NSAlert()
        alert.messageText = "Update Check Failed"
        alert.informativeText = "Could not check for updates:\n\(error.localizedDescription)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

