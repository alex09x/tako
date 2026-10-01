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
        let alert = NSAlert()
        alert.messageText = "Tako \(tagName) Installed!"
        alert.informativeText = "The update has been installed successfully to \(Bundle.main.bundleURL.path).\n\nYour current terminal windows remain active and will not be interrupted. The updated version will take effect the next time you launch Tako."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Keep Working")
        alert.runModal()
    }
}

// MARK: - Install checks

extension AppUpdater {
    enum UpdateError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case .message(let text) = self { return text }
            return nil
        }
    }

    /// Runs a tool and fails unless it exits 0.
    static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.message("\((tool as NSString).lastPathComponent) failed with status \(process.terminationStatus)")
        }
    }

    /// The Team ID that signed the bundle at `url`, nil for an ad-hoc or
    /// unsigned one.
    static func teamIdentifier(of url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Refuses a downloaded app unless it carries a valid Developer ID
    /// signature from `team` and Gatekeeper accepts it as notarized. A build
    /// with no team of its own (ad-hoc, local) has nothing to compare with,
    /// so it never installs updates by itself.
    static func verify(_ app: URL, signedBy team: String?) throws {
        guard let team, !team.isEmpty else {
            throw UpdateError.message("This copy of Tako is not signed by a developer, so it cannot check an update is genuine. Download the new version from the releases page.")
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError.message("The downloaded Tako.app is not a code bundle.")
        }
        let text = "anchor apple generic and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = \"\(team)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else {
            throw UpdateError.message("Could not build the signature requirement.")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw UpdateError.message("The downloaded Tako.app is not signed by the same developer as this one.")
        }
        do {
            try run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path])
        } catch {
            throw UpdateError.message("Gatekeeper does not accept the downloaded Tako.app as notarized.")
        }
    }
}

