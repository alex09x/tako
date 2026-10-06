/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Security

extension AppUpdater {
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
