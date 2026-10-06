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

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

/// Which Option key, if any, `TakoTerminalNSView.keyDown` treats as Alt
/// instead of a character composer. Backs the `macos-option-as-alt` config
/// key; string cases match its accepted values.
public enum OptionAsAlt: String, Sendable {
    case off = "false"
    case on = "true"
    case left
    case right

    /// Whether this mode applies to the Option key held down in `event`.
    func appliesTo(_ event: NSEvent) -> Bool {
        switch self {
        case .off: return false
        case .on: return true
        case .left: return event.modifierFlags.rawValue & 0x20 != 0
        case .right: return event.modifierFlags.rawValue & 0x40 != 0
        }
    }
}

/// Whether a Shift-held click reaches a program that reports the mouse, or
/// stays the terminal's, to select text with. Backs `mouse-shift-capture`;
/// the raw values are its config values.
public enum MouseShiftCapture: String, Sendable {
    /// Shift selects, unless the program asks for it (XTSHIFTESCAPE 1).
    case off = "false"
    /// Shift goes to the program, unless it gives it back (XTSHIFTESCAPE 0).
    case on = "true"
    /// Shift always goes to the program, whatever it asks.
    case always
    /// Shift always selects, whatever the program asks.
    case never

    /// Whether Shift is reported to the program, given what the program
    /// asked with XTSHIFTESCAPE -- nil if it has not.
    public func capturesShift(programRequest: Bool?) -> Bool {
        switch self {
        case .off: return programRequest ?? false
        case .on: return programRequest ?? true
        case .always: return true
        case .never: return false
        }
    }
}

/// A pinned command header at the top of the terminal pane while scrolling through long command output.
public struct StickyCommandHeader: Equatable {
    public let commandId: UInt64
    public let command: String
    public let promptRetainedRow: UInt64
    /// 0 = running, 1 = success (exit code 0), 2 = error (non-zero or abandoned/none)
    public let status: UInt8
    public let exitCode: Int32?

    public init(commandId: UInt64, command: String, promptRetainedRow: UInt64, status: UInt8, exitCode: Int32?) {
        self.commandId = commandId
        self.command = command
        self.promptRetainedRow = promptRetainedRow
        self.status = status
        self.exitCode = exitCode
    }
}

public typealias ProgressState = TakoTerminalNSView.ProgressState
public typealias LinkSecurityWarning = TakoTerminalNSView.LinkSecurityWarning
public typealias TerminalLink = TakoTerminalNSView.TerminalLink
public typealias SemanticPathPayload = TakoTerminalNSView.SemanticPathPayload
public typealias SemanticPathTarget = TakoTerminalNSView.SemanticPathTarget
public typealias FilteredOutputLine = TakoTerminalNSView.FilteredOutputLine
public typealias CommandTarget = TakoTerminalNSView.CommandTarget

extension TakoTerminalNSView {
    /// Distinct progress states for OSC 9;4 progress reporting (B2).
    public enum ProgressState: String, Equatable, Sendable, CaseIterable {
    case none
    case normal
    case error
    case indeterminate
    case paused
}

/// Security warnings evaluated before opening a link (E8).
public enum LinkSecurityWarning: Equatable, Sendable {
    case unsafeScheme(String)
    case urlMismatch(displayedText: String, targetURL: URL)
    case unconfirmedDestination(URL)
}

/// Represents a terminal link (OSC 8 hyperlink or detected plain URL) and its security metadata (E8).
public struct TerminalLink: Equatable, Sendable {
    public let url: URL
    public let text: String
    public let row: Int
    public let colStart: Int
    public let colEnd: Int
    public let isOsc8: Bool
    public let isMismatch: Bool
    public let isSchemeAllowedWithoutPrompt: Bool

    public init(
        url: URL,
        text: String,
        row: Int,
        colStart: Int,
        colEnd: Int,
        isOsc8: Bool,
        isMismatch: Bool,
        isSchemeAllowedWithoutPrompt: Bool
    ) {
        self.url = url
        self.text = text
        self.row = row
        self.colStart = colStart
        self.colEnd = colEnd
        self.isOsc8 = isOsc8
        self.isMismatch = isMismatch
        self.isSchemeAllowedWithoutPrompt = isSchemeAllowedWithoutPrompt
    }

    public var tooltipText: String {
        if isMismatch {
            return "⚠️ Suspicious destination mismatch: \(url.absoluteString)"
        } else if !isSchemeAllowedWithoutPrompt {
            return "External scheme (\(url.scheme ?? "unknown")): \(url.absoluteString)"
        } else {
            return url.absoluteString
        }
    }
}

/// Event payload emitted when a source code file path is clicked under Command (E6).
public struct SemanticPathPayload: Equatable, Sendable {
    public let path: String
    public let line: Int?
    public let col: Int?
    public let cwd: String?
    public let resolvedPath: String

