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
        if let app = NSApp?.delegate as? AppDelegate, app.quickControllerInitialized {
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
        if let app = NSApp {
            let candidates = [app.keyWindow, app.mainWindow] + app.orderedWindows.map { Optional($0) }
            for window in candidates {
                if let controller = window?.windowController as? BaseTerminalController,
                   let id = controller.focusedSurface?.id,
                   paneIDs.contains(id) {
                    return id
                }
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
                return .ok(try historyCommand(request, all: all))
            case "triggers":
                return .ok(try triggersCommand(request, all: all))
            case "send", "type":
                return .ok(try sendCommand(request, all: all))
            case "key":
                return .ok(try keyCommand(request, all: all))
            case "tab-new":
                return .ok(try tabNewCommand(request, all: all))
            case "split":
                return .ok(try splitCommand(request, all: all))
            case "collapse":
                return .ok(try collapseCommand(request, all: all))
            case "expand":
                return .ok(try expandCommand(request, all: all))
            case "resume":
                return try handleResume(request, all: all)
            case "input":
                return .ok(try inputOwnershipCommand(request, all: all))
            case "grant":
                return .ok(try grantCommand(request, all: all))
            case "broadcast":
                return .ok(try broadcastCommand(request, all: all))
            case "focus":
                return .ok(try focusCommand(request, all: all))
            case "title":
                return .ok(try titleCommand(request, all: all))
            case "status":
                return .ok(try statusCommand(request, all: all))
            case "progress":
                return .ok(try progressCommand(request, all: all))
            case "dialog":
                if let surface = try? target(request, all) {
                    recordActivity(for: request, on: surface.id, action: "dialog")
                }
                return .ok(try dialog(request.args))
            case "activity":
                return .ok(try activityCommand(request, all: all))
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
            case "diagnose":
                return .ok(try diagnoseCommand(request, all: all))
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
}
