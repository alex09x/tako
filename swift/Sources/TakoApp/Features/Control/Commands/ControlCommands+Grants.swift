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

extension ControlCommands {
    @_silgen_name("proc_pidpath")
    private static func proc_pidpath(_ pid: Int32, _ buffer: UnsafeMutablePointer<CChar>, _ buffersize: UInt32) -> Int32

    /// Derives the verified process origin strictly from the accepted socket's peer credentials/PID.
    static func resolvePeerProcess(for request: ControlRequest) -> (description: String, pid: pid_t?) {
        if request.clientFD >= 0 {
            var peerPID: pid_t = 0
            var len = socklen_t(MemoryLayout<pid_t>.size)
            // 0 is SOL_LOCAL, 2 is LOCAL_PEERPID on Darwin
            if getsockopt(request.clientFD, 0, 2, &peerPID, &len) == 0 && peerPID > 0 {
                var pathBuf = [CChar](repeating: 0, count: 4096)
                let pathLen = proc_pidpath(peerPID, &pathBuf, UInt32(pathBuf.count))
                if pathLen > 0 {
                    let procPath = String(cString: pathBuf)
                    let procName = (procPath as NSString).lastPathComponent
                    return ("Process: \(procName) [\(procPath)] (PID \(peerPID))", peerPID)
                }
                return ("Process (PID \(peerPID))", peerPID)
            }
        }
        return ("External process via control socket", nil)
    }

    /// Evaluates caller-claimed pane context against the verified peer PID and active panes.
    /// Caller-supplied pane information is NEVER presented as verified origin.
    static func resolvePaneContext(for request: ControlRequest, peerPID: pid_t?, all: [Pane]) -> String? {
        guard let from = request.from else { return nil }
        guard let pane = all.first(where: { $0.surface.id == from }) else {
            return "Claimed Pane Context (unverified, inactive): ID \(from.uuidString.lowercased())"
        }
        let rawTitle = pane.surface.title.isEmpty ? "Terminal" : pane.surface.title
        let rawCwd = pane.surface.workingDirectory ?? "unknown"
        let safeTitle = sanitizeSingleLineText(rawTitle, maxLen: 128) ?? "Terminal"
        let safeCwd = sanitizeSingleLineText(rawCwd, maxLen: 256) ?? "unknown"
        let shellPID = pane.surface.pid

        if let pid = peerPID, shellPID > 0 {
            if Int(pid) == shellPID || LocalPortInspection.descendantPids(rootPid: shellPID).contains(Int(pid)) {
                return "Associated Terminal Pane (process membership verified): ID \(from.uuidString.lowercased()) (shell PID \(shellPID), shell-reported title: \"\(safeTitle)\", cwd: \(safeCwd))"
            } else {
                return "Claimed Pane Context (unverified — socket peer PID \(pid) is not a process in this pane): ID \(from.uuidString.lowercased()) (reported title: \"\(safeTitle)\", cwd: \(safeCwd))"
            }
        }

        return "Claimed Pane Context (unverified, caller-asserted): ID \(from.uuidString.lowercased()) (reported title: \"\(safeTitle)\", cwd: \(safeCwd))"
    }

    /// Resolves origin description for display.
    static func resolveOrigin(for request: ControlRequest, all: [Pane]) -> String {
        let (procOrigin, peerPID) = resolvePeerProcess(for: request)
        if let paneCtx = resolvePaneContext(for: request, peerPID: peerPID, all: all) {
            return "\(procOrigin)\n\(paneCtx)"
        }
        return procOrigin
    }

    /// Records automated activity on a target pane for Track G2.
    static func recordActivity(for request: ControlRequest, on paneId: UUID, action: String) {
        let client = request.client ?? request.args["client"]?.string ?? "anonymous"
        InputOwnershipStore.shared.recordAutomation(paneId: paneId, client: client, action: action)
    }

