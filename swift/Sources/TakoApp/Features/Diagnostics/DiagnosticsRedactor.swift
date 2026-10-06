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

public enum DiagnosticsRedactor {
    /// Replaces occurrences of the user's home directory with `~`.
    public static func reducePath(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            let suffix = path.dropFirst(home.count)
            return "~" + suffix
        }
        // General fallback for /Users/<username> paths
        if let userRegex = try? NSRegularExpression(pattern: "^/Users/[^/]+", options: []) {
            let range = NSRange(path.startIndex..<path.endIndex, in: path)
            return userRegex.stringByReplacingMatches(in: path, options: [], range: range, withTemplate: "~")
        }
        return path
    }

    /// Redacts known secret patterns, tokens, private keys, and credential lines.
    public static func redactSecrets(in text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text

        // 1. Redact home directories in text
        result = reducePathInText(result)

        // 2. Private keys (PEM / OpenSSH / RSA / EC / DSA / PKCS8)
        if let pemRegex = try? NSRegularExpression(pattern: "-----BEGIN [A-Z0-9_ -]*PRIVATE KEY-----[\\s\\S]*?-----END [A-Z0-9_ -]*PRIVATE KEY-----", options: []) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = pemRegex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "[REDACTED_PRIVATE_KEY]")
        }

        // 3. Known API token formats (GitHub, GitLab, Slack, AWS)
        let tokenPatterns = [
            #"(?:ghp|gho|ghu|ghs|ghr)_[a-zA-Z0-9]{20,}"#,            // GitHub
            #"glpat-[a-zA-Z0-9\-_]{20,}"#,                           // GitLab
            #"xox[baprs]-[a-zA-Z0-9\-]{10,}"#,                      // Slack
            #"AKIA[0-9A-Z]{16}"#,                                    // AWS Access Key ID
        ]

        for pat in tokenPatterns {
            if let regex = try? NSRegularExpression(pattern: pat, options: []) {
                let range = NSRange(result.startIndex..<result.endIndex, in: result)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "[REDACTED]")
            }
        }

        // Key-value credentials (e.g. api_key: xyz, password = abc)
        let kvPattern = #"(?i)((?:api[_-]?key|secret|token|password|auth|bearer)\s*[:=]\s*['"]?)[a-zA-Z0-9\-_.~+/=]{8,}['"]?"#
        if let regex = try? NSRegularExpression(pattern: kvPattern, options: []) {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "$1[REDACTED]")
        }

        // 4. Pass through SessionSnapshotRedactor for any user-configured regexes
        result = SessionSnapshotRedactor.shared.redact(result)

        return result
    }

    private static func reducePathInText(_ text: String) -> String {
        let home = NSHomeDirectory()
        guard !home.isEmpty else { return text }
        return text.replacingOccurrences(of: home, with: "~")
    }
}
