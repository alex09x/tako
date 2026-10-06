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

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.tako-core.terminal",
        category: "AppUpdater"
    )

    private let repoOwner = "alex09x"
    private let repoName = "tako"

    private var isUpdating = false

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
                    Self.logger.info("Found update: \(release.tagName) (current: \(currentVersionString))")
                    await MainActor.run {
                        self.presentUpdateFound(release: release, currentVersion: currentVersionString)
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
        let alert = NSAlert()
        alert.messageText = "You're up to date!"
        let current = version ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.2")
        alert.informativeText = "Tako v\(current) is currently the newest version available."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @MainActor
    private func showErrorAlert(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Update Check Failed"
        alert.informativeText = "Could not check for updates:\n\(error.localizedDescription)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Download & In-Place Update

    private func performDownloadAndInstall(release: GitHubRelease) {
        guard !isUpdating else { return }
        isUpdating = true

        // Find DMG or ZIP asset
        let preferredAsset = release.assets.first(where: { $0.name.hasSuffix(".dmg") })
            ?? release.assets.first(where: { $0.name.hasSuffix(".zip") })

        guard let asset = preferredAsset, let assetUrl = URL(string: asset.browserDownloadUrl) else {
            // If no binary asset found, fall back to opening the release page
            if let webUrl = URL(string: release.htmlUrl) {
                NSWorkspace.shared.open(webUrl)
            }
            isUpdating = false
            return
        }

        Task {
            do {
                let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
                // Removed however this ends; declared first, so it runs after
                // the image is detached below.
                defer { try? FileManager.default.removeItem(at: tempDir) }

                let downloadDestination = tempDir.appendingPathComponent(asset.name)
                Self.logger.info("Downloading update asset from \(assetUrl.absoluteString)...")

                let (tempDownloadedUrl, _) = try await URLSession.shared.download(from: assetUrl)
                try FileManager.default.moveItem(at: tempDownloadedUrl, to: downloadDestination)

                let stagedAppPath: String
                var shouldUnmountDmg = false
                let mountPoint = tempDir.appendingPathComponent("tako_mount").path
                // Detached however this ends, a refused update included.
                defer {
                    if shouldUnmountDmg {
                        try? Self.run("/usr/bin/hdiutil", ["detach", mountPoint, "-force"])
                    }
                }

                if asset.name.hasSuffix(".dmg") {
                    try FileManager.default.createDirectory(atPath: mountPoint, withIntermediateDirectories: true)
                    try Self.run("/usr/bin/hdiutil", ["attach", downloadDestination.path, "-nobrowse", "-readonly", "-mountpoint", mountPoint])
                    stagedAppPath = (mountPoint as NSString).appendingPathComponent("Tako.app")
                    shouldUnmountDmg = true
                } else {
                    try Self.run("/usr/bin/ditto", ["-x", "-k", downloadDestination.path, tempDir.path])
                    stagedAppPath = tempDir.appendingPathComponent("Tako.app").path
                }

                guard FileManager.default.fileExists(atPath: stagedAppPath) else {
                    throw UpdateError.message("Tako.app not found in downloaded archive")
                }

                // Nothing replaces this app unless the same developer signed
                // it and Apple notarized it.
                try Self.verify(URL(fileURLWithPath: stagedAppPath), signedBy: Self.teamIdentifier(of: Bundle.main.bundleURL))

                // The bundle this process runs from, wherever it is. The new
                // one is copied beside it first and swapped in whole, so a
                // failed copy leaves the old app untouched.
                let destinationBundleUrl = Bundle.main.bundleURL
                let incoming = destinationBundleUrl.deletingLastPathComponent()
                    .appendingPathComponent(".Tako-update-\(UUID().uuidString).app")
                do {
                    try Self.run("/usr/bin/ditto", [stagedAppPath, incoming.path])
                    _ = try FileManager.default.replaceItemAt(destinationBundleUrl, withItemAt: incoming)
                } catch {
                    try? FileManager.default.removeItem(at: incoming)
                    throw error
                }


                Self.logger.info("Successfully updated Tako to \(release.tagName) in-place at \(destinationBundleUrl.path)")

                await MainActor.run {
                    self.isUpdating = false
                    self.showUpdateSuccessAlert(tagName: release.tagName)
                }
            } catch {
                Self.logger.error("Failed to install update: \(error.localizedDescription)")
                await MainActor.run {
                    self.isUpdating = false
                    self.showErrorAlert(error)
                }
            }
        }
    }

    @MainActor
    private func showUpdateSuccessAlert(tagName: String) {
        if let window = Self.noticeWindow(key: NSApp.keyWindow, windows: NSApp.windows) {
            let lines = [
                TUIText.Line(runs: [TUIText.Run(text: "Tako \(tagName) is ready to use.", kind: .bold)]),
                TUIText.Line(runs: []),
                TUIText.Line(runs: [TUIText.Run(text: "The update was installed successfully. Would you like to relaunch Tako now to start using the new version, or keep working and relaunch later?", kind: .plain)])
            ]
            Task { @MainActor in
                let answer = await TerminalDialogView.choose(
                    in: window,
                    title: "Tako \(tagName) Installed",
                    lines: lines,
                    choices: [
                        .init(title: "Keep Working", kind: .normal),
                        .init(title: "Relaunch Now", kind: .primary)
                    ],
                    selected: 1,
                    cancelIndex: 0,
                    theme: (NSApp.delegate as? AppDelegate)?.tako.config.theme
                )
                if answer == 1 {
                    Self.relaunchApp()
                }
            }
            return
        }

        let alert = NSAlert()
        alert.messageText = "Tako \(tagName) Installed!"
        alert.informativeText = "The update has been installed successfully.\n\nWould you like to relaunch Tako now to use \(tagName), or keep working and relaunch later?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Relaunch Now")
        alert.addButton(withTitle: "Keep Working")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            Self.relaunchApp()
        }
    }

    /// Terminates the current app process and relaunches the updated application bundle.
    static func relaunchApp() {
        guard NSClassFromString("XCTestCase") == nil else { return }
        let bundleURL = Bundle.main.bundleURL
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.1; done; /usr/bin/open -n \"\(bundleURL.path)\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try? process.run()
        NSApp.terminate(nil)
    }
}

