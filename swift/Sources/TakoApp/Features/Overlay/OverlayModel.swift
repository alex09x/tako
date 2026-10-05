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

/// Supported artifact and document preview types for in-terminal overlays (D1).
public enum OverlayFileType: String, Sendable, CaseIterable, Codable {
    case html
    case markdown
    case image
    case pdf
    case diff

    /// Infer file type from file extension.
    public static func infer(from url: URL) -> OverlayFileType {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "html", "htm", "xhtml":
            return .html
        case "md", "markdown", "mdown", "mkd":
            return .markdown
        case "png", "jpg", "jpeg", "gif", "svg", "webp", "bmp", "ico", "tiff":
            return .image
        case "pdf":
            return .pdf
        case "diff", "patch":
            return .diff
        default:
            return .html
        }
    }

    /// Human-readable title for file type badge.
    public var badgeTitle: String {
        switch self {
        case .html: return "HTML"
        case .markdown: return "MARKDOWN"
        case .image: return "IMAGE"
        case .pdf: return "PDF"
        case .diff: return "DIFF"
        }
    }

    /// SF Symbol icon name for file type.
    public var systemIconName: String {
        switch self {
        case .html: return "chevron.left.forwardslash.chevron.right"
        case .markdown: return "text.quote"
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .diff: return "arrow.left.arrow.right"
        }
    }
}

/// Active overlay state associated with a terminal pane (D1).
public struct OverlayState: Identifiable, Sendable {
    public let id: UUID
    public let paneId: UUID
    public let fileURL: URL
    public let fileType: OverlayFileType
    public let sandboxedDirectory: URL
    public let splitDirection: String? // "right", "left", "down", "up", or nil for inline overlay
    public var title: String
    public var lastModified: Date?

    public init(
        id: UUID = UUID(),
        paneId: UUID,
        fileURL: URL,
        fileType: OverlayFileType,
        sandboxedDirectory: URL,
        splitDirection: String? = nil,
        title: String? = nil,
        lastModified: Date? = nil
    ) {
        self.id = id
        self.paneId = paneId
        self.fileURL = fileURL
        self.fileType = fileType
        self.sandboxedDirectory = sandboxedDirectory
        self.splitDirection = splitDirection
        self.title = title ?? fileURL.lastPathComponent
        self.lastModified = lastModified
    }
}
