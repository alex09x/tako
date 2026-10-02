import AppKit

/// What `takoctl` requests do, on the main thread.
@MainActor
enum ControlCommands {
    /// The server, once started; `TAKO_SOCKET` names its path.
    static var server: ControlServer?
    static var mode: RemoteControlMode = .local

    /// The socket path every shell is told about, or nil when control is off.
    /// Set when the server starts, before any terminal opens.
    nonisolated(unsafe) static var socketPath: String?

    /// Starts serving per `remote-control`. A copy of Tako that finds the
    /// socket owned by another copy leaves it to that one.
    static func start(mode: RemoteControlMode, bundleID: String) {
        self.mode = mode
        guard mode != .off else { return }
        do {
            let path = try ControlServer.socketPath(bundleID: bundleID)
            socketPath = path
            let server = ControlServer(path: path) { request, reply in
                reply(handle(request))
            }
            switch try server.start() {
            case .listening: self.server = server
            case .taken: NSLog("takoctl: another copy of Tako serves \(path)")
            }
        } catch {
            NSLog("takoctl: not serving: \(error)")
        }
    }

    static func stop() {
        server?.stop()
        server = nil
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
        // front is still a pane a script can name.
        for controller in TerminalController.all {
            guard let window = controller.window else { continue }
            let windowID = ScriptWindow.stableID(tabGroup: Tako.CustomTabGroup.group(for: window))
            let tabID = ScriptTab.stableID(controller: controller)
            for surface in controller.surfaceTree {
                result.append(Pane(surface: surface, windowID: windowID, tabID: tabID))
            }
        }
        return result
    }

    /// The focused pane of the front window.
    static func activePane(_ panes: [Pane]) -> UUID? {
        let front = NSApp.orderedWindows.compactMap { $0.windowController as? BaseTerminalController }.first
        return front?.focusedSurface?.id ?? panes.first?.surface.id
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
            default:
                throw ControlError(.invalid, "unknown command \"\(request.cmd)\"")
            }
        } catch let error as ControlError {
            return .failure(error)
        } catch {
            return .failure(ControlError(.internalError, "\(error)"))
        }
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
