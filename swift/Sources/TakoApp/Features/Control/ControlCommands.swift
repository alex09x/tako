import AppKit

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
            let windowID: String, tabID: String
            if controller is QuickTerminalController {
                windowID = "quick-terminal"
                tabID = "quick-terminal"
            } else {
                guard let window = controller.window else { continue }
                windowID = ScriptWindow.stableID(tabGroup: Tako.CustomTabGroup.group(for: window))
                tabID = ScriptTab.stableID(controller: controller)
            }
            for surface in controller.surfaceTree {
                result.append(Pane(surface: surface, windowID: windowID, tabID: tabID))
            }
        }
        return result
    }

    /// The focused pane of the front window.
    /// The pane with the keyboard: the focused pane of the key window, else
    /// of the main window, else of the frontmost terminal window. Each tab is
    /// a window of its own, so the frontmost by order is not necessarily the
    /// one being typed into.
    static func activePane(_ panes: [Pane]) -> UUID? {
        let candidates = [NSApp.keyWindow, NSApp.mainWindow] + NSApp.orderedWindows.map { Optional($0) }
        for window in candidates {
            if let controller = window?.windowController as? BaseTerminalController,
               let id = controller.focusedSurface?.id {
                return id
            }
        }
        return panes.first?.surface.id
    }

    /// Answers `request`, now or -- for work done off the main thread or
    /// that waits on the user -- later, exactly once.
    static func handle(_ request: ControlRequest, reply: @escaping @Sendable (ControlResponse) -> Void) {
        let all = panes()
        do {
            guard mode.allows(from: request.from, panes: all.map(\.surface.id)) else {
                reply(handle(request))   // the refusal, from one place
                return
            }
            switch request.cmd {
            case "text":
                let surface = try target(request, all)
                let lines = try ControlInput.lines(request.args)
                let core = surface.core
                let id = surface.id.uuidString.lowercased()
                DispatchQueue.global(qos: .userInitiated).async {
                    var result = ControlInput.read(core, lines: lines)
                    result["id"] = .string(id)
                    reply(.ok(result))
                }
            case "close":
                let surface = try target(request, all)
                ControlLayout.close(surface, reply: reply)
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
        let all = panes()
        let ids = all.map(\.surface.id)
        guard mode.allows(from: request.from, panes: ids) else {
            return .failure(ControlError(.disabled, mode == .local
                ? "remote control accepts requests from inside a Tako pane (remote-control = local)"
                : "remote control is off"))
        }
        do {
            switch request.cmd {
            case "version":
                return .ok(version())
            case "tree":
                return .ok(tree(all, active: activePane(all)))
            case "send", "type":
                let surface = try target(request, all)
                let enter = request.cmd == "send" && request.args["enter"] != .bool(false)
                try ControlInput.send(surface, text: try ControlInput.text(request.args), enter: enter)
                return .ok(["id": .string(surface.id.uuidString.lowercased())])
            case "key":
                let surface = try target(request, all)
                try ControlInput.key(surface, chord: try ControlInput.text(request.args, "key"))
                return .ok(["id": .string(surface.id.uuidString.lowercased())])
            case "tab-new":
                let pane = try ControlLayout.newTab(beside: try target(request, all), args: request.args)
                return .ok(["id": .string(pane.id.uuidString.lowercased())])
            case "split":
                let pane = try ControlLayout.split(try target(request, all), args: request.args)
                return .ok(["id": .string(pane.id.uuidString.lowercased())])
            case "focus":
                let surface = try target(request, all)
                ControlLayout.focus(surface)
                return .ok(["id": .string(surface.id.uuidString.lowercased())])
            case "title":
                let surface = try target(request, all)
                try ControlLayout.title(surface, try ControlInput.text(request.args, "title"))
                return .ok(["id": .string(surface.id.uuidString.lowercased())])
            case "text", "close":
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
        for pane in panes {
            let surface = pane.surface
            let persistent = surface.persistence != nil
            var node: [String: JSON] = [
                "id": .string(surface.id.uuidString.lowercased()),
                "title": .string(surface.title),
                "cwd": surface.pwd.map(JSON.string) ?? .null,
                "focused": .bool(surface.id == active),
                "alternateScreen": .bool(surface.isAlternateScreen),
                "persistentSession": .bool(persistent),
                "exited": .bool(surface.processExited),
            ]
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
                return windows[w].tabs.count - 1
            }()
            windows[w].tabs[t].panes.append(.object(node))
        }
        return ["windows": .array(windows.map { window in
            .object([
                "id": .string(window.id),
                "tabs": .array(window.tabs.map { tab in
                    .object(["id": .string(tab.id), "panes": .array(tab.panes)])
                }),
            ])
        })]
    }
}
