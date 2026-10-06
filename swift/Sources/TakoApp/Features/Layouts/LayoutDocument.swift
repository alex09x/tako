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
import AppKit

/// Split direction within a declarative layout.
enum LayoutSplitDirection: String, Codable, Equatable, Sendable {
    case horizontal
    case vertical

    var asSplitTreeDirection: SplitTree<Tako.SurfaceView>.Direction {
        switch self {
        case .horizontal: return .horizontal
        case .vertical: return .vertical
        }
    }

    init(from direction: SplitTree<Tako.SurfaceView>.Direction) {
        switch direction {
        case .horizontal: self = .horizontal
        case .vertical: self = .vertical
        }
    }
}

/// Window frame representation in a declarative layout.
struct LayoutFrame: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(_ rect: NSRect) {
        self.x = Double(rect.origin.x)
        self.y = Double(rect.origin.y)
        self.width = Double(rect.size.width)
        self.height = Double(rect.size.height)
    }

    var asRect: NSRect {
        NSRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height))
    }
}

/// A terminal pane inside a declarative layout.
struct LayoutPane: Codable, Equatable, Sendable {
    var title: String?
    var cwd: String?
    var env: [String: String]?
    var command: [String]?
    var argv: [String]?
    var shell: Bool?

    init(
        title: String? = nil,
        cwd: String? = nil,
        env: [String: String]? = nil,
        command: [String]? = nil,
        argv: [String]? = nil,
        shell: Bool? = nil
    ) {
        self.title = title
        self.cwd = cwd
        self.env = env
        self.command = command
        self.argv = argv
        self.shell = shell
    }

    /// The effective argument vector for program execution (command or argv).
    var effectiveCommand: [String]? {
        if let command, !command.isEmpty { return command }
        if let argv, !argv.isEmpty { return argv }
        return nil
    }

    /// Whether this pane specifies an executable program or custom environment.
    var hasProgram: Bool {
        if let cmd = effectiveCommand, !cmd.isEmpty { return true }
        if let env, !env.isEmpty { return true }
        return false
    }

    enum CodingKeys: String, CodingKey {
        case title
        case cwd
        case env
        case command
        case argv
        case shell
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        self.env = try container.decodeIfPresent([String: String].self, forKey: .env)
        self.shell = try container.decodeIfPresent(Bool.self, forKey: .shell)

        // Support command as [String] or single String
        if let arr = try? container.decode([String].self, forKey: .command) {
            self.command = arr
        } else if let str = try? container.decode(String.self, forKey: .command) {
            self.command = [str]
        } else {
            self.command = nil
        }

        // Support argv as [String] or single String
        if let arr = try? container.decode([String].self, forKey: .argv) {
            self.argv = arr
        } else if let str = try? container.decode(String.self, forKey: .argv) {
            self.argv = [str]
        } else {
            self.argv = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(cwd, forKey: .cwd)
        try container.encodeIfPresent(env, forKey: .env)
        try container.encodeIfPresent(effectiveCommand, forKey: .command)
        try container.encodeIfPresent(shell, forKey: .shell)
    }
}

/// A split container node inside a declarative layout.
struct LayoutSplit: Codable, Equatable, Sendable {
    var direction: LayoutSplitDirection
    var ratio: Double
    var left: LayoutNode
    var right: LayoutNode

    init(
        direction: LayoutSplitDirection,
        ratio: Double = 0.5,
        left: LayoutNode,
        right: LayoutNode
    ) {
        self.direction = direction
        self.ratio = ratio
        self.left = left
        self.right = right
    }

    enum CodingKeys: String, CodingKey {
        case direction
        case ratio
        case left
        case right
        case first
        case second
        case top
        case bottom
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.direction = try container.decode(LayoutSplitDirection.self, forKey: .direction)
        self.ratio = (try? container.decode(Double.self, forKey: .ratio)) ?? 0.5

        if let l = try? container.decode(LayoutNode.self, forKey: .left) {
            self.left = l
        } else if let f = try? container.decode(LayoutNode.self, forKey: .first) {
            self.left = f
        } else if let t = try? container.decode(LayoutNode.self, forKey: .top) {
            self.left = t
        } else {
            throw DecodingError.keyNotFound(CodingKeys.left, .init(codingPath: decoder.codingPath, debugDescription: "missing left child in split"))
        }

