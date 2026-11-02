/*
 * tako — Theme configuration targets
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation

enum ThemeControlScope {
    case global
    case workspace(UUID, String?)
    case pane(UUID, workspaceID: UUID?)

    var appearance: AppearanceScope? {
        switch self {
        case .global: return nil
        case .workspace(let id, _): return .workspace(id)
        case .pane(let id, _): return .pane(id)
        }
    }

    var kind: String {
        switch self { case .global: return "global"; case .workspace: return "workspace"; case .pane: return "pane" }
    }

    var workspaceID: UUID? {
        switch self { case .global: return nil; case .workspace(let id, _): return id; case .pane(_, let id): return id }
    }

    var paneID: UUID? {
        if case .pane(let id, _) = self { return id }
        return nil
    }

    var metadata: [String: JSON] {
        switch self {
        case .global: return ["scope": .string(kind), "scope_id": .null]
        case .workspace(let id, let name):
            return ["scope": .string(kind), "scope_id": .string(id.uuidString.lowercased()), "workspace": name.map(JSON.string) ?? .null]
        case .pane(let id, let workspace):
            return ["scope": .string(kind), "scope_id": .string(id.uuidString.lowercased()),
                    "target": .string(id.uuidString.lowercased()), "workspace_id": workspace.map { .string($0.uuidString.lowercased()) } ?? .null]
        }
    }
}
