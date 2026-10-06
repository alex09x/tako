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

/// `self` is the pane the client runs in; `active` the focused pane of the
/// front window, decided once, when the request is taken; otherwise a full
/// pane id or a prefix of one that matches exactly one pane. No fallback:
/// a pane that is gone is `notFound`, never another pane.
enum ControlTarget: Equatable {
    case current
    case active
    case id(String)

    /// The target named by `args["target"]`; without one, the client's own
    /// pane when it runs in one, otherwise the active pane.
    static func from(_ args: [String: JSON], requestFrom: UUID?) throws -> ControlTarget {
        switch args["target"] {
        case nil, .null?:
            return requestFrom == nil ? .active : .current
        case .string(let s)?:
            switch s.lowercased() {
            case "", "self": return .current
            case "active": return .active
            default: return .id(s.lowercased())
            }
        default:
            throw ControlError(.invalid, "\"target\" is not a string")
        }
    }

    func resolve(panes: [UUID], requestFrom: UUID?, active: UUID?) throws -> UUID {
        switch self {
        case .current:
            guard let from = requestFrom else {
                throw ControlError(.notFound, "\"self\" needs a request from inside a Tako pane")
            }
            guard panes.contains(from) else {
                throw ControlError(.notFound, "the pane this request came from is gone")
            }
            return from
        case .active:
            guard let active, panes.contains(active) else {
                throw ControlError(.notFound, "no pane is active")
            }
            return active
        case .id(let prefix):
            let matches = panes.filter { $0.uuidString.lowercased().hasPrefix(prefix) }
            switch matches.count {
            case 0: throw ControlError(.notFound, "no pane matches \(prefix)")
            case 1: return matches[0]
            default:
                throw ControlError(.ambiguous, "\(matches.count) panes match \(prefix)",
                                   candidates: matches.map { $0.uuidString.lowercased() }.sorted())
            }
        }
    }
}

/// The `remote-control` setting.
enum RemoteControlMode: String {
    /// Requests from inside a Tako pane: `from` names a pane that exists.
    case local
    /// Any request on the socket.
    case on
    /// No socket at all.
    case off

    /// Whether a request may be served. A gate on where it comes from, not
    /// on who: the socket's owner and mode are what keep other users out.
    func allows(from: UUID?, panes: [UUID]) -> Bool {
        switch self {
        case .off: return false
        case .on: return true
        case .local: return from.map(panes.contains) ?? false
        }
    }
}
