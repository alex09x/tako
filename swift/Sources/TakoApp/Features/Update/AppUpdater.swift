import AppKit
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

    // MARK: - Models

    struct GitHubRelease: Codable, Sendable {
        let tagName: String
        let name: String?
        let body: String?
        let htmlUrl: String
        let assets: [GitHubAsset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case body
            case htmlUrl = "html_url"
            case assets
        }
    }

    struct GitHubAsset: Codable, Sendable {
        let name: String
        let browserDownloadUrl: String
        let size: Int

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadUrl = "browser_download_url"
            case size
        }
    }

    struct SemanticVersion: Comparable, Equatable, Sendable {
        let major: Int
        let minor: Int
        let patch: Int

        init(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "vV \t\n\r"))
            let components = trimmed.split(separator: ".").compactMap { Int($0) }
            self.major = components.indices.contains(0) ? components[0] : 0
            self.minor = components.indices.contains(1) ? components[1] : 0
            self.patch = components.indices.contains(2) ? components[2] : 0
        }

        static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
            if lhs.major != rhs.major { return lhs.major < rhs.major }
            if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
            return lhs.patch < rhs.patch
        }
    }

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
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            return nil
        }

        let decoder = JSONDecoder()
        return try decoder.decode(GitHubRelease.self, from: data)
    }

    // MARK: - UI Alerts

    @MainActor
    private func presentUpdateFound(release: GitHubRelease, currentVersion: String) {
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

                let downloadDestination = tempDir.appendingPathComponent(asset.name)
                Self.logger.info("Downloading update asset from \(assetUrl.absoluteString)...")

                let (tempDownloadedUrl, _) = try await URLSession.shared.download(from: assetUrl)
                try FileManager.default.moveItem(at: tempDownloadedUrl, to: downloadDestination)

                let stagedAppPath: String
                var shouldUnmountDmg = false
                let mountPoint = tempDir.appendingPathComponent("tako_mount").path

                if asset.name.hasSuffix(".dmg") {
                    // Mount disk image
                    try FileManager.default.createDirectory(atPath: mountPoint, withIntermediateDirectories: true)
                    let mountProcess = Process()
                    mountProcess.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                    mountProcess.arguments = ["attach", downloadDestination.path, "-nobrowse", "-readonly", "-mountpoint", mountPoint]
                    try mountProcess.run()
                    mountProcess.waitUntilExit()

                    stagedAppPath = (mountPoint as NSString).appendingPathComponent("Tako.app")
                    shouldUnmountDmg = true
                } else {
                    // Unzip archive
                    let unzipProcess = Process()
                    unzipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                    unzipProcess.arguments = ["-x", "-k", downloadDestination.path, tempDir.path]
                    try unzipProcess.run()
                    unzipProcess.waitUntilExit()

                    stagedAppPath = tempDir.appendingPathComponent("Tako.app").path
                }

                guard FileManager.default.fileExists(atPath: stagedAppPath) else {
                    throw NSError(domain: "TakoUpdater", code: 1, userInfo: [NSLocalizedDescriptionKey: "Tako.app not found in downloaded archive"])
                }

                // Locate destination bundle
                let destinationBundleUrl: URL
                if Bundle.main.bundleURL.path.hasPrefix("/Applications") {
                    destinationBundleUrl = URL(fileURLWithPath: "/Applications/Tako.app")
                } else {
                    destinationBundleUrl = Bundle.main.bundleURL
                }

                // Replace the bundle using ditto to preserve permissions and signatures
                let replaceProcess = Process()
                replaceProcess.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
                replaceProcess.arguments = [stagedAppPath, destinationBundleUrl.path]
                try replaceProcess.run()
                replaceProcess.waitUntilExit()

                // Clear quarantine attributes
                let xattrProcess = Process()
                xattrProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
                xattrProcess.arguments = ["-dr", "com.apple.quarantine", destinationBundleUrl.path]
                try? xattrProcess.run()
                xattrProcess.waitUntilExit()

                if shouldUnmountDmg {
                    let detachProcess = Process()
                    detachProcess.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
                    detachProcess.arguments = ["detach", mountPoint, "-force"]
                    try? detachProcess.run()
                    detachProcess.waitUntilExit()
                }

                // Cleanup temp dir
                try? FileManager.default.removeItem(at: tempDir)

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
        let alert = NSAlert()
        alert.messageText = "Tako \(tagName) Installed!"
        alert.informativeText = "The update has been installed successfully to /Applications/Tako.app.\n\nYour current terminal windows remain active and will not be interrupted. The updated version will take effect the next time you launch Tako."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Keep Working")
        alert.runModal()
    }
}
