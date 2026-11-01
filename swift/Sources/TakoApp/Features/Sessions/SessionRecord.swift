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

/// The identity and last known placement of a persistent terminal.
struct SessionRecord: Codable, Equatable {
    enum State: Codable, Equatable {
        case creating
        case attached
        case detached
        case error(String)
    }

    var id: UUID
    var runtimeID: String
    var generation: String
    var state: State
    var createdAt: Date
    var quietSince: Date?
    var workspaceID: UUID? = nil
    var tabIdentifier: String? = nil
    var workingDirectory: String? = nil
    /// Stable tab IDs that shared this physical window at the last capture.
    /// Optional so records written by older versions still decode.
    var windowTabIdentifiers: [String]? = nil

    static func newGeneration() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