    static func sanitizeIdentifier(_ s: String, maxLen: Int = 64) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxLen else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.@"))
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return nil
        }
        return trimmed
    }

    static func sanitizeSingleLineText(_ s: String, maxLen: Int = 256) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= maxLen else { return nil }
        for scalar in trimmed.unicodeScalars {
            if scalar.value < 32 || scalar.value == 127 {
                return nil
            }
        }
        return trimmed
    }

    /// Hook for testability or custom confirmation UI: takes (client, scopes, description, origin, completionHandler).
    static var userGrantPrompt: (@MainActor (String, Set<ControlScope>, String?, String, @escaping @Sendable (Bool) -> Void) -> Void)? = nil

    static func handleGrantRequest(_ request: ControlRequest, all: [Pane], reply: @escaping @Sendable (ControlResponse) -> Void) {
        do {
            guard let rawClient = request.args["client"]?.string,
                  let client = sanitizeIdentifier(rawClient) else {
                throw ControlError(.invalid, "missing, empty, or invalid \"client\" for grant request (must be a single-line safe identifier of at most 64 characters: alphanumeric, -, _, ., @)")
            }
            let desc: String?
            if let rawDesc = request.args["description"]?.string {
                guard let sanitized = sanitizeSingleLineText(rawDesc) else {
                    throw ControlError(.invalid, "invalid \"description\" for grant request (must be a single-line string of at most 256 characters without control characters)")
                }
                desc = sanitized
            } else {
                desc = nil
            }
            let parsed = try ControlScope.parseScopes(from: request.args["scopes"])
            let candidateScopes = parsed ?? Set(ControlScope.allCases).subtracting([.approval])
            let effectiveScopes = candidateScopes.subtracting([.approval])
            guard !effectiveScopes.isEmpty else {
                throw ControlError(.invalid, "grant request cannot grant approval scope; requested scopes must contain at least one standard scope")
            }

            let (procOrigin, peerPID) = resolvePeerProcess(for: request)
            let paneContext = resolvePaneContext(for: request, peerPID: peerPID, all: all)
            let displayOrigin = paneContext != nil ? "\(procOrigin)\n\(paneContext!)" : procOrigin

            if let customPrompt = userGrantPrompt {
                customPrompt(client, effectiveScopes, desc, displayOrigin) { approved in
                    if approved {
                        let grant = ControlGrantStore.shared.issueGrant(client: client, scopes: effectiveScopes, description: desc)
                        reply(.ok([
                            "token": .string(grant.token),
                            "client": .string(grant.client),
                            "scopes": .array(grant.scopes.map { .string($0.rawValue) }.sorted(by: { $0.string! < $1.string! }))
                        ]))
                    } else {
                        reply(.failure(ControlError(.disabled, "grant request for '\(client)' was denied by user")))
                    }
                }
                return
            }

            guard NSApp != nil else {
                reply(.failure(ControlError(.disabled, "user-mediated grant confirmation is unavailable without application host")))
                return
            }

            let alert = NSAlert()
            alert.messageText = "Remote Control Access Request"
            let scopeList = effectiveScopes.map(\.rawValue).sorted().joined(separator: ", ")
            var info = """
            An unauthenticated client is requesting remote control access to Tako.

            Origin (verified): \(procOrigin)
            """
            if let pc = paneContext {
                info += "\n\(pc)"
            }
            info += """

            Requested Scopes: [\(scopeList)]
            Claimed Client Name (unverified): "\(client)"
            """
            if let d = desc, !d.isEmpty {
                info += "\nClaimed Purpose (unverified): \"\(d)\""
            }
            info += "\n\nWarning: Authorizing this request will grant the process the ability to interact with your terminal sessions. Do you want to allow this request?"
            alert.informativeText = info
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Deny")

            let appDelegate = NSApp?.delegate as? AppDelegate
            let response = appDelegate?.runModalAlert(alert) ?? alert.runModal()
            if response == .alertFirstButtonReturn {
                let grant = ControlGrantStore.shared.issueGrant(client: client, scopes: effectiveScopes, description: desc)
                reply(.ok([
                    "token": .string(grant.token),
                    "client": .string(grant.client),
                    "scopes": .array(grant.scopes.map { .string($0.rawValue) }.sorted(by: { $0.string! < $1.string! }))
                ]))
            } else {
                reply(.failure(ControlError(.disabled, "grant request for '\(client)' was denied by user")))
            }
        } catch let err as ControlError {
            reply(.failure(err))
        } catch {
            reply(.failure(ControlError(.internalError, "\(error)")))
        }
    }

    static func grantCommand(_ request: ControlRequest, all: [Pane]) throws -> [String: JSON] {
        let sub = request.args["subcommand"]?.string ?? ""
        switch sub {
        case "request":
            throw ControlError(.invalid, "grant request requires user confirmation and must be handled via socket or with completion handler")
        case "create":
            guard let client = request.args["client"]?.string, !client.isEmpty else {
                throw ControlError(.invalid, "missing or empty \"client\" for grant create")
            }
            let scopes = try ControlScope.parseScopes(from: request.args["scopes"]) ?? Set(ControlScope.allCases)
            let desc = request.args["description"]?.string
            let grant = ControlGrantStore.shared.issueGrant(client: client, scopes: scopes, description: desc)
            return [
                "token": .string(grant.token),
                "client": .string(grant.client),
                "scopes": .array(grant.scopes.map { .string($0.rawValue) }.sorted(by: { $0.string! < $1.string! }))
            ]
        case "revoke":
            guard let tokenToRevoke = request.args["token"]?.string, !tokenToRevoke.isEmpty else {
                throw ControlError(.invalid, "missing \"token\" for grant revoke")
            }
            let revoked = ControlGrantStore.shared.revokeGrant(token: tokenToRevoke)
            return ["revoked": .bool(revoked)]
        case "list":
            let grants = ControlGrantStore.shared.listGrants()
            let items: [JSON] = grants.map { g in
                .object([
                    "id": .string(g.id.uuidString.lowercased()),
                    "client": .string(g.client),
                    "scopes": .array(g.scopes.map { .string($0.rawValue) }.sorted(by: { $0.string! < $1.string! })),
                    "created_at": .number(g.createdAt.timeIntervalSince1970)
                ])
            }
            return ["grants": .array(items)]
        default:
            throw ControlError(.invalid, "unknown grant subcommand '\(sub)'; use request, create, revoke, or list")
        }
    }
}
