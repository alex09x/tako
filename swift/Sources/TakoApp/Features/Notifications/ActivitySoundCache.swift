/*
 * tako — The chosen system sound, where macOS notifications can find it
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import CryptoKit
import Foundation
import Security

/// UNNotificationSound(named:) finds a sound only in the app bundle or in
/// Library/Sounds of the app's (group) container -- not in
/// /System/Library/Sounds. Tako ships no Apple sounds; when a notification
/// needs one, the installed system file is copied, unchanged, into
/// Library/Sounds of Tako's own app group (`<team>.com.tako-core.terminal.sounds`),
/// as `tako-<Name>.aiff`.
///
/// Only a process that is signed by that team and carries that group in its
/// entitlements touches the container; any other build (ad-hoc, unsigned,
/// another team) gets a failure and its notifications keep macOS's own sound.
/// Only `tako-*.aiff` files are ever written there.
/// Self-contained (Foundation, Security, CryptoKit): the signed probe that
/// proves the placement compiles this same file.
enum ActivitySoundCache {
    static let team = "284V2M3LN9"
    static let group = "\(team).com.tako-core.terminal.sounds"
    static let systemSounds = URL(fileURLWithPath: "/System/Library/Sounds", isDirectory: true)
    static let filePrefix = "tako-"
    static let maxBytes = 4 << 20

    enum Failure: Error, Equatable {
        case unknownSound, notEntitled, otherTeam, noContainer, badSource, unsafeTarget, io
    }

    struct Placed: Equatable {
        let fileName: String
        let url: URL
        let sha256: String
    }

    /// How this process may reach a group: its entitlement, its team, its container.
    struct Environment {
        var groups: () -> [String]
        var teamID: () -> String?
        var container: (String) -> URL?

        static let current = Environment(groups: ownGroups, teamID: ownTeam,
                                         container: { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) })
    }

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Copies `name` (one of `known`) into the group's Library/Sounds, or says why not.
    static func place(_ name: String, known: [String], group: String = group, env: Environment = .current,
                      source: URL = systemSounds) -> Result<Placed, Failure> {
        guard known.contains(name), name.range(of: "^[A-Za-z]+$", options: .regularExpression) != nil else { return .failure(.unknownSound) }
        guard env.groups().contains(group) else { return .failure(.notEntitled) }
        guard let team = env.teamID(), group.hasPrefix(team + ".") else { return .failure(.otherTeam) }
        guard let container = env.container(group) else { return .failure(.noContainer) }

        let from = source.appendingPathComponent("\(name).aiff")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: from.path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let size = attrs[.size] as? Int, size > 12, size <= maxBytes,
              let data = try? Data(contentsOf: from), data.count == size,
              data.prefix(4) == Data("FORM".utf8), [Data("AIFF".utf8), Data("AIFC".utf8)].contains(data.subdata(in: 8..<12))
        else { return .failure(.badSource) }
        let digest = sha256(data)

        // Library, then Sounds, one at a time: each must be a real folder (not a
        // link, not anything else) before anything is made inside it, so nothing
        // is ever created or written outside the container.
        guard let library = ownedFolder(container.appendingPathComponent("Library", isDirectory: true)),
              let sounds = ownedFolder(library.appendingPathComponent("Sounds", isDirectory: true))
        else { return .failure(.unsafeTarget) }
        let fileName = "\(filePrefix)\(name).aiff"
        let to = sounds.appendingPathComponent(fileName)
        do {
            if let existing = try? FileManager.default.attributesOfItem(atPath: to.path) {
                // Ours to replace only as a plain file; a link or anything else stays as it is.
                guard existing[.type] as? FileAttributeType == .typeRegular else { return .failure(.unsafeTarget) }
                if let old = try? Data(contentsOf: to), sha256(old) == digest {
                    return .success(Placed(fileName: fileName, url: to, sha256: digest))
                }
            }
            try data.write(to: to, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: to.path)
        } catch {
            return .failure(.io)
        }
        guard let written = try? Data(contentsOf: to), sha256(written) == digest else { return .failure(.io) }
        return .success(Placed(fileName: fileName, url: to, sha256: digest))
    }

    /// `url` as a plain folder: made (0700) if absent, accepted if it is a
    /// directory itself; nil for a link, any other type, or a type that cannot
    /// be read. Never follows a link.
    static func ownedFolder(_ url: URL) -> URL? {
        func type() -> FileAttributeType?? {
            do { return try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { return .some(nil) }
            catch { return nil }   // unknown
        }
        switch type() {
        case .some(.some(.typeDirectory)): return url
        case .some(.none):
            do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
            catch { return nil }
            return type() == .some(.some(.typeDirectory)) ? url : nil
        default: return nil
        }
    }

    // MARK: - This process's signature

    static func ownGroups() -> [String] {
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "com.apple.security.application-groups" as CFString, nil)
        else { return [] }
        return value as? [String] ?? []
    }

    static func ownTeam() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any]
        else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
