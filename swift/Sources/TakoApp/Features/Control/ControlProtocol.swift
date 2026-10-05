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

/// Capability scopes for socket clients (Track G1).
enum ControlScope: String, CaseIterable, Sendable, Codable {
    case read
    case input
    case layout
    case signal
    case overlay
    case approval

    /// The scopes required to run a given command with specific args.
    /// Returns an empty set for unscoped discovery commands (e.g. `version`).
    static func required(for cmd: String, args: [String: JSON] = [:]) -> Set<ControlScope> {
        switch cmd {
        case "version":
            return []
        case "tree", "text", "last", "find", "events", "screenshot", "history", "activity":
            return [.read]
        case "send", "type", "key", "broadcast":
            return [.input]
        case "input":
            let sub = args["subcommand"]?.string ?? ""
            if sub == "log" || sub == "status" {
                return [.read]
            }
            if sub == "allow-automation" || sub == "enable-automation" ||
               sub == "disallow-automation" || sub == "disable-automation" ||
               sub == "confirm-automation" {
                return [.approval]
            }
            return [.input]
        case "grant":
            let sub = args["subcommand"]?.string ?? ""
            if sub == "request" {
                return []
            }
            return [.approval]
        case "run":
            return [.layout, .input]
        case "tab-new", "split":
            if args["argv"] != nil {
                return [.layout, .input]
            }
            return [.layout]
        case "close", "focus", "collapse", "expand",
             "workspace", "layout", "action", "task", "session", "wait", "resume":
            return [.layout]
        case "notify", "status", "progress", "ask", "title", "triggers":
            return [.signal]
        case "dialog", "overlay":
            return [.overlay]
        case "review":
            let sub = args["subcommand"]?.string ?? ""
            if sub == "send" {
                return [.input]
            }
            return [.read]
        default:
            return []
        }
    }

    /// Parses scopes from a JSON string, comma-separated string, or array of strings.
    static func parseScopes(from raw: JSON?) throws -> Set<ControlScope>? {
        guard let raw else { return nil }
        switch raw {
        case .null:
            return nil
        case .array(let arr):
            var parsedScopes: Set<ControlScope> = []
            for item in arr {
                guard case .string(let s) = item else {
                    throw ControlError(.invalid, "item in \"scopes\" must be a string")
                }
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if trimmed.isEmpty { continue }
                guard let scope = ControlScope(rawValue: trimmed) else {
                    throw ControlError(.invalid, "unknown scope '\(s)'; valid scopes are \(ControlScope.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                parsedScopes.insert(scope)
            }
            return parsedScopes
        case .string(let s):
            var parsedScopes: Set<ControlScope> = []
            for part in s.split(separator: ",") {
                let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if trimmed.isEmpty { continue }
                guard let scope = ControlScope(rawValue: trimmed) else {
                    throw ControlError(.invalid, "unknown scope '\(trimmed)'; valid scopes are \(ControlScope.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                parsedScopes.insert(scope)
            }
            return parsedScopes
        default:
            throw ControlError(.invalid, "\"scopes\" must be an array of strings or comma-separated string")
        }
    }
}

/// The wire format of `takoctl`: one JSON request per connection, one JSON
/// response, then the connection closes.
///
///     {"cmd": "tree", "args": {...}, "from": "<pane uuid>"}
///     {"ok": true, "result": {...}}
///     {"ok": false, "error": {"code": "notFound", "message": "..."}}
///
/// `from` is the pane the client runs in (`TAKO_SURFACE_ID`), when it runs
/// in one. It says where a request comes from; it is not a credential --
/// anything running as this user can open the socket.
enum ControlProtocol {
    static let version = 1
    /// Largest request read; past it the connection is answered `invalid`.
    static let maxRequestBytes = 1 << 20
}

/// A JSON value, as much of it as requests and responses need.
enum JSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    init(any value: Any) throws {
        switch value {
        case is NSNull: self = .null
        case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): self = .bool(n.boolValue)
        case let n as NSNumber: self = .number(n.doubleValue)
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(try a.map(JSON.init(any:)))
        case let o as [String: Any]: self = .object(try o.mapValues(JSON.init(any:)))
        default: throw ControlError(.invalid, "unsupported JSON value")
        }
    }

    /// The number this is, if it is one.
    var number: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    var any: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let a): return a.map(\.any)
        case .object(let o): return o.mapValues(\.any)
        }
    }

    var string: String? { if case .string(let s) = self { return s } else { return nil } }
    var array: [JSON]? { if case .array(let a) = self { return a } else { return nil } }
    var bool: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    var object: [String: JSON]? { if case .object(let o) = self { return o } else { return nil } }
}

struct ControlError: Error, Equatable {
    enum Code: String {
        /// The request was not understood: bad JSON, unknown command, a
        /// missing or mistyped argument.
        case invalid
        /// Nothing matches the target.
        case notFound
        /// More than one pane matches the target's prefix.
        case ambiguous
        /// Remote control is off, or this request is not allowed by the
        /// `remote-control` setting.
        case disabled
        /// Too many requests at once.
        case busy
        case timeout
        /// A wait on the command the request itself is part of: it cannot
        /// end while the request waits.
        case selfWait
        /// The client is missing a capability scope required for this command (Track G1).
        case missingScope = "missingScope"
        /// Automation is not permitted to type into this pane without the switch or confirmation (Track G1).
        case automationNotPermitted = "automationNotPermitted"
        case internalError = "internal"
    }

