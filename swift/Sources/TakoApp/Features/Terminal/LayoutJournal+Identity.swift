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

extension LayoutJournal {
    struct JournalError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// A malformed journal must never create two windows for one tab or pane.
    struct IdentityAccumulator {
        private var tabs = Set<String>()
        private var panes = Set<UUID>()

        mutating func accept(_ tab: [String: Any]) -> Bool {
            if let id = tab["tabIdentifier"] as? String, !id.isEmpty,
               !tabs.insert(id.lowercased()).inserted { return false }
            guard let tree = tab["surfaceTree"] as? [String: Any], let root = tree["root"] else { return true }
            return collect(root)
        }

        private mutating func collect(_ value: Any) -> Bool {
            if let array = value as? [Any] {
                for child in array where !collect(child) { return false }
            } else if let object = value as? [String: Any] {
                if let view = object["view"] as? [String: Any], let id = view["id"] as? String,
                   let uuid = UUID(uuidString: id), !panes.insert(uuid).inserted { return false }
                for child in object.values where !collect(child) { return false }
            }
            return true
        }
    }
}
