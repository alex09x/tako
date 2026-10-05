/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import UserNotifications

/// What `takoctl` requests do, on the main thread.
@MainActor
enum ControlCommands {
    /// The server, while this copy of Tako owns the socket.
    static var server: ControlServer?
    static var mode: RemoteControlMode = .off
    private static var bundleID = "com.tako-core.terminal"

    /// What every new shell is told in `TAKO_SOCKET`: the socket this copy
    /// serves, or "" when it serves none -- control off, another copy of
    /// Tako owning the socket, or a failure to start. Empty rather than
    /// absent, so takoctl in such a pane says control is unavailable here
    /// instead of finding another copy's socket on its own.
    nonisolated(unsafe) static var socketPath = ""

    /// Brings the server in line with `remote-control`: at launch, and again
    /// whenever the configuration is reloaded.
    static func apply(mode newMode: RemoteControlMode, bundleID: String? = nil) {
        if let bundleID { self.bundleID = bundleID }
        mode = newMode
        if newMode == .off {
            // Requests already taken are answered `disabled` by `handle`,
            // which reads the mode when it runs.
            server?.stop()
            server = nil
            socketPath = ""
            return
        }
        guard server == nil else { return }   // local <-> on: only the gate changes
        do {
            let path = try ControlServer.socketPath(bundleID: self.bundleID)
            let candidate = ControlServer(path: path) { request, reply in
                handle(request, reply: reply)
            }
            switch try candidate.start() {
            case .listening:
                server = candidate
                socketPath = path
            case .taken:
                socketPath = ""
                NSLog("takoctl: another copy of Tako serves \(path); control is unavailable in this one")
            }
        } catch {
            socketPath = ""
            NSLog("takoctl: not serving: \(error)")
        }
    }

    static func stop() {
        server?.stop()
        server = nil
        socketPath = ""
    }

    // MARK: - Requests

    /// Every pane, in window and tab order, with where it sits.
    struct Pane {
        let surface: Tako.SurfaceView
        let windowID: String
        let tabID: String
        let stableTabID: String
        let controller: BaseTerminalController?

        init(surface: Tako.SurfaceView, windowID: String, tabID: String, stableTabID: String? = nil, controller: BaseTerminalController? = nil) {
            self.surface = surface
            self.windowID = windowID
            self.tabID = tabID
            self.stableTabID = stableTabID ?? controller?.window?.stableTabIdentifier ?? tabID
            self.controller = controller
        }
    }

    static func panes() -> [Pane] {
        var result: [Pane] = []
        // Every terminal window, hidden tabs included: a tab that is not in
        // front is still a pane a script can name. The Quick Terminal last,
        // while it exists, shown or not.
        var controllers: [BaseTerminalController] = TerminalController.all
        if let app = NSApp.delegate as? AppDelegate, app.quickControllerInitialized {
            controllers.append(app.quickController)
        }
        for controller in controllers {
            let windowID: String, tabID: String, stableTabID: String
            if controller is QuickTerminalController {
                windowID = "quick-terminal"
                tabID = "quick-terminal"
                stableTabID = "quick-terminal"
            } else {
                guard let window = controller.window else { continue }
                windowID = "window-\(ObjectIdentifier(Tako.CustomTabGroup.group(for: window)).hexString)"
                tabID = "tab-\(ObjectIdentifier(controller).hexString)"
                stableTabID = window.stableTabIdentifier
            }
            for surface in controller.surfaceTree {
                result.append(Pane(surface: surface, windowID: windowID, tabID: tabID, stableTabID: stableTabID, controller: controller))
            }
        }
        return result
    }

    /// Resolves the window, tab, and workspace context for a surface view.
    static func surfaceContext(_ surface: Tako.SurfaceView) -> (window: String?, tab: String?, workspace: String?) {
        for pane in panes() {
            if pane.surface === surface {
                let wsName = WorkspaceStore.shared.workspace(forTab: pane.stableTabID)?.name ?? WorkspaceStore.shared.activeWorkspace.name
                return (pane.windowID, pane.tabID, wsName)
            }
        }
        return (nil, nil, WorkspaceStore.shared.activeWorkspace.name)
    }

    /// The focused pane of the front window.
    /// The pane with the keyboard: the focused pane of the key window, else
    /// of the main window, else of the frontmost terminal window. Each tab is
    /// a window of its own, so the frontmost by order is not necessarily the
    /// one being typed into.
    static func activePane(_ panes: [Pane]) -> UUID? {
        let paneIDs = Set(panes.map(\.surface.id))
        let candidates = [NSApp.keyWindow, NSApp.mainWindow] + NSApp.orderedWindows.map { Optional($0) }
        for window in candidates {
            if let controller = window?.windowController as? BaseTerminalController,
               let id = controller.focusedSurface?.id,
               paneIDs.contains(id) {
                return id
            }
        }
        return panes.first?.surface.id
    }

    /// Answers `request`, now or -- for work done off the main thread or
    /// that waits on the user -- later, exactly once.
    static func handle(_ request: ControlRequest, reply: @escaping @Sendable (ControlResponse) -> Void) {
        handle(request, all: panes(), reply: reply)
    }

    /// Binds caller to a server-side capability authorization grant (Track G1).
    /// Scopes and client identity are derived strictly from the server-side grant;
    /// caller-supplied scopes in payload can only attenuate, never expand.
    /// Unauthenticated callers or invalid tokens fail closed with no scopes.
    nonisolated static func authorize(_ request: ControlRequest) -> ControlRequest {
        var req = request
        if let token = request.token {
            if let grant = ControlGrantStore.shared.grant(for: token) {
                let client = (grant.scopes.contains(.approval) && request.client != nil) ? request.client! : grant.client
                let effectiveScopes = grant.scopes.intersection(request.requestedScopes ?? grant.scopes)
                req.client = client
                req.scopes = effectiveScopes
            } else {
                req.client = nil
                req.scopes = []
            }
        } else if req.scopes != nil && req.requestedScopes == nil {
            // In-memory test requests with explicit scopes set directly
        } else {
            // Socket caller without valid grant token
            req.client = nil
            req.scopes = []
        }
        return req
    }

    /// Checks that the client has the required capability scope for this command (Track G1).
    nonisolated static func checkScope(for request: ControlRequest) throws {
        let requiredScopes = ControlScope.required(for: request.cmd, args: request.args)
        if requiredScopes.isEmpty {
            return // unscoped discovery commands (e.g. version)
        }
        guard let clientScopes = request.scopes, !clientScopes.isEmpty else {
            let missing = requiredScopes.sorted(by: { $0.rawValue < $1.rawValue }).first!
            var err = ControlError(.missingScope, "command '\(request.cmd)' requires '\(missing.rawValue)' scope (no grant provided)")
            err.scope = missing.rawValue
            throw err
        }
        for required in requiredScopes.sorted(by: { $0.rawValue < $1.rawValue }) {
            if !clientScopes.contains(required) {
                let activeList = clientScopes.map(\.rawValue).sorted().joined(separator: ", ")
                var err = ControlError(.missingScope, "command '\(request.cmd)' requires '\(required.rawValue)' scope (client scopes: [\(activeList)])")
                err.scope = required.rawValue
                throw err
            }
        }
    }

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

