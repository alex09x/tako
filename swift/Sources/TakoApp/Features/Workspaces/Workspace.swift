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

/// A workspace groups tabs that belong to one project: a name, a root directory,
/// a colour or icon, its own tab order, and its own attention count (C1).
public struct Workspace: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var rootDirectory: String?
    public var color: String?
    public var icon: String?
    public var tabIdentifiers: [String]
    public var activeTabIdentifier: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        rootDirectory: String? = nil,
        color: String? = nil,
        icon: String? = nil,
        tabIdentifiers: [String] = [],
        activeTabIdentifier: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.rootDirectory = rootDirectory
        self.color = color
        self.icon = icon
        self.tabIdentifiers = tabIdentifiers
        self.activeTabIdentifier = activeTabIdentifier
        self.createdAt = createdAt
    }
}