    let code: Code
    let message: String
    /// For `ambiguous`: the ids that matched.
    var candidates: [String] = []
    /// For `missingScope`: the name of the missing scope (Track G1).
    var scope: String? = nil

    init(_ code: Code, _ message: String, candidates: [String] = [], scope: String? = nil) {
        self.code = code
        self.message = message
        self.candidates = candidates
        self.scope = scope
    }
}

struct ControlRequest: Equatable {
    let cmd: String
    let args: [String: JSON]
    /// The pane the client runs in, as it says.
    let from: UUID?
    /// The client identity (e.g. "takoctl", "agent-123"). Set from server-side grant.
    var client: String?
    /// The authorization token provided by the client, if any.
    let token: String?
    /// The effective capability scopes granted to this client session by the server (Track G1).
    var scopes: Set<ControlScope>?
    /// The scopes requested by the client in its request payload (for attenuation).
    let requestedScopes: Set<ControlScope>?
    /// Whether the client has gone -- closed its end -- so work that waits
    /// for something (`wait`) can stop. Set by the server.
    var clientGone: @Sendable () -> Bool = { false }
    /// Raw socket descriptor when streaming (e.g. `events`).
    var clientFD: Int32 = -1
    /// Streaming connection cleanup callback.
    var onStreamClose: (@Sendable () -> Void)? = nil

    init(
        cmd: String,
        args: [String: JSON] = [:],
        from: UUID? = nil,
        client: String? = nil,
        token: String? = nil,
        scopes: Set<ControlScope>? = nil,
        requestedScopes: Set<ControlScope>? = nil
    ) {
        self.cmd = cmd
        self.args = args
        self.from = from
        self.client = client
        self.token = token
        self.scopes = scopes
        self.requestedScopes = requestedScopes
    }

    static func == (a: Self, b: Self) -> Bool {
        a.cmd == b.cmd && a.args == b.args && a.from == b.from && a.client == b.client && a.token == b.token && a.scopes == b.scopes && a.requestedScopes == b.requestedScopes
    }

    /// Parses one request line. A `from` that is present but not a UUID is
    /// refused rather than ignored: a script that meant its own pane must not
    /// silently act on another.
    static func parse(_ data: Data) throws -> ControlRequest {
        guard data.count <= ControlProtocol.maxRequestBytes else {
            throw ControlError(.invalid, "request larger than \(ControlProtocol.maxRequestBytes) bytes")
        }
        let raw: Any
        do {
            raw = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ControlError(.invalid, "request is not JSON")
        }
        guard case .object(let object) = try JSON(any: raw) else {
            throw ControlError(.invalid, "request is not a JSON object")
        }
        guard let cmd = object["cmd"]?.string, !cmd.isEmpty else {
            throw ControlError(.invalid, "request has no \"cmd\"")
        }
        var args: [String: JSON] = [:]
        switch object["args"] {
        case nil, .null?: break
        case .object(let a)?: args = a
        default: throw ControlError(.invalid, "\"args\" is not an object")
        }
        var from: UUID?
        switch object["from"] {
        case nil, .null?: break
        case .string(let s)? where !s.isEmpty:
            guard let id = UUID(uuidString: s) else {
                throw ControlError(.invalid, "\"from\" is not a pane id")
            }
            from = id
        case .string?: break
        default: throw ControlError(.invalid, "\"from\" is not a string")
        }

        var token: String?
        switch object["token"] ?? object["auth"] ?? args["token"] ?? args["auth"] {
        case nil, .null?: break
        case .string(let s)?:
            token = s.isEmpty ? nil : s
        default:
            throw ControlError(.invalid, "\"token\" is not a string")
        }

        var client: String?
        switch object["client"] {
        case nil, .null?:
            client = args["client"]?.string
        case .string(let s)?:
            client = s.isEmpty ? nil : s
        default:
            throw ControlError(.invalid, "\"client\" is not a string")
        }

        let requestedScopes = try ControlScope.parseScopes(from: object["scopes"] ?? args["scopes"])

        return ControlRequest(
            cmd: cmd,
            args: args,
            from: from,
            client: client,
            token: token,
            scopes: nil,
            requestedScopes: requestedScopes
        )
    }
}

enum ControlResponse {
    case ok([String: JSON])
    case failure(ControlError)

    /// One line of JSON, newline-terminated.
    func encoded() -> Data {
        var object: [String: Any]
        switch self {
        case .ok(let result):
            object = ["ok": true, "result": result.mapValues(\.any)]
        case .failure(let error):
            var body: [String: Any] = ["code": error.code.rawValue, "message": error.message]
            if !error.candidates.isEmpty { body["candidates"] = error.candidates }
            if let scope = error.scope { body["scope"] = scope }
            object = ["ok": false, "error": body]
        }
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data(#"{"ok":false,"error":{"code":"internal","message":"unencodable response"}}"#.utf8)
        data.append(0x0A)
        return data
    }
}

/// Which pane a request means.
///
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