        if let r = try? container.decode(LayoutNode.self, forKey: .right) {
            self.right = r
        } else if let s = try? container.decode(LayoutNode.self, forKey: .second) {
            self.right = s
        } else if let b = try? container.decode(LayoutNode.self, forKey: .bottom) {
            self.right = b
        } else {
            throw DecodingError.keyNotFound(CodingKeys.right, .init(codingPath: decoder.codingPath, debugDescription: "missing right child in split"))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(direction, forKey: .direction)
        try container.encode(ratio, forKey: .ratio)
        try container.encode(left, forKey: .left)
        try container.encode(right, forKey: .right)
    }
}

/// A node in a tab's split tree: either a single pane or a split.
indirect enum LayoutNode: Codable, Equatable, Sendable {
    case leaf(LayoutPane)
    case split(LayoutSplit)

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: LayoutSplit.CodingKeys.self)
        if container.contains(.direction) {
            let split = try LayoutSplit(from: decoder)
            self = .split(split)
        } else {
            let pane = try LayoutPane(from: decoder)
            self = .leaf(pane)
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .leaf(let pane):
            try pane.encode(to: encoder)
        case .split(let split):
            try split.encode(to: encoder)
        }
    }

    /// Recursively collects all panes in this tree.
    var allPanes: [LayoutPane] {
        switch self {
        case .leaf(let pane):
            return [pane]
        case .split(let split):
            return split.left.allPanes + split.right.allPanes
        }
    }

    /// Whether any pane in this tree specifies a program.
    var hasPrograms: Bool {
        allPanes.contains { $0.hasProgram }
    }
}

/// A tab in a declarative layout.
struct LayoutTab: Codable, Equatable, Sendable {
    var title: String?
    var color: String?
    var root: LayoutNode

    init(title: String? = nil, color: String? = nil, root: LayoutNode) {
        self.title = title
        self.color = color
        self.root = root
    }

    var allPanes: [LayoutPane] { root.allPanes }
    var hasPrograms: Bool { root.hasPrograms }
}

/// A window in a declarative layout.
struct LayoutWindow: Codable, Equatable, Sendable {
    var title: String?
    var frame: LayoutFrame?
    var selectedTab: Int?
    var tabs: [LayoutTab]

    init(title: String? = nil, frame: LayoutFrame? = nil, selectedTab: Int? = nil, tabs: [LayoutTab] = []) {
        self.title = title
        self.frame = frame
        self.selectedTab = selectedTab
        self.tabs = tabs
    }

    var allPanes: [LayoutPane] { tabs.flatMap(\.allPanes) }
    var hasPrograms: Bool { tabs.contains { $0.hasPrograms } }
}

/// A declarative layout document representing one or more windows.
struct LayoutDocument: Codable, Equatable, Sendable {
    var version: Int
    var name: String?
    var windows: [LayoutWindow]
    var tabs: [LayoutTab]?

    init(version: Int = 1, name: String? = nil, windows: [LayoutWindow] = [], tabs: [LayoutTab]? = nil) {
        self.version = version
        self.name = name
        self.windows = windows
        self.tabs = tabs
    }

    /// Windows to apply, synthesizing a single window if only top-level `tabs` was supplied.
    var effectiveWindows: [LayoutWindow] {
        if !windows.isEmpty { return windows }
        if let tabs, !tabs.isEmpty {
            return [LayoutWindow(tabs: tabs)]
        }
        return []
    }

    /// All panes across all windows.
    var allPanes: [LayoutPane] {
        effectiveWindows.flatMap(\.allPanes)
    }

    /// Whether any pane in this document specifies an executable program.
    var hasPrograms: Bool {
        effectiveWindows.contains { $0.hasPrograms }
    }

    /// Program summaries: (cwd, command) for all panes specifying executable commands.
    var programsSummary: [(cwd: String?, command: [String])] {
        allPanes.compactMap { pane in
            guard let cmd = pane.effectiveCommand, !cmd.isEmpty else { return nil }
            return (pane.cwd, cmd)
        }
    }
}
