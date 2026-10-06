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
import Foundation
import OSLog

extension AppUpdater {
    // MARK: - Download & In-Place Update

    func performDownloadAndInstall(release: GitHubRelease) {
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
    func showUpdateSuccessAlert(tagName: String) {
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
