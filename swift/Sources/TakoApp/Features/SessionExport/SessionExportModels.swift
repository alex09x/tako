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

/// Errors that can occur during session export or import (C9).
public enum SessionExportError: LocalizedError, Equatable {
    case unsupportedFormatVersion(got: Int, supported: Int)
    case invalidSessionFile(String)
    case fileNotFound(String)
    case emptySession

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormatVersion(let got, let supported):
            return "Unsupported session format version \(got); this version of Tako supports up to version \(supported)."
        case .invalidSessionFile(let reason):
            return "Invalid session file: \(reason)"
        case .fileNotFound(let path):
            return "Session file not found: \(path)"
        case .emptySession:
            return "Session contains no windows or panes to export"
        }
    }
}

/// A serialized Tako session export file containing window layouts, scrollback, and resume records (C9).
public struct SessionExportFile: Codable, Equatable {
    public static let currentFormatVersion: Int = 1

    public var formatVersion: Int
    public var exportedAt: Date
    public var takoVersion: String
    public var windows: [ExportedWindow]

    public init(
        formatVersion: Int = SessionExportFile.currentFormatVersion,
        exportedAt: Date = Date(),
        takoVersion: String = "0.1.7",
        windows: [ExportedWindow]
    ) {
        self.formatVersion = formatVersion
        self.exportedAt = exportedAt
        self.takoVersion = takoVersion
        self.windows = windows
    }
}

/// Serialized state for a single terminal window (C9).
public struct ExportedWindow: Codable, Equatable {
    public var id: UUID
    public var titleOverride: String?
    public var tabColor: String?
    public var layout: ExportedLayoutNode
    public var panes: [ExportedPane]

    public init(
        id: UUID = UUID(),
        titleOverride: String? = nil,
        tabColor: String? = nil,
        layout: ExportedLayoutNode,
        panes: [ExportedPane]
    ) {
        self.id = id
        self.titleOverride = titleOverride
        self.tabColor = tabColor
        self.layout = layout
        self.panes = panes
    }
}

/// Recursive split tree structure for an exported window layout (C9).
public indirect enum ExportedLayoutNode: Codable, Equatable {
    case leaf(paneId: UUID)
    case split(direction: String, ratio: Double, left: ExportedLayoutNode, right: ExportedLayoutNode)

    private enum CodingKeys: String, CodingKey {
        case type, paneId, direction, ratio, left, right
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        if type == "leaf" {
            let paneId = try container.decode(UUID.self, forKey: .paneId)
            self = .leaf(paneId: paneId)
        } else if type == "split" {
            let direction = try container.decode(String.self, forKey: .direction)
            let ratio = try container.decode(Double.self, forKey: .ratio)
            let left = try container.decode(ExportedLayoutNode.self, forKey: .left)
            let right = try container.decode(ExportedLayoutNode.self, forKey: .right)
            self = .split(direction: direction, ratio: ratio, left: left, right: right)
        } else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown layout node type: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .leaf(let paneId):
            try container.encode("leaf", forKey: .type)
            try container.encode(paneId, forKey: .paneId)
        case .split(let direction, let ratio, let left, let right):
            try container.encode("split", forKey: .type)
            try container.encode(direction, forKey: .direction)
            try container.encode(ratio, forKey: .ratio)
            try container.encode(left, forKey: .left)
            try container.encode(right, forKey: .right)
        }
    }
}

/// Exported pane metadata, sanitized scrollback, and resume configuration (C9).
public struct ExportedPane: Codable, Equatable {
    public var id: UUID
    public var pwd: String?
    public var title: String?
    public var scrollback: String
    public var resume: ExportedResume?

    public init(
        id: UUID,
        pwd: String? = nil,
        title: String? = nil,
        scrollback: String = "",
        resume: ExportedResume? = nil
    ) {
        self.id = id
        self.pwd = pwd
        self.title = title
        self.scrollback = scrollback
        self.resume = resume
    }
}

/// Exported command resumption binding (C9).
public struct ExportedResume: Codable, Equatable {
    public var argv: [String]
    public var cwd: String
    public var env: [String: String]?

    public init(argv: [String], cwd: String, env: [String: String]? = nil) {
        self.argv = argv
        self.cwd = cwd
        self.env = env.map { ResumeSessionStore.sanitizeEnvironment($0) }
    }
}

/// Lightweight overview returned by session inspection (C9).
public struct SessionInfo: Codable, Equatable {
    public var formatVersion: Int
    public var exportedAt: Date
    public var takoVersion: String
    public var windowCount: Int
    public var paneCount: Int
    public var resumeCount: Int

    public init(
        formatVersion: Int,
        exportedAt: Date,
        takoVersion: String,
        windowCount: Int,
        paneCount: Int,
        resumeCount: Int
    ) {
        self.formatVersion = formatVersion
        self.exportedAt = exportedAt
        self.takoVersion = takoVersion
        self.windowCount = windowCount
        self.paneCount = paneCount
        self.resumeCount = resumeCount
    }
}