    private static func sanitizeIdentifier(_ s: String, maxLen: Int = 64) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxLen else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.@"))
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return nil
        }
        return trimmed
    }

    private static func sanitizeSingleLineText(_ s: String, maxLen: Int = 256) -> String? {
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

    private static func handleGrantRequest(_ request: ControlRequest, all: [Pane], reply: @escaping @Sendable (ControlResponse) -> Void) {
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

    static func handle(_ request: ControlRequest, all: [Pane], reply: @escaping @Sendable (ControlResponse) -> Void) {
        let request = authorize(request)
        do {
            guard mode.allows(from: request.from, panes: all.map(\.surface.id)) else {
                reply(handle(request, all: all))   // the refusal, from one place
                return
            }
            try checkScope(for: request)
            if let surface = try? target(request, all) {
                if request.client?.lowercased().contains("companion") == true || request.args["companion"]?.bool == true {
                    try CompanionAccessGate.checkAccess(for: surface)
                }
            }
            switch request.cmd {
            case "grant":
                let sub = request.args["subcommand"]?.string ?? ""
                if sub == "request" {
                    handleGrantRequest(request, all: all, reply: reply)
                    return
                }
                reply(handle(request, all: all))
            case "text":
                let surface = try target(request, all)
                recordActivity(for: request, on: surface.id, action: "text")
                guard !SecureInput.shared.isSecure(for: surface) && !surface.isSecureInput else {
                    throw ControlError(.disabled, "secure-input panes cannot be read")
                }
                let lines = try ControlInput.lines(request.args)
                let styled = request.args["styled"] == .bool(true)
                let core = surface.core
                let id = surface.id.uuidString.lowercased()
                DispatchQueue.global(qos: .userInitiated).async {
                    var result = ControlInput.read(core, lines: lines, styled: styled)
                    result["id"] = .string(id)
                    reply(.ok(result))
                }
            case "screenshot":
                reply(handle(request, all: all))
            case "close":
                let surface = try target(request, all)
                recordActivity(for: request, on: surface.id, action: "close")
                ControlLayout.close(surface, reply: reply)
            case "last":
                let surface = try target(request, all)
                recordActivity(for: request, on: surface.id, action: "last")
                guard !SecureInput.shared.isSecure(for: surface) && !surface.isSecureInput else {
                    throw ControlError(.disabled, "secure-input panes cannot be read")
                }
                try ControlCommand.last(surface, args: request.args, reply: reply)
            case "wait":
                let surface = try target(request, all)
                recordActivity(for: request, on: surface.id, action: "wait")
                try ControlCommand.wait(request, surface, reply: reply)
            case "run":
                let surface = try target(request, all)
                recordActivity(for: request, on: surface.id, action: "run")
                try ControlCommand.run(request, beside: surface, reply: reply)
            case "find":
                if let surface = try? target(request, all) {
                    recordActivity(for: request, on: surface.id, action: "find")
                }
                find(try ControlInput.text(request.args), limit: try findLimit(request.args), reply: reply)
            case "notify":
                let surface = try target(request, all)
                recordActivity(for: request, on: surface.id, action: "notify")
                try notify(request, surface, text: try ControlInput.text(request.args),
                           title: request.args["title"].flatMap { if case .string(let s) = $0 { s } else { nil } },
                           reply: reply)
            case "events":
                guard request.clientFD >= 0 else {
                    throw ControlError(.internalError, "streaming requires active socket descriptor")
                }
                guard let onClose = request.onStreamClose else {
                    throw ControlError(.internalError, "missing stream close handler")
                }
                if let surface = try? target(request, all) {
                    recordActivity(for: request, on: surface.id, action: "events")
                }
                try TerminalEventHub.shared.subscribe(
                    clientFD: request.clientFD,
                    args: request.args,
                    onClose: onClose
                )
            case "ask":
                let surface = try target(request, all)
                recordActivity(for: request, on: surface.id, action: "ask")
                try PromptManager.shared.ask(request: request, surface: surface, reply: reply)
            default:
                reply(handle(request))
            }
        } catch let error as ControlError {
            reply(.failure(error))
        } catch {
            reply(.failure(ControlError(.internalError, "\(error)")))
        }
    }
    static func handle(_ request: ControlRequest) -> ControlResponse {
        handle(request, all: panes())
    }

    static func handle(_ request: ControlRequest, all: [Pane]) -> ControlResponse {
        let request = authorize(request)
        let ids = all.map(\.surface.id)
        guard mode.allows(from: request.from, panes: ids) else {
            return .failure(ControlError(.disabled, mode == .local
                ? "remote control accepts requests from inside a Tako pane (remote-control = local)"
                : "remote control is off"))
        }
        do {
            try checkScope(for: request)
            if let surface = try? target(request, all) {
                if request.client?.lowercased().contains("companion") == true || request.args["companion"]?.bool == true {
                    try CompanionAccessGate.checkAccess(for: surface)
                }
            }
            switch request.cmd {
            case "version":
                return .ok(version())
            case "tree":
                return .ok(tree(all, active: activePane(all)))
            case "history":
                let query = request.args["query"]?.string ?? ""
                let limit = try historyLimit(request.args)
                let entries = CommandHistoryStore.shared.search(query: query, limit: limit).filter { entry in
                    guard let paneId = entry.paneId else { return true }
                    if let found = all.first(where: { $0.surface.id == paneId }) {
                        return !SecureInput.shared.isSecure(for: found.surface) && !found.surface.isSecureInput
                    }
                    return true
                }
                let jsonEntries = entries.map { entry -> JSON in
                    var obj: [String: JSON] = [
                        "id": .string(entry.id.uuidString.lowercased()),
                        "command": .string(entry.command),
                        "started_at": .number(entry.startedAt.timeIntervalSince1970),
                    ]
                    if let cwd = entry.cwd { obj["cwd"] = .string(cwd) }
                    if let dur = entry.duration {
                        obj["duration"] = .number(dur)
                        obj["duration_ms"] = .number((dur * 1000.0).rounded())
                    }
                    if let exitCode = entry.exitCode {
                        obj["exit_code"] = .number(Double(exitCode))
                    }
                    if let paneId = entry.paneId {
                        obj["pane_id"] = .string(paneId.uuidString.lowercased())
                    }
                    return .object(obj)
                }
                return .ok(["entries": .array(jsonEntries)])
            case "triggers":
                return .ok(try triggersCommand(request, all: all))
            case "send", "type":
                let surface = try target(request, all)
                let client = request.client ?? request.args["client"]?.string ?? "takoctl"
                guard InputOwnershipStore.shared.canClientType(paneId: surface.id, client: client) else {
                    let state = InputOwnershipStore.shared.state(for: surface.id)
                    let creatorDesc = state.creatorClient.map { "pane was created by client '\($0)'" } ?? "pane was created by user"
                    throw ControlError(.automationNotPermitted, "automation is not permitted to type into pane \(surface.id.uuidString.lowercased()): \(creatorDesc) and 'automation may type here' is off")
                }
                let enter = request.cmd == "send" && request.args["enter"] != .bool(false)
                let text = try ControlInput.text(request.args)
                try ControlInput.send(surface, text: text, enter: enter)
                recordActivity(for: request, on: surface.id, action: request.cmd)
                return .ok(["id": .string(surface.id.uuidString.lowercased())])
            case "key":
                let surface = try target(request, all)
                let client = request.client ?? request.args["client"]?.string ?? "takoctl"
                guard InputOwnershipStore.shared.canClientType(paneId: surface.id, client: client) else {
                    let state = InputOwnershipStore.shared.state(for: surface.id)
                    let creatorDesc = state.creatorClient.map { "pane was created by client '\($0)'" } ?? "pane was created by user"
                    throw ControlError(.automationNotPermitted, "automation is not permitted to type into pane \(surface.id.uuidString.lowercased()): \(creatorDesc) and 'automation may type here' is off")
                }
                let chord = try ControlInput.text(request.args, "key")
                try ControlInput.key(surface, chord: chord)
                recordActivity(for: request, on: surface.id, action: "key")
                return .ok(["id": .string(surface.id.uuidString.lowercased())])
            case "tab-new":
                let pane = try ControlLayout.newTab(beside: try target(request, all), args: request.args, client: request.client)
                recordActivity(for: request, on: pane.id, action: "tab-new")
                return .ok(["id": .string(pane.id.uuidString.lowercased())])
            case "split":
                let pane = try ControlLayout.split(try target(request, all), args: request.args, client: request.client)
                recordActivity(for: request, on: pane.id, action: "split")
                return .ok(["id": .string(pane.id.uuidString.lowercased())])
            case "collapse":
                let surface = try target(request, all)
                recordActivity(for: request, on: surface.id, action: "collapse")
                SubagentHierarchyStore.shared.setCollapsed(surface.id, collapsed: true)
                return .ok(["id": .string(surface.id.uuidString.lowercased()), "collapsed": .bool(true)])
            case "expand":
                let surface = try target(request, all)
                recordActivity(for: request, on: surface.id, action: "expand")
                SubagentHierarchyStore.shared.setCollapsed(surface.id, collapsed: false)
                return .ok(["id": .string(surface.id.uuidString.lowercased()), "collapsed": .bool(false)])
            case "resume":
                return try handleResume(request, all: all)
            case "input":
                let surface = try target(request, all)
                recordActivity(for: request, on: surface.id, action: "input")
                let sub = try ControlInput.text(request.args, "subcommand")
                switch sub {
                case "lock":
                    let ownerName = request.args["owner"]?.string ?? "agent"
                    InputOwnershipStore.shared.lock(paneId: surface.id, by: ownerName)
                    let state = InputOwnershipStore.shared.state(for: surface.id)
                    return .ok([
                        "id": .string(surface.id.uuidString.lowercased()),
                        "locked": .bool(state.isLocked),
                        "owner": .string(state.owner.agentName ?? "agent")
                    ])
                case "unlock":
                    InputOwnershipStore.shared.unlock(paneId: surface.id)
                    let state = InputOwnershipStore.shared.state(for: surface.id)
                    return .ok([
                        "id": .string(surface.id.uuidString.lowercased()),
                        "locked": .bool(state.isLocked),
                        "owner": .string("human")
                    ])
                case "takeover":
                    InputOwnershipStore.shared.takeOver(paneId: surface.id)
                    let state = InputOwnershipStore.shared.state(for: surface.id)
                    return .ok([
                        "id": .string(surface.id.uuidString.lowercased()),
                        "locked": .bool(state.isLocked),
                        "owner": .string("human")
                    ])
                case "handback":
                    let toName = request.args["owner"]?.string
                    InputOwnershipStore.shared.handBack(paneId: surface.id, to: toName)
                    let state = InputOwnershipStore.shared.state(for: surface.id)
                    return .ok([
                        "id": .string(surface.id.uuidString.lowercased()),
                        "locked": .bool(state.isLocked),
                        "owner": .string(state.owner.agentName ?? "agent")
                    ])
                case "allow-automation", "enable-automation":
                    InputOwnershipStore.shared.setAutomationMayType(paneId: surface.id, allowed: true)
                    let state = InputOwnershipStore.shared.state(for: surface.id)
                    return .ok([
                        "id": .string(surface.id.uuidString.lowercased()),
                        "automation_may_type": .bool(state.automationMayType)
                    ])
                case "disallow-automation", "disable-automation":
                    InputOwnershipStore.shared.setAutomationMayType(paneId: surface.id, allowed: false)
                    let state = InputOwnershipStore.shared.state(for: surface.id)
                    return .ok([
                        "id": .string(surface.id.uuidString.lowercased()),
                        "automation_may_type": .bool(state.automationMayType)
                    ])
                case "confirm-automation":
                    InputOwnershipStore.shared.confirmOneTimeTyping(paneId: surface.id)
                    return .ok([
                        "id": .string(surface.id.uuidString.lowercased()),
                        "confirmed": .bool(true)
                    ])
                case "status":
                    let state = InputOwnershipStore.shared.state(for: surface.id)
                    var dict: [String: JSON] = [
                        "id": .string(surface.id.uuidString.lowercased()),
                        "locked": .bool(state.isLocked),
                        "owner": .string(state.owner.isAgent ? (state.owner.agentName ?? "agent") : "human"),
                        "automation_may_type": .bool(state.automationMayType),
                    ]
                    if let creator = state.creatorClient {
                        dict["creator_client"] = .string(creator)
                    }
                    if let mark = state.lastActivityMark {
                        dict["last_client"] = .string(mark.client)
                        dict["last_action"] = .string(mark.action)
                    }
                    return .ok(dict)
                case "log":
                    let state = InputOwnershipStore.shared.state(for: surface.id)
                    let entries: [JSON] = state.activityLog.map { record in
                        .object([
                            "client": .string(record.client),
                            "action": .string(record.action),
                            "timestamp": .string(ISO8601DateFormatter().string(from: record.timestamp))
                        ])
                    }
                    return .ok([
                        "id": .string(surface.id.uuidString.lowercased()),
                        "entries": .array(entries)
                    ])
                default:
                    throw ControlError(.invalid, "unknown input subcommand: \(sub)")
                }
            case "grant":
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
                    return .ok([
                        "token": .string(grant.token),
                        "client": .string(grant.client),
                        "scopes": .array(grant.scopes.map { .string($0.rawValue) }.sorted(by: { $0.string! < $1.string! }))
                    ])
                case "revoke":
                    guard let tokenToRevoke = request.args["token"]?.string, !tokenToRevoke.isEmpty else {
                        throw ControlError(.invalid, "missing \"token\" for grant revoke")
                    }
                    let revoked = ControlGrantStore.shared.revokeGrant(token: tokenToRevoke)
                    return .ok(["revoked": .bool(revoked)])
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
                    return .ok(["grants": .array(items)])
                default:
                    throw ControlError(.invalid, "unknown grant subcommand '\(sub)'; use request, create, revoke, or list")
                }
            case "broadcast":
                let surface = try target(request, all)
                recordActivity(for: request, on: surface.id, action: "broadcast")
                let sub = try? ControlInput.text(request.args, "subcommand")
                switch sub ?? "status" {
                case "start":
                    var targetPanes: Set<UUID> = []
                    if let panesArg = request.args["panes"]?.string {
                        let tokens = panesArg.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                        for token in tokens {
                            if let pane = all.first(where: {
                                $0.surface.id.uuidString.lowercased().hasPrefix(token.lowercased())
                            }) {
                                targetPanes.insert(pane.surface.id)
                            }
                        }
                    } else if request.args["all_splits"] == .bool(true) || request.args["panes"] == nil {
                        if let currentPane = all.first(where: { $0.surface.id == surface.id }) {
                            let tabPanes = all.filter { $0.tabID == currentPane.tabID }
                            for p in tabPanes {
                                targetPanes.insert(p.surface.id)
                            }
                        }
                    }
                    targetPanes.insert(surface.id)
                    guard targetPanes.count >= 2 else {
                        throw ControlError(.invalid, "broadcast requires at least 2 panes in selection")
                    }
                    let started = BroadcastInputStore.shared.startBroadcast(panes: targetPanes, leader: surface.id)
                    let session = BroadcastInputStore.shared.activeSession
                    let paneArray: [JSON] = (session?.selectedPaneIds ?? []).map { .string($0.uuidString.lowercased()) }
                    return .ok([
                        "active": .bool(started),
                        "leader": .string(surface.id.uuidString.lowercased()),
                        "count": .number(Double(paneArray.count)),
                        "panes": .array(paneArray)
                    ])
                case "stop":
                    BroadcastInputStore.shared.endBroadcast()
                    return .ok([
                        "active": .bool(false)
                    ])
                case "status":
                    let session = BroadcastInputStore.shared.activeSession
                    let active = session != nil
                    let paneArray: [JSON] = (session?.selectedPaneIds ?? []).map { .string($0.uuidString.lowercased()) }
                    var dict: [String: JSON] = [
                        "active": .bool(active),
                        "count": .number(Double(paneArray.count)),
                        "panes": .array(paneArray)
                    ]
                    if let leader = session?.leaderPaneId {
                        dict["leader"] = .string(leader.uuidString.lowercased())
                    }
                    return .ok(dict)
                default:
                    throw ControlError(.invalid, "unknown broadcast subcommand: \(sub ?? "")")
                }
            case "focus":
                let surface = try target(request, all)
                recordActivity(for: request, on: surface.id, action: "focus")
                ControlLayout.focus(surface)
                return .ok(["id": .string(surface.id.uuidString.lowercased())])
            case "title":
                let surface = try target(request, all)
                recordActivity(for: request, on: surface.id, action: "title")
                try ControlLayout.title(surface, try ControlInput.text(request.args, "title"))
                return .ok(["id": .string(surface.id.uuidString.lowercased())])
            case "status":
                let surface = try target(request, all)
                recordActivity(for: request, on: surface.id, action: "status")
                let action: String = try {
                    if let a = request.args["action"] {
                        if case .string(let s) = a { return s }
                        throw ControlError(.invalid, "\"action\" must be a string")
                    }
                    return "get"
                }()
                switch action {
                case "get":
                    var dict: [String: JSON] = [
                        "id": .string(surface.id.uuidString.lowercased()),
                        "status": .string(surface.crab.paneStatus.rawValue),
                        "unread": .bool(surface.crab.unread),
                    ]
                    if let text = surface.crab.statusText {
                        dict["text"] = .string(text)
                    }
                    if let ttl = surface.crab.remainingTTL {
                        dict["ttl"] = .number(ttl)
                    }
                    return .ok(dict)
                case "set":
                    let statusStr: String = try {
                        guard let s = request.args["status"], case .string(let str) = s else {
                            throw ControlError(.invalid, "missing or invalid \"status\" argument")
                        }
                        return str
                    }()
                    guard let parsed = Tako.PaneStatus.parse(statusStr) else {
                        throw ControlError(.invalid, "invalid status \"\(statusStr)\"")
                    }
                    let text: String? = {
                        if let t = request.args["text"], case .string(let str) = t { return str }
                        return nil
                    }()
                    let ttl: TimeInterval? = {
                        if let ttlVal = request.args["ttl"] {
                            if case .number(let n) = ttlVal, n > 0 { return n }
                        }
                        return nil
                    }()
                    surface.setStatus(parsed.rawValue, text: text, ttl: ttl)
                    var dict: [String: JSON] = [
                        "id": .string(surface.id.uuidString.lowercased()),
                        "status": .string(surface.crab.paneStatus.rawValue),
                        "unread": .bool(surface.crab.unread),
                    ]
                    if let t = surface.crab.statusText { dict["text"] = .string(t) }
                    if let rem = surface.crab.remainingTTL { dict["ttl"] = .number(rem) }
                    return .ok(dict)
                case "clear":
                    surface.clearStatus()
                    return .ok([
                        "id": .string(surface.id.uuidString.lowercased()),
                        "status": .string(surface.crab.paneStatus.rawValue),
                        "unread": .bool(surface.crab.unread),
                    ])
                default:
                    throw ControlError(.invalid, "unknown status action \"\(action)\"")
                }
            case "progress":
                let surface = try target(request, all)
                recordActivity(for: request, on: surface.id, action: "progress")
                let action: String = try {
                    if let a = request.args["action"] {
                        if case .string(let s) = a { return s.lowercased() }
                        throw ControlError(.invalid, "\"action\" must be a string")
                    }
                    if let s = request.args["state"] {
                        if case .string(let str) = s { return str.lowercased() }
                    }
                    return "get"
                }()

                let parsedNumber: UInt8? = {
                    if let num = UInt8(action), (0...100).contains(num) {
                        return num
                    }
                    if let v = request.args["value"] ?? request.args["progress"] {
                        if case .number(let n) = v, n >= 0, n <= 100 { return UInt8(n) }
                    }
                    return nil
                }()

                let effectiveAction = parsedNumber != nil && action != "error" && action != "pause" && action != "paused" ? "set" : action

                switch effectiveAction {
                case "get":
                    var dict: [String: JSON] = [
                        "id": .string(surface.id.uuidString.lowercased()),
                        "state": .string(surface.crab.progressState.rawValue),
                    ]
                    if let p = surface.crab.progress {
                        dict["progress"] = .number(Double(p))
                    }
                    return .ok(dict)

                case "set", "normal":
                    let val = parsedNumber
                    surface.crab.progressReported(state: 1, value: val)
                    surface.progressReport = .init(state: .set, progress: val)
                    surface.updateProgressBar(state: surface.crab.progressState, progress: surface.crab.progress)
                    (NSApp.delegate as? AppDelegate)?.setDockBadge()
                    Tako.TabBarController.refreshAll()
                    var dict: [String: JSON] = [
                        "id": .string(surface.id.uuidString.lowercased()),
                        "state": .string(surface.crab.progressState.rawValue),
                    ]
                    if let p = surface.crab.progress { dict["progress"] = .number(Double(p)) }
                    return .ok(dict)

                case "error":
                    let val = parsedNumber
                    surface.crab.progressReported(state: 2, value: val)
                    surface.progressReport = .init(state: .error, progress: val)
                    surface.updateProgressBar(state: surface.crab.progressState, progress: surface.crab.progress)
                    (NSApp.delegate as? AppDelegate)?.setDockBadge()
                    Tako.TabBarController.refreshAll()
                    var dict: [String: JSON] = [
                        "id": .string(surface.id.uuidString.lowercased()),
                        "state": .string(surface.crab.progressState.rawValue),
                    ]
                    if let p = surface.crab.progress { dict["progress"] = .number(Double(p)) }
                    return .ok(dict)

                case "indeterminate":
                    surface.crab.progressReported(state: 3, value: nil)
                    surface.progressReport = .init(state: .indeterminate, progress: nil)
                    surface.updateProgressBar(state: surface.crab.progressState, progress: nil)
                    (NSApp.delegate as? AppDelegate)?.setDockBadge()
                    Tako.TabBarController.refreshAll()
                    return .ok([
                        "id": .string(surface.id.uuidString.lowercased()),
                        "state": .string("indeterminate"),
                    ])

                case "pause", "paused":
                    let val = parsedNumber
                    surface.crab.progressReported(state: 4, value: val)
                    surface.progressReport = .init(state: .pause, progress: val)
                    surface.updateProgressBar(state: surface.crab.progressState, progress: surface.crab.progress)
                    (NSApp.delegate as? AppDelegate)?.setDockBadge()
                    Tako.TabBarController.refreshAll()
                    var dict: [String: JSON] = [
                        "id": .string(surface.id.uuidString.lowercased()),
                        "state": .string(surface.crab.progressState.rawValue),
                    ]
                    if let p = surface.crab.progress { dict["progress"] = .number(Double(p)) }
                    return .ok(dict)

                case "clear", "none", "reset":
                    surface.progressReport = nil
                    surface.crab.progressReported(state: 0, value: nil)
                    surface.updateProgressBar(state: .none, progress: nil)
                    (NSApp.delegate as? AppDelegate)?.setDockBadge()
                    Tako.TabBarController.refreshAll()
                    return .ok([
                        "id": .string(surface.id.uuidString.lowercased()),
                        "state": .string("none"),
                    ])

                default:
                    throw ControlError(.invalid, "unknown progress action \"\(action)\"")
                }
            case "dialog":
                if let surface = try? target(request, all) {
                    recordActivity(for: request, on: surface.id, action: "dialog")
                }
                return .ok(try dialog(request.args))
            case "activity":
                let surface = try target(request, all)
                guard !SecureInput.shared.isSecure(for: surface) && !surface.isSecureInput else {
                    throw ControlError(.disabled, "secure-input panes cannot be read")
                }
                let act = request.args["action"]?.string ?? request.args["subcommand"]?.string ?? "get"
                switch act {
                case "get", "list":
                    recordActivity(for: request, on: surface.id, action: "activity")
                    let records = InputOwnershipStore.shared.activityLog(for: surface.id)
                    let entries: [JSON] = records.map { record in
                        .object([
                            "client": .string(record.client),
                            "action": .string(record.action),
                            "timestamp": .string(ISO8601DateFormatter().string(from: record.timestamp))
                        ])
                    }
                    var dict: [String: JSON] = [
                        "id": .string(surface.id.uuidString.lowercased()),
                        "count": .number(Double(entries.count)),
                        "entries": .array(entries)
                    ]
                    if let lastCleared = InputOwnershipStore.shared.lastCleared(for: surface.id) {
                        dict["last_cleared"] = .object([
                            "client": .string(lastCleared.client),
                            "action": .string(lastCleared.action),
                            "timestamp": .string(ISO8601DateFormatter().string(from: lastCleared.timestamp))
                        ])
                    }
                    if let exportPath = request.args["export"]?.string ?? request.args["file"]?.string {
                        let jsonString = InputOwnershipStore.shared.exportLog(for: surface.id)
                        let expanded = (exportPath as NSString).expandingTildeInPath
                        try jsonString.write(toFile: expanded, atomically: true, encoding: .utf8)
                        dict["exported"] = .string(expanded)
                    }
                    return .ok(dict)
                case "clear":
                    let client = request.client ?? "control"
                    InputOwnershipStore.shared.clearLog(paneId: surface.id, by: client)
                    var dict: [String: JSON] = [
                        "id": .string(surface.id.uuidString.lowercased()),
                        "cleared": .bool(true)
                    ]
                    if let lastCleared = InputOwnershipStore.shared.lastCleared(for: surface.id) {
                        dict["last_cleared"] = .object([
                            "client": .string(lastCleared.client),
                            "action": .string(lastCleared.action),
                            "timestamp": .string(ISO8601DateFormatter().string(from: lastCleared.timestamp))
                        ])
                    }
                    return .ok(dict)
                case "export":
                    let jsonString = InputOwnershipStore.shared.exportLog(for: surface.id)
                    var dict: [String: JSON] = [
                        "id": .string(surface.id.uuidString.lowercased()),
                        "json": .string(jsonString)
                    ]
                    if let exportPath = request.args["export"]?.string ?? request.args["file"]?.string ?? request.args["path"]?.string {
                        let expanded = (exportPath as NSString).expandingTildeInPath
                        try jsonString.write(toFile: expanded, atomically: true, encoding: .utf8)
                        dict["exported"] = .string(expanded)
                    }
                    return .ok(dict)
                default:
                    throw ControlError(.invalid, "unknown activity action \"\(act)\"; use get, export, or clear")
                }
            case "workspace":
                return .ok(try workspaceCommand(request, all: all))
            case "layout":
                return .ok(try layoutCommand(request, all: all))
            case "action":
                return .ok(try actionCommand(request, all: all))
            case "task":
                return .ok(try taskCommand(request, all: all))
            case "session":
                return .ok(try sessionCommand(request, all: all))
            case "overlay":
                return .ok(try overlayCommand(request, all: all))
            case "review":
                return .ok(try reviewCommand(request, all: all))
            case "screenshot":
                return .ok(try screenshotCommand(request, all: all))
            case "text", "close", "last", "wait", "run", "find", "notify", "events":
                throw ControlError(.internalError, "\(request.cmd) is answered asynchronously")
            default:
                throw ControlError(.invalid, "unknown command \"\(request.cmd)\"")
            }
        } catch let error as ControlError {
            return .failure(error)
        } catch {
            return .failure(ControlError(.internalError, "\(error)"))
        }
    }

    /// `takoctl find`: the Find in All Tabs search -- every terminal window's
    /// panes, newest match first in each, bounded the same way -- with the
    /// command that printed each match where the shell marked one.
    /// `limit` for find: a whole number from 1 to the panel's own limit.
    static func findLimit(_ args: [String: JSON]) throws -> Int {
        let refused = ControlError(.invalid, "\"limit\" must be a whole number from 1 to \(CrossSessionSearch.limit)")
        switch args["limit"] {
        case nil, .null?: return 50
        case .number(let n)?:
            guard n.isFinite, let limit = Int(exactly: n), (1...CrossSessionSearch.limit).contains(limit) else {
                throw refused
            }
            return limit
        default:
            throw refused
        }
    }

    /// `takoctl history`: the cross-session command history search.
    /// `limit` for history: a whole number from 0 to 5000 (default 100).
    static func historyLimit(_ args: [String: JSON]) throws -> Int {
        let refused = ControlError(.invalid, "\"limit\" must be a whole number from 0 to 5000")
        switch args["limit"] {
        case nil, .null?: return 100
        case .number(let n)?:
            guard n.isFinite, let limit = Int(exactly: n), (0...5000).contains(limit) else {
                throw refused
            }
            return limit
        default:
            throw refused
        }
    }

    static func find(_ needle: String, limit cap: Int, reply: @escaping @Sendable (ControlResponse) -> Void) {
        guard !needle.isEmpty else { return reply(.failure(ControlError(.invalid, "nothing to find"))) }
        let targets = CrossSessionSearch.openTerminals()
        Task.detached(priority: .userInitiated) {
            guard let found = await CrossSessionSearch.search(needle, in: targets) else {
                return reply(.failure(ControlError(.internalError, "search cancelled")))
            }
            let matches: [JSON] = found.results.prefix(cap).map { result in
                var match: [String: JSON] = [
                    "id": .string(result.surfaceID.uuidString.lowercased()),
                    "place": .string(result.place),
                    "pane": result.pane.map(JSON.string) ?? .null,
                    "line": .string(result.hit.before + result.hit.matched + result.hit.after),
                    "matched": .string(result.hit.matched),
                ]
                if let heading = result.command {
                    match["command"] = .object([
                        "input": heading.commandLine.map(JSON.string) ?? .null,
                        "status": .string(heading.outcomeText),
                        "cwd": heading.directory.map(JSON.string) ?? .null,
                    ])
                }
                return .object(match)
            }
            reply(.ok(["matches": .array(matches), "more": .bool(found.more || found.results.count > cap)]))
        }
    }

    /// `takoctl dialog`: the questions Tako has up in its windows. With
    /// `press`, answers the only one by pressing that button -- allowed only
    /// with `remote-control = on`: a confirmation a script in a pane could
    /// answer itself would not protect anything.
    static func dialog(_ args: [String: JSON]) throws -> [String: JSON] {
        let open: [(window: String, view: TerminalDialogView)] = TerminalController.all.compactMap { controller in
            guard let window = controller.window, let view = TerminalDialogView.pending(in: window) else { return nil }
            return ("window-\(ObjectIdentifier(Tako.CustomTabGroup.group(for: window)).hexString)", view)
        }
        guard case .string(let label)? = args["press"] else {
            return ["dialogs": .array(open.map { item in
                var summary = item.view.summary
                summary["window"] = .string(item.window)
                return .object(summary)
            })]
        }
        guard mode == .on else {
            throw ControlError(.disabled, "answering a question needs remote-control = on")
        }
        guard let only = open.first, open.count == 1 else {
            throw ControlError(open.isEmpty ? .notFound : .ambiguous,
                               open.isEmpty ? "no question is up" : "\(open.count) questions are up")
        }
        let summary = only.view.summary
        guard only.view.press(label) else {
            throw ControlError(.invalid, "no button \"\(label)\"; there are: \(summary["buttons"].map { "\($0.any)" } ?? "")")
        }
        TerminalEventHub.shared.publish(
            type: "ask_answered",
            window: only.window,
            payload: [
                "answer": .string(label),
                "title": summary["title"] ?? .null
            ]
        )
        return ["pressed": .string(label), "title": summary["title"] ?? .null]
    }

    /// `takoctl notify`: a system notification about `surface` -- titled
    /// `title`, or the tab's title -- that brings the pane forward when
    /// clicked, shown even while Tako is in front.
    /// Answered once the notification is with the system -- or with why it
    /// is not: notifications not allowed for Tako, or not accepted.
    /// How long `notify` waits for the system -- a first-time permission
    /// prompt may sit unanswered -- before it answers `timeout`: inside
    /// takoctl's own 30 s, so the client always hears why.
    static let notifyWait: TimeInterval = 20

    static func notify(_ request: ControlRequest, _ surface: Tako.SurfaceView, text: String, title: String?,
                       reply: @escaping @Sendable (ControlResponse) -> Void) throws {
        guard !text.isEmpty else { throw ControlError(.invalid, "nothing to say") }
        let content = UNMutableNotificationContent()
        let tabTitle = surface.window?.windowController.flatMap { ($0 as? BaseTerminalController)?.titleOverride }
            ?? surface.window?.title
        content.title = title ?? tabTitle.flatMap { $0.isEmpty ? nil : $0 } ?? "Tako"
        content.body = text
        content.userInfo = [Tako.notificationSurfaceKey: surface.id.uuidString,
                            Tako.notificationFromControlKey: true]
        guard let center = AppDelegate.notificationCenterProvider() else {
            throw ControlError(.internalError, "notifications are unavailable")
        }
        let id = surface.id.uuidString.lowercased()
        // One answer, whichever comes first: the system, the deadline, or
        // the client going away. After that nothing is posted.
        let once = OnceReply(reply)
        let deadline = Date().addingTimeInterval(notifyWait)
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { timer in
            // Cancels only while the system has not been asked to post; once
            // it has, its own answer comes.
            if once.done {
                timer.invalidate()
            } else if request.clientGone() {
                if once.cancel(.failure(ControlError(.timeout, "the client went away"))) { timer.invalidate() }
            } else if Date() >= deadline {
                if once.cancel(.failure(ControlError(.timeout,
                    "no answer from the system in \(Int(notifyWait)) s -- is a notification permission prompt waiting?"))) {
                    timer.invalidate()
                }
            }
        }
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            // Cancelled already: nothing is posted.
            guard once.claim() else { return }
            guard granted else {
                return once.answer(.failure(ControlError(.disabled,
                    "notifications are not allowed for Tako (System Settings → Notifications)"
                        + (error.map { ": \($0.localizedDescription)" } ?? ""))))
            }
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
                if let error {
                    once.answer(.failure(ControlError(.internalError, "not posted: \(error.localizedDescription)")))
                } else {
                    surface.publishEvent(
                        type: "notification",
                        payload: [
                            "title": .string(content.title),
                            "body": .string(text),
                            "action": .string("posted")
                        ]
                    )
                    once.answer(.ok(["id": .string(id)]))
                }
            }
        }
    }

    /// A reply that goes out at most once, and an action it guards: while
    /// `pending`, the deadline or a departed client may `cancel` it; once
    /// the action has `claim`ed it, only the action answers -- so nothing is
    /// done after a cancel, and nothing done is reported as cancelled.
    final class OnceReply: @unchecked Sendable {
        enum State { case pending, acting, answered }
        private let lock = NSLock()
        private var state = State.pending
        private let reply: @Sendable (ControlResponse) -> Void
        init(_ reply: @escaping @Sendable (ControlResponse) -> Void) { self.reply = reply }
        var done: Bool { lock.withLock { state == .answered } }

        /// Takes the right to act; false when already cancelled or answered.
        func claim() -> Bool {
            lock.withLock {
                guard state == .pending else { return false }
                state = .acting
                return true
            }
        }

        /// Answers only if nothing has started: false otherwise.
        @discardableResult
        func cancel(_ response: ControlResponse) -> Bool {
            let won = lock.withLock { () -> Bool in
                guard state == .pending else { return false }
                state = .answered
                return true
            }
            if won { reply(response) }
            return won
        }

        /// The answer from whoever holds the right to act, or from a
        /// pending one; once.
        func answer(_ response: ControlResponse) {
            let first = lock.withLock { () -> Bool in
                guard state != .answered else { return false }
                state = .answered
                return true
            }
            if first { reply(response) }
        }
    }

    /// The one pane a request means, decided now -- `active` included.
    static func target(_ request: ControlRequest, _ all: [Pane]) throws -> Tako.SurfaceView {
        let id = try ControlTarget.from(request.args, requestFrom: request.from)
            .resolve(panes: all.map(\.surface.id), requestFrom: request.from, active: activePane(all))
        guard let pane = all.first(where: { $0.surface.id == id }) else {
            throw ControlError(.notFound, "no pane \(id.uuidString.lowercased())")
        }
        return pane.surface
    }

    static func version() -> [String: JSON] {
        let info = Bundle.main.infoDictionary ?? [:]
        return [
            "app": .string("Tako"),
            "version": .string(info["CFBundleShortVersionString"] as? String ?? ""),
            "build": .string(info["CFBundleVersion"] as? String ?? ""),
            "protocol": .number(Double(ControlProtocol.version)),
        ]
    }

    /// Windows, their tabs, and the panes in each. What the shell reported
    /// and nothing guessed: `cwd` is the last OSC 7 directory; `pid` and
    /// `tty` are the pane's own process, and null when that process is the
    /// client of a persistent session rather than the shell.
    static func tree(_ panes: [Pane], active: UUID?) -> [String: JSON] {
        var windows: [(id: String, tabs: [(id: String, panes: [JSON])])] = []
        var tabInfo: [String: [String: JSON]] = [:]
        for pane in panes {
            let surface = pane.surface
            let persistent = surface.persistence != nil
            var node: [String: JSON] = [
                "id": .string(surface.id.uuidString.lowercased()),
                "title": .string(surface.title),
                "cwd": surface.pwd.map(JSON.string) ?? .null,
                "focused": .bool(surface.id == active),
                "status": .string(surface.crab.paneStatus.rawValue),
                "unread": .bool(surface.crab.unread),
                "alternateScreen": .bool(surface.isAlternateScreen),
                "persistentSession": .bool(persistent),
                "exited": .bool(surface.processExited),
            ]
            if let text = surface.crab.statusText {
                node["statusText"] = .string(text)
            }
            if let ttl = surface.crab.remainingTTL {
                node["statusTTL"] = .number(ttl)
            }
            if let parent = SubagentHierarchyStore.shared.parent(of: surface.id) {
                node["parent"] = .string(parent.uuidString.lowercased())
            }
            if let label = SubagentHierarchyStore.shared.label(for: surface.id) {
                node["label"] = .string(label)
            }
            if SubagentHierarchyStore.shared.hasChildren(surface.id) {
                let children = SubagentHierarchyStore.shared.children(of: surface.id)
                node["children"] = .array(children.map { .string($0.uuidString.lowercased()) })
                if let summary = SubagentHierarchyStore.shared.statusSummary(for: surface.id) {
                    node["childrenStatus"] = .string(summary)
                }
                node["collapsed"] = .bool(SubagentHierarchyStore.shared.isCollapsed(surface.id))
            }
            if persistent {
                node["pid"] = .null
                node["tty"] = .null
            } else {
                node["pid"] = surface.surfaceModel?.foregroundPID.map { .number(Double($0)) } ?? .null
                node["tty"] = surface.surfaceModel?.ttyName.map(JSON.string) ?? .null
            }
            // Grouped by id, in the order first seen: tabs of one window
            // need not come one after another.
            let w = windows.firstIndex { $0.id == pane.windowID } ?? {
                windows.append((pane.windowID, []))
                return windows.count - 1
            }()
            let t = windows[w].tabs.firstIndex { $0.id == pane.tabID } ?? {
                windows[w].tabs.append((pane.tabID, []))
                if let controller = pane.controller {
                    tabInfo[pane.tabID] = tabFacts(controller)
                }
                return windows[w].tabs.count - 1
            }()
            windows[w].tabs[t].panes.append(.object(node))
        }
        return ["windows": .array(windows.map { window in
            // Tabs in the order the tab bar shows them.
            let tabs = window.tabs.sorted {
                (tabInfo[$0.id]?["index"]?.number ?? 0) < (tabInfo[$1.id]?["index"]?.number ?? 0)
            }
            return .object([
                "id": .string(window.id),
                "tabs": .array(tabs.map { tab in
                    var node = tabInfo[tab.id] ?? [:]
                    node["id"] = .string(tab.id)
                    node["panes"] = .array(tab.panes)
                    return .object(node)
                }),
            ])
        })]
    }

    /// What a tab adds to its panes: its place in the tab bar (from 1), its
    /// title, whether it is the one shown, and how its panes are split --
    /// `{"pane": id}` or `{"split": "right"|"down", "ratio", "children": [a, b]}`.
    static func tabFacts(_ controller: BaseTerminalController) -> [String: JSON] {
        var facts: [String: JSON] = ["layout": controller.surfaceTree.root.map(layout) ?? .null]
        if let window = controller.window, !(controller is QuickTerminalController) {
            let group = Tako.CustomTabGroup.group(for: window)
            facts["index"] = .number(Double((group.windows.firstIndex { $0 === window } ?? 0) + 1))
            facts["selected"] = .bool(group.selectedWindow === window || group.windows.count <= 1)
            facts["title"] = .string(controller.titleOverride ?? window.title)
            let ws = WorkspaceStore.shared.workspace(forTab: window.stableTabIdentifier) ?? WorkspaceStore.shared.activeWorkspace
            facts["workspace"] = .string(ws.name)
        }
        return facts
    }

    /// `takoctl workspace`: manage project workspaces (C1).
    static func workspaceCommand(_ request: ControlRequest, all: [Pane]) throws -> [String: JSON] {
        let action = request.args["action"]?.string ?? "list"
        switch action {
        case "list":
            let list: [JSON] = WorkspaceStore.shared.workspaces.map { ws in
                var dict: [String: JSON] = [
                    "id": .string(ws.id.uuidString.lowercased()),
                    "name": .string(ws.name),
                    "tabs": .array(ws.tabIdentifiers.map { .string($0) }),
                    "is_active": .bool(ws.id == WorkspaceStore.shared.activeWorkspaceId),
                    "attention_count": .number(Double(WorkspaceStore.shared.attentionCount(for: ws))),
                ]
                if let root = ws.rootDirectory { dict["root_directory"] = .string(root) }
                if let color = ws.color { dict["color"] = .string(color) }
                if let icon = ws.icon { dict["icon"] = .string(icon) }
                if let activeTab = ws.activeTabIdentifier { dict["active_tab"] = .string(activeTab) }
                return .object(dict)
            }
            return ["workspaces": .array(list)]

        case "current":
            let ws = WorkspaceStore.shared.activeWorkspace
            var dict: [String: JSON] = [
                "id": .string(ws.id.uuidString.lowercased()),
                "name": .string(ws.name),
                "tabs": .array(ws.tabIdentifiers.map { .string($0) }),
                "is_active": .bool(true),
                "attention_count": .number(Double(WorkspaceStore.shared.attentionCount(for: ws))),
            ]
            if let root = ws.rootDirectory { dict["root_directory"] = .string(root) }
            if let color = ws.color { dict["color"] = .string(color) }
            if let icon = ws.icon { dict["icon"] = .string(icon) }
            if let activeTab = ws.activeTabIdentifier { dict["active_tab"] = .string(activeTab) }
            return dict

        case "switch":
            guard let nameOrId = request.args["name"]?.string, !nameOrId.isEmpty else {
                throw ControlError(.invalid, "workspace name or ID required")
            }
            let switched = WorkspaceStore.shared.switchWorkspace(named: nameOrId) ||
                (UUID(uuidString: nameOrId).map { WorkspaceStore.shared.switchWorkspace(to: $0) } ?? false)
            guard switched else {
                throw ControlError(.notFound, "workspace not found: \(nameOrId)")
            }
            let ws = WorkspaceStore.shared.activeWorkspace
            return [
                "id": .string(ws.id.uuidString.lowercased()),
                "name": .string(ws.name),
                "is_active": .bool(true),
            ]

        case "create":
            guard let name = request.args["name"]?.string, !name.isEmpty else {
                throw ControlError(.invalid, "workspace name required")
            }
            let root = request.args["root"]?.string
            let color = request.args["color"]?.string
            let icon = request.args["icon"]?.string
            let ws = WorkspaceStore.shared.createWorkspace(name: name, rootDirectory: root, color: color, icon: icon)
            var dict: [String: JSON] = [
                "id": .string(ws.id.uuidString.lowercased()),
                "name": .string(ws.name),
            ]
            if let r = ws.rootDirectory { dict["root_directory"] = .string(r) }
            if let c = ws.color { dict["color"] = .string(c) }
            if let i = ws.icon { dict["icon"] = .string(i) }
            return dict

        case "delete":
            guard let nameOrId = request.args["name"]?.string, !nameOrId.isEmpty else {
                throw ControlError(.invalid, "workspace name or ID required")
            }
            let targetWs = WorkspaceStore.shared.workspace(named: nameOrId)
                ?? UUID(uuidString: nameOrId).flatMap { WorkspaceStore.shared.workspace(for: $0) }
            guard let target = targetWs else {
                throw ControlError(.notFound, "workspace not found: \(nameOrId)")
            }
            guard target.id != WorkspaceStore.defaultWorkspaceId else {
                throw ControlError(.invalid, "cannot delete default workspace")
            }
            guard WorkspaceStore.shared.deleteWorkspace(id: target.id) else {
                throw ControlError(.invalid, "failed to delete workspace")
            }
            return ["deleted": .string(target.name)]

        case "assign":
            guard let wsIdentifier = request.args["workspace"]?.string, !wsIdentifier.isEmpty else {
                throw ControlError(.invalid, "workspace name or ID required")
            }
            let targetWs = WorkspaceStore.shared.workspace(named: wsIdentifier)
                ?? UUID(uuidString: wsIdentifier).flatMap { WorkspaceStore.shared.workspace(for: $0) }
            guard let targetWorkspace = targetWs else {
                throw ControlError(.notFound, "workspace not found: \(wsIdentifier)")
            }
            let tabId: String
            if let directTab = request.args["tab"]?.string, !directTab.isEmpty {
                if let matchedPane = all.first(where: { $0.tabID == directTab || $0.stableTabID == directTab }) {
                    tabId = matchedPane.stableTabID
                } else {
                    tabId = directTab
                }
            } else {
                let surface = try Self.target(request, all)
                guard let matchedPane = all.first(where: { $0.surface === surface }) else {
                    throw ControlError(.notFound, "cannot determine tab for pane")
                }
                tabId = matchedPane.stableTabID
            }
            WorkspaceStore.shared.assignTab(tabIdentifier: tabId, to: targetWorkspace.id)
            return [
                "tab": .string(tabId),
                "workspace": .string(targetWorkspace.name),
            ]

        default:
            throw ControlError(.invalid, "unknown workspace action: \(action)")
        }
    }

    static func layoutCommand(_ request: ControlRequest, all: [Pane]) throws -> [String: JSON] {
        let action: String = try {
            if let a = request.args["action"], case .string(let str) = a { return str }
            if let a = request.args["subcommand"], case .string(let str) = a { return str }
            throw ControlError(.invalid, "layout command requires an action (save, apply, approve, status)")
        }()

        switch action {
        case "save":
            let window: NSWindow? = {
                if let surface = try? target(request, all) {
                    if let win = surface.window { return win }
                    if let matched = all.first(where: { $0.surface === surface }), let win = matched.controller?.window {
                        return win
                    }
                }
                if let key = NSApp.keyWindow ?? NSApp.mainWindow { return key }
                if let first = all.first(where: { $0.controller?.window != nil })?.controller?.window {
                    return first
                }
                return TerminalController.all.first?.window
            }()
            guard let window else {
                throw ControlError(.notFound, "no window found to save layout")
            }
            let doc = try LayoutManager.capture(window: window)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(doc)
            let jsonString = String(decoding: data, as: UTF8.self)

            if let path = request.args["path"]?.string, !path.isEmpty {
                let expanded = (path as NSString).expandingTildeInPath
                try data.write(to: URL(fileURLWithPath: expanded), options: .atomic)
            }

            let tabsCount = doc.windows.reduce(0) { $0 + $1.tabs.count }
            let panesCount = doc.allPanes.count
            return [
                "saved": .bool(true),
                "path": request.args["path"] ?? .null,
                "tabs": .number(Double(tabsCount)),
                "panes": .number(Double(panesCount)),
                "content": .string(jsonString)
            ]

        case "apply":
            let rawContent: String
            let filePath: String?
            if let content = request.args["content"]?.string, !content.isEmpty {
                rawContent = content
                filePath = request.args["path"]?.string
            } else if let path = request.args["path"]?.string, !path.isEmpty {
                let expanded = (path as NSString).expandingTildeInPath
                guard FileManager.default.fileExists(atPath: expanded) else {
                    throw ControlError(.notFound, "layout file not found: \(path)")
                }
                rawContent = try String(contentsOfFile: expanded, encoding: .utf8)
                filePath = path
            } else {
                throw ControlError(.invalid, "layout apply requires 'path' or 'content'")
            }

            guard let data = rawContent.data(using: .utf8) else {
                throw ControlError(.invalid, "invalid UTF-8 content in layout")
            }
            let doc = try JSONDecoder().decode(LayoutDocument.self, from: data)

            // Trust evaluation
            let isTrusted: Bool
            if !doc.hasPrograms {
                isTrusted = true
            } else if request.args["approve"] == .bool(true) {
                if let filePath {
                    LayoutTrustStore.shared.trust(path: filePath, content: rawContent)
                }
                isTrusted = true
            } else if let filePath, LayoutTrustStore.shared.isTrusted(path: filePath, content: rawContent) {
                isTrusted = true
            } else {
                if request.args["allow_unapproved"] == .bool(true) {
                    isTrusted = false
                } else {
                    throw ControlError(.disabled, "unapproved layout contains executable programs: approval required (use --approve or takoctl layout approve)")
                }
            }

            let takoApp = all.first?.controller?.tako ?? (NSApp.delegate as? AppDelegate)?.tako
            let result = try LayoutManager.apply(document: doc, isTrusted: isTrusted, app: takoApp)
            return [
                "applied": .bool(true),
                "path": filePath.map(JSON.string) ?? .null,
                "windows": .number(Double(result.windowsCreated)),
                "tabs": .number(Double(result.tabsCreated)),
                "panes": .number(Double(result.panesCreated)),
                "programs_started": .number(Double(result.programsStarted)),
                "programs_suppressed": .number(Double(result.programsSuppressed)),
                "trusted": .bool(result.isTrusted)
            ]

        case "approve":
            guard let path = request.args["path"]?.string, !path.isEmpty else {
                throw ControlError(.invalid, "layout approve requires 'path'")
            }
            let expanded = (path as NSString).expandingTildeInPath
            let content: String = try {
                if let c = request.args["content"]?.string, !c.isEmpty { return c }
                return try String(contentsOfFile: expanded, encoding: .utf8)
            }()
            LayoutTrustStore.shared.trust(path: expanded, content: content)
            let hash = LayoutTrustStore.sha256(for: content)
            return [
                "approved": .bool(true),
                "path": .string(LayoutTrustStore.canonicalPath(expanded)),
                "sha256": .string(hash)
            ]

        case "status":
            guard let path = request.args["path"]?.string, !path.isEmpty else {
                throw ControlError(.invalid, "layout status requires 'path'")
            }
            let expanded = (path as NSString).expandingTildeInPath
            let content: String = try {
                if let c = request.args["content"]?.string, !c.isEmpty { return c }
                return try String(contentsOfFile: expanded, encoding: .utf8)
            }()
            let status = LayoutTrustStore.shared.status(path: expanded, content: content)
            let hash = LayoutTrustStore.sha256(for: content)
            let hasPrograms = (try? JSONDecoder().decode(LayoutDocument.self, from: Data(content.utf8)))?.hasPrograms ?? false
            return [
                "path": .string(LayoutTrustStore.canonicalPath(expanded)),
                "status": .string(status.description),
                "trusted": .bool(status.isTrusted),
                "sha256": .string(hash),
                "has_programs": .bool(hasPrograms)
            ]

        default:
            throw ControlError(.invalid, "unknown layout action: \(action)")
        }
    }

    static func actionCommand(_ request: ControlRequest, all: [Pane]) throws -> [String: JSON] {
        let action: String = try {
            if let a = request.args["action"], case .string(let str) = a { return str }
            if let a = request.args["subcommand"], case .string(let str) = a { return str }
            throw ControlError(.invalid, "action command requires a subcommand (list, run, approve, status)")
        }()

        let surface: Tako.SurfaceView? = (try? target(request, all)) ?? all.first?.surface

        let project: ProjectActionDiscovery.DiscoveredProject? = {
            if let path = request.args["path"]?.string, !path.isEmpty {
                return ProjectActionDiscovery.find(at: path)
            }
            if let surface {
                return ProjectActionDiscovery.find(for: surface)
            }
            return ProjectActionDiscovery.find(at: FileManager.default.currentDirectoryPath)
        }()

        switch action {
        case "list":
            guard let project else {
                return ["actions": .array([])]
            }
            let status = ProjectActionTrustStore.shared.status(path: project.filePath, content: project.fileContent)
            let actionsJson: [JSON] = project.file.actions.map { act in
                var dict: [String: JSON] = [
                    "id": .string(act.id),
                    "title": .string(act.title),
                    "target": .string(act.effectiveTarget.rawValue),
                    "direction": .string(act.effectiveDirection.rawValue),
                    "command": .array(act.effectiveCommand.map(JSON.string))
                ]
                if let desc = act.description { dict["description"] = .string(desc) }
                if let cwd = act.cwd { dict["cwd"] = .string(cwd) }
                return .object(dict)
            }
            return [
                "project": .string(project.projectRoot),
                "path": .string(project.filePath),
                "name": project.file.name.map(JSON.string) ?? .null,
                "trusted": .bool(status.isTrusted),
                "status": .string(status.description),
                "actions": .array(actionsJson)
            ]

        case "run":
            guard let id = request.args["id"]?.string, !id.isEmpty else {
                throw ControlError(.invalid, "action run requires 'id'")
            }
            guard let project else {
                throw ControlError(.notFound, "no project actions found for current pane or specified path")
            }
            guard let act = project.file.actions.first(where: { $0.id == id }) else {
                throw ControlError(.notFound, "action '\(id)' not found in project actions (\(project.filePath))")
            }

            let approveFlag = request.args["approve"] == .bool(true)
            if approveFlag {
                ProjectActionTrustStore.shared.trust(path: project.filePath, content: project.fileContent)
            }

            let status = ProjectActionTrustStore.shared.status(path: project.filePath, content: project.fileContent)
            guard status.isTrusted else {
                throw ControlError(.disabled, "unapproved project actions: approval required (use --approve or takoctl action approve)")
            }

            guard let targetSurface = surface else {
                throw ControlError(.notFound, "no active surface to run project action")
            }

            let takoApp = all.first?.controller?.tako ?? (NSApp.delegate as? AppDelegate)?.tako
            let result = try ProjectActionManager.shared.execute(
                action: act,
                projectRoot: project.projectRoot,
                from: targetSurface,
                isTrusted: true,
                app: takoApp
            )

            return [
                "ran": .bool(result.executed),
                "id": .string(result.actionId),
                "title": .string(act.title),
                "target": .string(result.target.rawValue),
                "cwd": .string(result.effectiveCwd),
                "trusted": .bool(result.isTrusted)
            ]

        case "approve":
            guard let project else {
                throw ControlError(.notFound, "no project actions found to approve")
            }
            ProjectActionTrustStore.shared.trust(path: project.filePath, content: project.fileContent)
            let hash = ProjectActionTrustStore.sha256(for: project.fileContent)
            return [
                "approved": .bool(true),
                "project": .string(project.projectRoot),
                "path": .string(ProjectActionTrustStore.canonicalPath(project.filePath)),
                "sha256": .string(hash)
            ]

        case "status":
            guard let project else {
                throw ControlError(.notFound, "no project actions found to inspect status")
            }
            let status = ProjectActionTrustStore.shared.status(path: project.filePath, content: project.fileContent)
            let hash = ProjectActionTrustStore.sha256(for: project.fileContent)
            return [
                "project": .string(project.projectRoot),
                "path": .string(ProjectActionTrustStore.canonicalPath(project.filePath)),
                "status": .string(status.description),
                "trusted": .bool(status.isTrusted),
                "sha256": .string(hash),
                "actions_count": .number(Double(project.file.actions.count))
            ]

        default:
            throw ControlError(.invalid, "unknown action subcommand: \(action)")
        }
    }

    static func taskCommand(_ request: ControlRequest, all: [Pane]) throws -> [String: JSON] {
        let action: String = try {
            if let a = request.args["action"], case .string(let str) = a { return str }
            if let a = request.args["subcommand"], case .string(let str) = a { return str }
            throw ControlError(.invalid, "task command requires a subcommand (create, list, status, finish)")
        }()

        let surface: Tako.SurfaceView? = (try? target(request, all)) ?? all.first?.surface
        let path: String? = {
            if let p = request.args["path"]?.string, !p.isEmpty { return p }
            if let s = surface, let pwd = s.workingDirectory, !pwd.isEmpty { return pwd }
            return nil
        }()

        switch action {
        case "create":
            guard let name = request.args["name"]?.string, !name.isEmpty else {
                throw ControlError(.invalid, "task create requires 'name'")
            }
            let branch = request.args["branch"]?.string
            let base = request.args["base"]?.string
            let targetStr = request.args["target"]?.string ?? "tab"
            let target: WorktreeTaskTarget = (targetStr == "workspace") ? .workspace : .tab
            let command: [String]? = {
                if let arr = request.args["command"]?.array {
                    return arr.compactMap { $0.string }
                }
                if let str = request.args["command"]?.string, !str.isEmpty {
                    return [str]
                }
                return nil
            }()

            let takoApp = all.first?.controller?.tako ?? (NSApplication.shared.delegate as? AppDelegate)?.tako
            let fromWindow = surface?.window ?? all.first?.controller?.window

            do {
                let info = try WorktreeTaskManager.shared.createTask(
                    name: name,
                    projectPath: path,
                    branch: branch,
                    base: base,
                    target: target,
                    command: command,
                    app: takoApp,
                    fromWindow: fromWindow
                )
                var dict: [String: JSON] = [
                    "created": .bool(true),
                    "id": .string(info.id),
                    "name": .string(info.name),
                    "project": .string(info.projectRoot),
                    "worktree": .string(info.worktreePath),
                    "branch": .string(info.branch),
                    "base": .string(info.baseBranch),
                    "target": .string(info.target.rawValue),
                    "status": .string(info.status.rawValue)
                ]
                if let cmd = info.command {
                    dict["command"] = .array(cmd.map(JSON.string))
                }
                return dict
            } catch {
                throw ControlError(.internalError, error.localizedDescription)
            }

        case "list":
            let tasks = WorktreeTaskManager.shared.listTasks(for: path)
            let tasksJson: [JSON] = tasks.map { t in
                var dict: [String: JSON] = [
                    "id": .string(t.id),
                    "name": .string(t.name),
                    "project": .string(t.projectRoot),
                    "worktree": .string(t.worktreePath),
                    "branch": .string(t.branch),
                    "base": .string(t.baseBranch),
                    "target": .string(t.target.rawValue),
                    "status": .string(t.status.rawValue),
                    "ahead": .number(Double(t.ahead)),
                    "behind": .number(Double(t.behind)),
                    "changed_files": .number(Double(t.changedFiles)),
                    "has_uncommitted": .bool(t.hasUncommitted),
                    "has_unpushed": .bool(t.hasUnpushed)
                ]
                if let cmd = t.command {
                    dict["command"] = .array(cmd.map(JSON.string))
                }
                return .object(dict)
            }
            return [
                "tasks": .array(tasksJson)
            ]

        case "status":
            guard let name = request.args["name"]?.string, !name.isEmpty else {
                throw ControlError(.invalid, "task status requires 'name'")
            }
            do {
                let t = try WorktreeTaskManager.shared.status(name: name, projectPath: path)
                var dict: [String: JSON] = [
                    "id": .string(t.id),
                    "name": .string(t.name),
                    "project": .string(t.projectRoot),
                    "worktree": .string(t.worktreePath),
                    "branch": .string(t.branch),
                    "base": .string(t.baseBranch),
                    "target": .string(t.target.rawValue),
                    "status": .string(t.status.rawValue),
                    "ahead": .number(Double(t.ahead)),
                    "behind": .number(Double(t.behind)),
                    "changed_files": .number(Double(t.changedFiles)),
                    "has_uncommitted": .bool(t.hasUncommitted),
                    "has_unpushed": .bool(t.hasUnpushed)
                ]
                if let cmd = t.command {
                    dict["command"] = .array(cmd.map(JSON.string))
                }
                return dict
            } catch {
                throw ControlError(.notFound, error.localizedDescription)
            }

        case "finish":
            guard let name = request.args["name"]?.string, !name.isEmpty else {
                throw ControlError(.invalid, "task finish requires 'name'")
            }
            let archive = request.args["archive"] == .bool(true)
            let editor = request.args["editor"] == .bool(true)
            let force = request.args["force"] == .bool(true)
            do {
                let res = try WorktreeTaskManager.shared.finishTask(
                    name: name,
                    projectPath: path,
                    archive: archive,
                    editor: editor,
                    force: force
                )
                return [
                    "finished": .bool(true),
                    "id": .string(res.taskId),
                    "name": .string(res.name),
                    "worktree": .string(res.worktreePath),
                    "archived": .bool(res.archived),
                    "opened_in_editor": .bool(res.openedInEditor),
                    "status": .string(res.status.rawValue)
                ]
            } catch {
                throw ControlError(.disabled, error.localizedDescription)
            }

        default:
            throw ControlError(.invalid, "unknown task subcommand: \(action)")
        }
    }

    static func handleResume(_ request: ControlRequest, all: [Pane]) throws -> ControlResponse {
        let surface = try target(request, all)
        let action: String = try {
            if let a = request.args["action"] {
                if case .string(let s) = a { return s }
                throw ControlError(.invalid, "\"action\" must be a string")
            }
            return "show"
        }()

        switch action {
        case "set":
            let argv: [String] = try {
                guard let argVal = request.args["argv"] else {
                    throw ControlError(.invalid, "missing \"argv\" argument for resume set")
                }
                if case .array(let arr) = argVal {
                    return try arr.map {
                        if case .string(let s) = $0 { return s }
                        throw ControlError(.invalid, "argv elements must be strings")
                    }
                }
                throw ControlError(.invalid, "\"argv\" must be an array of strings")
            }()
            guard !argv.isEmpty else {
                throw ControlError(.invalid, "argv cannot be empty")
            }
            let cwd: String = {
                if let c = request.args["cwd"], case .string(let s) = c, !s.isEmpty { return s }
                return surface.pwd ?? ""
            }()
            var env: [String: String] = [:]
            if let e = request.args["env"], case .object(let dict) = e {
                for (k, v) in dict {
                    if case .string(let s) = v { env[k] = s }
                }
            }
            let record = ResumeSessionRecord(argv: argv, cwd: cwd, env: env, recordedAt: Date(), isImported: false)
            ResumeSessionStore.shared.set(record: record, for: surface.id)
            let isApproved = ResumeTrustStore.shared.isApproved(argv: record.argv, cwd: cwd)
            return .ok([
                "id": .string(surface.id.uuidString.lowercased()),
                "argv": .array(argv.map(JSON.string)),
                "cwd": .string(cwd),
                "approved": .bool(isApproved),
            ])

        case "show":
            guard let record = ResumeSessionStore.shared.record(for: surface.id) else {
                return .ok([
                    "id": .string(surface.id.uuidString.lowercased()),
                    "has_resume": .bool(false),
                ])
            }
            let isApproved = ResumeTrustStore.shared.isApproved(argv: record.argv, cwd: record.cwd)
            var dict: [String: JSON] = [
                "id": .string(surface.id.uuidString.lowercased()),
                "has_resume": .bool(true),
                "argv": .array(record.argv.map(JSON.string)),
                "cwd": .string(record.cwd),
                "is_imported": .bool(record.isImported),
                "approved": .bool(isApproved),
                "recorded_at": .string(ISO8601DateFormatter().string(from: record.recordedAt)),
            ]
            var envJson: [String: JSON] = [:]
            for (k, v) in record.env {
                envJson[k] = .string(v)
            }
            dict["env"] = .object(envJson)
            return .ok(dict)

        case "clear":
            ResumeSessionStore.shared.clear(for: surface.id)
            return .ok([
                "id": .string(surface.id.uuidString.lowercased()),
                "cleared": .bool(true),
            ])

        case "run":
            guard let record = ResumeSessionStore.shared.record(for: surface.id) else {
                throw ControlError(.notFound, "no resume session recorded for this pane")
            }
            surface.dismissResumeBanner()
            surface.executeResume(record: record)
            return .ok([
                "id": .string(surface.id.uuidString.lowercased()),
                "executed": .bool(true),
                "argv": .array(record.argv.map(JSON.string)),
            ])

        case "approve":
            let cwd: String = {
                if let c = request.args["cwd"], case .string(let s) = c, !s.isEmpty { return s }
                if let record = ResumeSessionStore.shared.record(for: surface.id), !record.cwd.isEmpty {
                    return record.cwd
                }
                return surface.pwd ?? ""
            }()
            let prefix: String = try {
                if let p = request.args["prefix"], case .string(let s) = p, !s.isEmpty {
                    return s
                }
                if let record = ResumeSessionStore.shared.record(for: surface.id), !record.argv.isEmpty {
                    return record.argv.map { ResumeSessionStore.shellQuote($0) }.joined(separator: " ")
                }
                throw ControlError(.invalid, "missing prefix to approve and no recorded session found")
            }()
            ResumeTrustStore.shared.approve(prefix: prefix, cwd: cwd)
            return .ok([
                "id": .string(surface.id.uuidString.lowercased()),
                "approved": .bool(true),
                "prefix": .string(prefix),
                "cwd": .string(cwd),
            ])

        default:
            throw ControlError(.invalid, "unknown resume action \"\(action)\" (expected set, show, clear, run, approve)")
        }
    }

    static func sessionCommand(_ request: ControlRequest, all: [Pane]) throws -> [String: JSON] {
        let action: String = try {
            if let a = request.args["action"], case .string(let str) = a { return str }
            if let a = request.args["subcommand"], case .string(let str) = a { return str }
            throw ControlError(.invalid, "session command requires an action (export, import, info)")
        }()

        switch action {
        case "export":
            guard let path = request.args["path"]?.string, !path.isEmpty else {
                throw ControlError(.invalid, "session export requires 'path'")
            }
            let expanded = (path as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)

            // Resolve target window if requested
            let targetWindow: NSWindow? = {
                if let winId = request.args["window"]?.string, !winId.isEmpty {
                    if let found = all.first(where: {
                        $0.windowID.lowercased().hasPrefix(winId.lowercased()) ||
                        $0.stableTabID.lowercased().hasPrefix(winId.lowercased())
                    }) {
                        return found.controller?.window
                    }
                }
                if let targetSurface = try? target(request, all) {
                    return targetSurface.window ?? all.first(where: { $0.surface === targetSurface })?.controller?.window
                }
                return nil
            }()

            do {
                let file = try SessionExportManager.shared.exportSession(window: targetWindow, to: url)
                var paneCount = 0
                var resumeCount = 0
                for w in file.windows {
                    paneCount += w.panes.count
                    resumeCount += w.panes.filter { $0.resume != nil }.count
                }
                return [
                    "exported": .bool(true),
                    "path": .string(path),
                    "windows": .number(Double(file.windows.count)),
                    "panes": .number(Double(paneCount)),
                    "resumes": .number(Double(resumeCount)),
                    "format_version": .number(Double(file.formatVersion))
                ]
            } catch let err as SessionExportError {
                switch err {
                case .emptySession:
                    throw ControlError(.notFound, err.localizedDescription)
                default:
                    throw ControlError(.invalid, err.localizedDescription)
                }
            } catch {
                throw ControlError(.internalError, error.localizedDescription)
            }

        case "import":
            guard let path = request.args["path"]?.string, !path.isEmpty else {
                throw ControlError(.invalid, "session import requires 'path'")
            }
            let expanded = (path as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            let effectiveApp = all.first?.controller?.tako ?? (NSApp.delegate as? AppDelegate)?.tako

            do {
                let controllers = try SessionExportManager.shared.importSession(from: url, in: effectiveApp)
                return [
                    "imported": .bool(true),
                    "path": .string(path),
                    "windows": .number(Double(controllers.count))
                ]
            } catch let err as SessionExportError {
                switch err {
                case .unsupportedFormatVersion:
                    throw ControlError(.disabled, err.localizedDescription)
                case .invalidSessionFile, .emptySession:
                    throw ControlError(.invalid, err.localizedDescription)
                case .fileNotFound:
                    throw ControlError(.notFound, err.localizedDescription)
                }
            } catch {
                throw ControlError(.internalError, error.localizedDescription)
            }

        case "info":
            guard let path = request.args["path"]?.string, !path.isEmpty else {
                throw ControlError(.invalid, "session info requires 'path'")
            }
            let expanded = (path as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)

            do {
                let info = try SessionExportManager.shared.inspectSession(from: url)
                let formatter = ISO8601DateFormatter()
                return [
                    "format_version": .number(Double(info.formatVersion)),
                    "exported_at": .string(formatter.string(from: info.exportedAt)),
                    "tako_version": .string(info.takoVersion),
                    "windows": .number(Double(info.windowCount)),
                    "panes": .number(Double(info.paneCount)),
                    "resumes": .number(Double(info.resumeCount))
                ]
            } catch let err as SessionExportError {
                switch err {
                case .unsupportedFormatVersion:
                    throw ControlError(.disabled, err.localizedDescription)
                case .invalidSessionFile, .emptySession:
                    throw ControlError(.invalid, err.localizedDescription)
                case .fileNotFound:
                    throw ControlError(.notFound, err.localizedDescription)
                }
            } catch {
                throw ControlError(.internalError, error.localizedDescription)
            }

        default:
            throw ControlError(.invalid, "unknown session subcommand: \(action)")
        }
    }

    /// Handles `takoctl overlay open|close|status|reload` (D1).
    static func overlayCommand(_ request: ControlRequest, all: [Pane]) throws -> [String: JSON] {
        let surface = try target(request, all)
        recordActivity(for: request, on: surface.id, action: "overlay")
        let sub = (try? ControlInput.text(request.args, "subcommand")) ?? "status"

        switch sub {
        case "open":
            guard let file = request.args["file"]?.string, !file.isEmpty else {
                throw ControlError(.invalid, "missing \"file\" argument")
            }
            let typeStr = request.args["type"]?.string
            let splitDir = request.args["split"]?.string
            let surfacePwd = surface.pwd

            let targetPane: Tako.SurfaceView
            if let dir = splitDir {
                // Open overlay in a new split pane beside target
                let createdPane = try ControlLayout.split(surface, args: [
                    "direction": .string(dir),
                    "label": .string("overlay: \(file)")
                ])
                targetPane = createdPane
            } else {
                targetPane = surface
            }

            do {
                let state = try OverlayStore.shared.openOverlay(
                    paneId: targetPane.id,
                    path: file,
                    typeString: typeStr,
                    split: splitDir,
                    surfacePwd: surfacePwd
                )
                var dict: [String: JSON] = [
                    "id": .string(targetPane.id.uuidString.lowercased()),
                    "target": .string(surface.id.uuidString.lowercased()),
                    "open": .bool(true),
                    "file": .string(state.fileURL.path),
                    "title": .string(state.title),
                    "type": .string(state.fileType.rawValue),
                    "sandboxed": .string(state.sandboxedDirectory.path),
                ]
                if let s = splitDir {
                    dict["split"] = .string(s)
                }
                return dict
            } catch {
                throw ControlError(.invalid, error.localizedDescription)
            }

        case "close":
            let closed = OverlayStore.shared.closeOverlay(paneId: surface.id)
            return [
                "id": .string(surface.id.uuidString.lowercased()),
                "closed": .bool(closed)
            ]

        case "status":
            if let state = OverlayStore.shared.overlay(for: surface.id) {
                var dict: [String: JSON] = [
                    "id": .string(surface.id.uuidString.lowercased()),
                    "open": .bool(true),
                    "file": .string(state.fileURL.path),
                    "title": .string(state.title),
                    "type": .string(state.fileType.rawValue),
                    "sandboxed": .string(state.sandboxedDirectory.path),
                ]
                if let s = state.splitDirection {
                    dict["split"] = .string(s)
                }
                return dict
            } else {
                return [
                    "id": .string(surface.id.uuidString.lowercased()),
                    "open": .bool(false)
                ]
            }

        case "reload":
            OverlayStore.shared.reloadOverlay(paneId: surface.id)
            return [
                "id": .string(surface.id.uuidString.lowercased()),
                "reloaded": .bool(true)
            ]

        default:
            throw ControlError(.invalid, "unknown overlay subcommand: \(sub)")
        }
    }

    static func screenshotCommand(_ request: ControlRequest, all: [Pane]) throws -> [String: JSON] {
        let surface = try target(request, all)
        recordActivity(for: request, on: surface.id, action: "screenshot")
        guard !SecureInput.shared.isSecure(for: surface) && !surface.isSecureInput else {
            throw ControlError(.disabled, "secure-input panes cannot be read")
        }
        let (pngData, width, height) = try captureScreenshot(surface)
        let id = surface.id.uuidString.lowercased()
        return [
            "id": .string(id),
            "width": .number(Double(width)),
            "height": .number(Double(height)),
            "format": .string("png"),
            "data": .string(pngData.base64EncodedString()),
        ]
    }

    static func captureScreenshot(_ surface: Tako.SurfaceView) throws -> (data: Data, width: Int, height: Int) {
        let cols = max(1, Int(surface.core.cols()))
        let rows = max(1, Int(surface.core.rows()))
        let renderer = surface.renderer
        let size = renderer.pixelSize(cols: cols, rows: rows)
        let imgWidth = max(1, Int(size.width))
        let imgHeight = max(1, Int(size.height))

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil,
                  width: imgWidth,
                  height: imgHeight,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw ControlError(.internalError, "failed to create bitmap context for screenshot")
        }

        let snapshot = surface.core.snapshot()
        let cursorRow = Int(snapshot.cursorRow)
        let cursorCol = Int(snapshot.cursorCol)
        let cursorVisible = snapshot.cursorVisible
        let cursorStyle = snapshot.cursorStyle

        var cachedRows: [[TerminalCell]] = []
        var graphemes: [FfiGrapheme] = []
        for r in 0..<rows {
            let ffiCells = surface.core.viewportRow(row: UInt32(r))
            var termCells: [TerminalCell] = []
            for (c, cell) in ffiCells.enumerated() {
                termCells.append(TerminalCell(cell))
                if let g = cell.grapheme, !g.isEmpty {
                    graphemes.append(FfiGrapheme(row: UInt32(r), col: UInt32(c), text: g))
                }
            }
            cachedRows.append(termCells)
        }

        renderer.draw(
            in: context,
            cols: cols,
            rows: rows,
            rowProvider: { row in
                guard row >= 0 && row < cachedRows.count else { return [] }
                return cachedRows[row]
            },
            graphemes: graphemes,
            cursorRow: cursorRow,
            cursorCol: cursorCol,
            cursorVisible: cursorVisible,
            cursorStyle: cursorStyle,
            selection: nil,
            skipBackgrounds: false
        )

        guard let cgImage = context.makeImage() else {
            throw ControlError(.internalError, "failed to create cgImage from bitmap context")
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            throw ControlError(.internalError, "failed to encode screenshot as PNG")
        }
        return (pngData, imgWidth, imgHeight)
    }

    /// Handles `takoctl review open|status|files|diff|comment|send|close` (D3).
    static func reviewCommand(_ request: ControlRequest, all: [Pane]) throws -> [String: JSON] {
        let surface = try target(request, all)
        recordActivity(for: request, on: surface.id, action: "review")
        let sub = (try? ControlInput.text(request.args, "subcommand")) ?? "status"

        switch sub {
        case "open":
            guard let taskName = (request.args["task"]?.string ?? request.args["name"]?.string ?? request.args["worktree"]?.string), !taskName.isEmpty else {
                throw ControlError(.invalid, "missing \"task\" argument")
            }
            let baseBranch = request.args["base"]?.string
            let targetPaneStr = request.args["target_pane"]?.string
            let targetPaneId = targetPaneStr.flatMap(UUID.init) ?? request.from

            do {
                let session = try DiffReviewStore.shared.openReview(
                    paneId: surface.id,
                    taskName: taskName,
                    projectPath: surface.pwd,
                    baseBranch: baseBranch,
                    targetPaneId: targetPaneId
                )
                return [
                    "id": .string(surface.id.uuidString.lowercased()),
                    "task": .string(session.taskName),
                    "worktree": .string(session.worktreePath),
                    "base": .string(session.baseBranch),
                    "files_count": .number(Double(session.files.count)),
                    "comments_count": .number(Double(session.comments.count)),
                    "open": .bool(true),
                ]
            } catch {
                throw ControlError(.invalid, error.localizedDescription)
            }

        case "status":
            if let session = DiffReviewStore.shared.session(for: surface.id) {
                return [
                    "id": .string(surface.id.uuidString.lowercased()),
                    "open": .bool(true),
                    "task": .string(session.taskName),
                    "worktree": .string(session.worktreePath),
                    "base": .string(session.baseBranch),
                    "files_count": .number(Double(session.files.count)),
                    "comments_count": .number(Double(session.comments.count)),
                ]
            } else {
                return [
                    "id": .string(surface.id.uuidString.lowercased()),
                    "open": .bool(false),
                ]
            }

        case "files":
            guard let session = DiffReviewStore.shared.session(for: surface.id) else {
                throw ControlError(.notFound, "no active diff review session on this pane")
            }
            let fileJSONs: [JSON] = session.files.map { f in
                var dict: [String: JSON] = [
                    "path": .string(f.path),
                    "status": .string(f.status.rawValue),
                    "additions": .number(Double(f.additions)),
                    "deletions": .number(Double(f.deletions)),
                ]
                if let old = f.oldPath {
                    dict["old_path"] = .string(old)
                }
                return .object(dict)
            }
            return [
                "id": .string(surface.id.uuidString.lowercased()),
                "task": .string(session.taskName),
                "base": .string(session.baseBranch),
                "files": .array(fileJSONs),
            ]

        case "diff":
            guard let session = DiffReviewStore.shared.session(for: surface.id) else {
                throw ControlError(.notFound, "no active diff review session on this pane")
            }
            if let file = request.args["file"]?.string, !file.isEmpty {
                let detail = GitDiffHelper.getFileDiff(
                    worktreePath: session.worktreePath,
                    baseBranch: session.baseBranch,
                    file: file
                )
                return [
                    "id": .string(surface.id.uuidString.lowercased()),
                    "task": .string(session.taskName),
                    "file": .string(file),
                    "patch": .string(detail.patch),
                ]
            } else {
                let patch = GitDiffHelper.getFullDiff(
                    worktreePath: session.worktreePath,
                    baseBranch: session.baseBranch
                )
                return [
                    "id": .string(surface.id.uuidString.lowercased()),
                    "task": .string(session.taskName),
                    "patch": .string(patch),
                ]
            }

        case "comment":
            let action = (try? ControlInput.text(request.args, "action")) ?? "list"
            switch action {
            case "add":
                guard let file = request.args["file"]?.string, !file.isEmpty else {
                    throw ControlError(.invalid, "missing \"file\" argument")
                }
                let lineNum = Int(request.args["line"]?.number ?? 1)
                guard let text = request.args["text"]?.string, !text.isEmpty else {
                    throw ControlError(.invalid, "missing \"text\" argument")
                }
                do {
                    let comment = try DiffReviewStore.shared.addComment(
                        paneId: surface.id,
                        file: file,
                        line: lineNum,
                        text: text
                    )
                    return [
                        "id": .string(surface.id.uuidString.lowercased()),
                        "comment_id": .string(comment.id.uuidString.lowercased()),
                        "file": .string(comment.file),
                        "line": .number(Double(comment.line)),
                        "text": .string(comment.text),
                    ]
                } catch {
                    throw ControlError(.invalid, error.localizedDescription)
                }

            case "list":
                guard let session = DiffReviewStore.shared.session(for: surface.id) else {
                    throw ControlError(.notFound, "no active diff review session on this pane")
                }
                let commentJSONs: [JSON] = session.comments.map { c in
                    .object([
                        "id": .string(c.id.uuidString.lowercased()),
                        "file": .string(c.file),
                        "line": .number(Double(c.line)),
                        "text": .string(c.text),
                    ])
                }
                return [
                    "id": .string(surface.id.uuidString.lowercased()),
                    "comments": .array(commentJSONs),
                ]

            case "remove":
                guard let commentIdStr = request.args["comment_id"]?.string ?? request.args["id"]?.string,
                      let commentId = UUID(uuidString: commentIdStr) else {
                    throw ControlError(.invalid, "missing or invalid \"comment_id\" argument")
                }
                let removed = DiffReviewStore.shared.removeComment(paneId: surface.id, commentId: commentId)
                return [
                    "id": .string(surface.id.uuidString.lowercased()),
                    "removed": .bool(removed),
                ]

            case "clear":
                DiffReviewStore.shared.clearComments(paneId: surface.id)
                return [
                    "id": .string(surface.id.uuidString.lowercased()),
                    "cleared": .bool(true),
                ]

            default:
                throw ControlError(.invalid, "unknown review comment action: \(action)")
            }

        case "send":
            let explicitTargetStr = request.args["target_pane"]?.string ?? request.args["to"]?.string
            let targetPaneId = explicitTargetStr.flatMap(UUID.init)
            let destSurface: Tako.SurfaceView = try {
                if let targetPaneId {
                    guard let p = all.first(where: { $0.surface.id == targetPaneId }) else {
                        throw ControlError(.notFound, "target pane \(targetPaneId) not found")
                    }
                    return p.surface
                }
                if let storedTarget = DiffReviewStore.shared.session(for: surface.id)?.targetPaneId,
                   let p = all.first(where: { $0.surface.id == storedTarget }) {
                    return p.surface
                }
                return surface
            }()
            do {
                let (msg, destId) = try DiffReviewStore.shared.sendFeedback(
                    paneId: surface.id,
                    targetSurface: destSurface
                )
                return [
                    "id": .string(surface.id.uuidString.lowercased()),
                    "target": .string(destId),
                    "sent": .bool(true),
                    "message": .string(msg),
                ]
            } catch {
                throw ControlError(.invalid, error.localizedDescription)
            }

        case "close":
            let closed = DiffReviewStore.shared.closeReview(paneId: surface.id)
            return [
                "id": .string(surface.id.uuidString.lowercased()),
                "closed": .bool(closed),
            ]

        default:
            throw ControlError(.invalid, "unknown review subcommand: \(sub)")
        }
    }

    /// Handles `triggers` control command: list, add, remove, and clear passive regex triggers (E7).
    /// Strictly passive: rules can highlight output text or trigger notifications; never injects keystrokes.
    static func triggersCommand(_ request: ControlRequest, all: [Pane]) throws -> [String: JSON] {
        let sub = request.args["subcommand"]?.string ?? "list"
        switch sub {
        case "list":
            let triggers = PassiveTriggerStore.shared.allTriggers
            let listJson: [JSON] = triggers.map { trigger in
                var obj: [String: JSON] = [
                    "id": .string(trigger.id.uuidString.lowercased()),
                    "pattern": .string(trigger.pattern),
                    "action": .string(trigger.action.rawValue),
                    "style": .string(trigger.style.rawValue),
                    "only_unfocused": .bool(trigger.onlyUnfocused),
                    "is_dynamic": .bool(trigger.isDynamic),
                ]
                if let colorName = trigger.colorName {
                    obj["color"] = .string(colorName)
                }
                if let title = trigger.notificationTitle {
                    obj["title"] = .string(title)
                }
                return .object(obj)
            }
            return ["triggers": .array(listJson)]

        case "add":
            guard let pattern = request.args["pattern"]?.string, !pattern.isEmpty else {
                throw ControlError(.invalid, "missing or empty \"pattern\" argument")
            }
            // Validate regex syntax
            guard (try? NSRegularExpression(pattern: pattern, options: [])) != nil else {
                throw ControlError(.invalid, "invalid regular expression pattern: \(pattern)")
            }
            let actionStr = request.args["action"]?.string ?? "highlight"
            guard let action = TerminalRegexTrigger.Action(rawValue: actionStr.lowercased()) else {
                throw ControlError(.invalid, "invalid action: \(actionStr); expected highlight, notify, or both")
            }
            let colorName = request.args["color"]?.string ?? "yellow"
            let styleStr = request.args["style"]?.string ?? "background"
            guard let style = TerminalRegexTrigger.HighlightStyle(rawValue: styleStr.lowercased()) else {
                throw ControlError(.invalid, "invalid style: \(styleStr); expected background, underline, box, or bold")
            }
            let title = request.args["title"]?.string
            let onlyUnfocused = request.args["only_unfocused"]?.bool ?? (request.args["all_focus"]?.bool == true ? false : true)

            let safety = TerminalRegexTrigger.isSafePattern(pattern)
            guard safety.isSafe else {
                throw ControlError(.invalid, "unsafe regex pattern: \(safety.reason ?? "catastrophic backtracking risk")")
            }
            guard let trigger = TerminalRegexTrigger(
                pattern: pattern,
                action: action,
                colorName: colorName,
                style: style,
                notificationTitle: title,
                onlyUnfocused: onlyUnfocused,
                isDynamic: true
            ) else {
                throw ControlError(.invalid, "invalid regex pattern: \(pattern)")
            }
            PassiveTriggerStore.shared.addDynamicTrigger(trigger)
            all.forEach { $0.surface.updateActiveRegexTriggers() }

            var res: [String: JSON] = [
                "id": .string(trigger.id.uuidString.lowercased()),
                "pattern": .string(trigger.pattern),
                "action": .string(trigger.action.rawValue),
                "color": .string(colorName),
                "style": .string(trigger.style.rawValue),
                "only_unfocused": .bool(trigger.onlyUnfocused),
                "is_dynamic": .bool(true),
            ]
            if let title {
                res["title"] = .string(title)
            }
            return res

        case "remove", "rm", "delete":
            guard let idStr = request.args["id"]?.string, let id = UUID(uuidString: idStr) else {
                throw ControlError(.invalid, "missing or invalid \"id\" argument")
            }
            PassiveTriggerStore.shared.removeTrigger(id: id)
            all.forEach { $0.surface.updateActiveRegexTriggers() }
            return ["removed": .string(id.uuidString.lowercased())]

        case "clear", "reset":
            PassiveTriggerStore.shared.clearDynamicTriggers()
            all.forEach { $0.surface.updateActiveRegexTriggers() }
            return ["cleared": .bool(true)]

        default:
            throw ControlError(.invalid, "unknown triggers subcommand: \(sub); expected list, add, remove, or clear")
        }
    }

    static func layout(_ node: SplitTree<Tako.SurfaceView>.Node) -> JSON {
        switch node {
        case .leaf(let view):
            return .object(["pane": .string(view.id.uuidString.lowercased())])
        case .split(let split):
            return .object([
                // Horizontal lays the two out side by side: the second is to
                // the right. Vertical stacks them: the second is below.
                "split": .string(split.direction == .horizontal ? "right" : "down"),
                "ratio": .number((split.ratio * 100).rounded() / 100),
                "children": .array([layout(split.left), layout(split.right)]),
            ])
        }
    }
}
