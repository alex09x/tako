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
        let controller: BaseTerminalController

        init(surface: Tako.SurfaceView, windowID: String, tabID: String, stableTabID: String? = nil, controller: BaseTerminalController) {
            self.surface = surface
            self.windowID = windowID
            self.tabID = tabID
            self.stableTabID = stableTabID ?? controller.window?.stableTabIdentifier ?? tabID
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
            case "last":
                try ControlCommand.last(try target(request, all), args: request.args, reply: reply)
            case "wait":
                try ControlCommand.wait(request, try target(request, all), reply: reply)
            case "run":
                try ControlCommand.run(request, beside: try target(request, all), reply: reply)
            case "find":
                find(try ControlInput.text(request.args), limit: try findLimit(request.args), reply: reply)
            case "notify":
                let surface = try target(request, all)
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
                try TerminalEventHub.shared.subscribe(
                    clientFD: request.clientFD,
                    args: request.args,
                    onClose: onClose
                )
            case "ask":
                let surface = try target(request, all)
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
            case "status":
                let surface = try target(request, all)
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
                return .ok(try dialog(request.args))
            case "workspace":
                return .ok(try workspaceCommand(request, all: all))
            case "layout":
                return .ok(try layoutCommand(request, all: all))
            case "action":
                return .ok(try actionCommand(request, all: all))
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
                tabInfo[pane.tabID] = tabFacts(pane.controller)
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
                    if let matched = all.first(where: { $0.surface === surface }), let win = matched.controller.window {
                        return win
                    }
                }
                if let key = NSApp.keyWindow ?? NSApp.mainWindow { return key }
                if let first = all.first(where: { $0.controller.window != nil })?.controller.window {
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

            let takoApp = all.first?.controller.tako ?? (NSApp.delegate as? AppDelegate)?.tako
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

            let takoApp = all.first?.controller.tako ?? (NSApp.delegate as? AppDelegate)?.tako
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