    public init(path: String, line: Int? = nil, col: Int? = nil, cwd: String? = nil, resolvedPath: String) {
        self.path = path
        self.line = line
        self.col = col
        self.cwd = cwd
        self.resolvedPath = resolvedPath
    }
}

/// Validated file path target under the mouse cursor in terminal coordinates (E6).
public struct SemanticPathTarget: Equatable, Sendable {
    public let rawPath: String
    public let line: Int?
    public let col: Int?
    public let resolvedPath: String
    public let row: Int
    public let colStart: Int
    public let colEnd: Int

    public init(
        rawPath: String,
        line: Int? = nil,
        col: Int? = nil,
        resolvedPath: String,
        row: Int,
        colStart: Int,
        colEnd: Int
    ) {
        self.rawPath = rawPath
        self.line = line
        self.col = col
        self.resolvedPath = resolvedPath
        self.row = row
        self.colStart = colStart
        self.colEnd = colEnd
    }
}

/// One retained line captured for output filtering (Focus mode - E5).
public struct FilteredOutputLine: Equatable, Sendable {
    public let retainedRowIndex: Int
    public let text: String
    public let packedCells: Data
    public let graphemes: [FfiGrapheme]

    public init(retainedRowIndex: Int, text: String, packedCells: Data, graphemes: [FfiGrapheme] = []) {
        self.retainedRowIndex = retainedRowIndex
        self.text = text
        self.packedCells = packedCells
        self.graphemes = graphemes
    }
}

    /// Checks whether a URL scheme is considered safe to open without confirmation prompt (E8: http, https, file).
    public static func isSafeScheme(_ scheme: String?) -> Bool {
        guard let scheme = scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https" || scheme == "file"
    }

    static let domainCandidateRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}(?::\d+)?(?:/[^\s]*)?$"#,
            options: [.caseInsensitive]
        )
    }()

    /// Detects whether displayed text looks like a URL or domain pointing to a different destination than targetURL (E8).
    public static func detectLinkMismatch(text: String, targetURL: URL) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let candidateString: String?
        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("ftp://") || lower.hasPrefix("file://") {
            candidateString = trimmed
        } else if lower.hasPrefix("mailto:") {
            let emailPart = String(trimmed.dropFirst(7))
            let emailWithoutQuery = emailPart.components(separatedBy: "?").first ?? ""
            if let atIdx = emailWithoutQuery.lastIndex(of: "@") {
                let domain = String(emailWithoutQuery[emailWithoutQuery.index(after: atIdx)...]).trimmingCharacters(in: .whitespaces)
                candidateString = domain.isEmpty ? nil : "https://" + domain
            } else {
                candidateString = nil
            }
        } else if lower.hasPrefix("www.") {
            candidateString = "https://" + trimmed
        } else if let match = domainCandidateRegex.firstMatch(in: trimmed, range: NSRange(location: 0, length: (trimmed as NSString).length)),
                  match.range.location == 0 && match.range.length == (trimmed as NSString).length {
            candidateString = "https://" + trimmed
        } else {
            candidateString = nil
        }

        guard let candidateString,
              let candidateURL = URL(string: candidateString),
              let candidateHost = candidateURL.host?.lowercased(),
              !candidateHost.isEmpty else {
            return false
        }

        guard candidateHost.contains(".") || candidateHost == "localhost" else {
            return false
        }

        if targetURL.isFileURL {
            if candidateHost.lowercased() == targetURL.lastPathComponent.lowercased() {
                return false
            }
        }

        let targetHost: String?
        if let host = targetURL.host?.lowercased(), !host.isEmpty {
            targetHost = host
        } else if targetURL.scheme?.lowercased() == "mailto" {
            let abs = targetURL.absoluteString
            let emailPart = abs.lowercased().hasPrefix("mailto:") ? String(abs.dropFirst(7)) : abs
            let targetEmail = emailPart.components(separatedBy: "?").first ?? ""
            if let atIdx = targetEmail.lastIndex(of: "@") {
                targetHost = String(targetEmail[targetEmail.index(after: atIdx)...]).trimmingCharacters(in: .whitespaces).lowercased()
            } else {
                targetHost = nil
            }
        } else {
            targetHost = nil
        }

        guard let targetHost, !targetHost.isEmpty else {
            return true
        }

        let normCandidate = candidateHost.hasPrefix("www.") ? String(candidateHost.dropFirst(4)) : candidateHost
        let normTarget = targetHost.hasPrefix("www.") ? String(targetHost.dropFirst(4)) : targetHost

        return normCandidate != normTarget
    }

    /// Matches the schemes upstream's `link-url` looks for: `http`,
    /// `https`, `file` and `mailto`.
    static let urlPattern: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"(?:https?|file)://[^\s<>"']+|mailto:[^\s<>"']+"#)
    }()

    /// Matches tokens of the form path[:line[:col]], bounded by whitespace, quotes, or brackets (E6).
    public static let semanticPathPattern: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"(?<=^|[\s"'\[\]()<>])([a-zA-Z0-9_.~/][a-zA-Z0-9_.~/-]*?)(?::([0-9]+)(?::([0-9]+))?)?(?=$|[\s"'\[\]()<>,;:])"#,
            options: []
        )
    }()
}
#endif
