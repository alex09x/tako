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

extension AppUpdater {
    enum UpdateError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case .message(let text) = self { return text }
            return nil
        }
    }

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
}
