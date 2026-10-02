import AppKit

/// Tabs and splits for `takoctl tab-new|split|focus|close|title`.
@MainActor
enum ControlLayout {
    /// `cwd` from a request: a directory that exists, or nothing.
    static func config(_ args: [String: JSON]) throws -> Tako.SurfaceConfiguration? {
        guard let cwd = args["cwd"] else { return nil }
        guard let path = cwd.string else { throw ControlError(.invalid, "\"cwd\" is not a string") }
        let expanded = (path as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue else {
            throw ControlError(.invalid, "\"cwd\" is not a directory: \(path)")
        }
        return Tako.SurfaceConfiguration(workingDirectory: expanded)
    }

    static func controller(of surface: Tako.SurfaceView) throws -> BaseTerminalController {
        guard let controller = surface.window?.windowController as? BaseTerminalController else {
            throw ControlError(.notFound, "the pane is not in a window")
        }
        return controller
    }

    /// A new tab in the window of `beside`, its pane's id returned. `select`
    /// false keeps the tab the user is looking at in front.
    static func newTab(beside: Tako.SurfaceView, args: [String: JSON]) throws -> Tako.SurfaceView {
        guard let app = NSApp.delegate as? AppDelegate else {
            throw ControlError(.internalError, "no app delegate")
        }
        let config = try config(args)
        let select = args["select"] != .bool(false)
        let front = NSApp.keyWindow
        guard !(try controller(of: beside) is QuickTerminalController) else {
            throw ControlError(.invalid, "the Quick Terminal has no tabs")
        }
        guard let created = TerminalController.newTab(app.tako, from: beside.window, withBaseConfig: config),
              let pane = created.surfaceTree.first else {
            throw ControlError(.internalError, "the tab was not created")
        }
        if !select, let front {
            // The new tab takes the front once AppKit has shown it; give the
            // front back after that, not before.
            DispatchQueue.main.async {
                DispatchQueue.main.async { front.makeKeyAndOrderFront(nil) }
            }
        }
        return pane
    }

    static func split(_ surface: Tako.SurfaceView, args: [String: JSON]) throws -> Tako.SurfaceView {
        let direction: SplitTree<Tako.SurfaceView>.NewDirection
        switch args["direction"]?.string {
        case "right"?: direction = .right
        case "left"?: direction = .left
        case "down"?: direction = .down
        case "up"?: direction = .up
        default: throw ControlError(.invalid, "\"direction\" must be right, left, down or up")
        }
        let config = try config(args)
        guard let pane = try controller(of: surface).newSplit(at: surface, direction: direction, baseConfig: config) else {
            throw ControlError(.internalError, "the split was not created")
        }
        return pane
    }

    /// Brings the pane's window and tab forward and gives it the keyboard.
    static func focus(_ surface: Tako.SurfaceView) {
        NotificationCenter.default.post(name: Tako.Notification.takoPresentTerminal, object: surface)
    }

    /// The tab's title; empty restores the program's own.
    static func title(_ surface: Tako.SurfaceView, _ title: String) throws {
        try controller(of: surface).titleOverride = title.isEmpty ? nil : title
    }

    /// How long a close may wait for the user to answer its question: well
    /// inside takoctl's own 30 s, so the client always hears the outcome --
    /// never a timeout while the question is still up. TAKO_CLOSE_WAIT
    /// (seconds) shortens it for a test.
    static var closeWait: TimeInterval {
        ProcessInfo.processInfo.environment["TAKO_CLOSE_WAIT"].flatMap(Double.init).map { min($0, 20) } ?? 20
    }

    /// Closes the pane the way closing it by hand does: asking first exactly
    /// when that would (a running process), never skipping a persistent
    /// session's own question. Answers once, with what happened: `closed`,
    /// or `cancelled` when the user said no -- or did not answer within
    /// `closeWait`, in which case the question is withdrawn so a late click
    /// cannot close it after takoctl was told it did not.
    static func close(_ surface: Tako.SurfaceView, reply: @escaping @Sendable (ControlResponse) -> Void) {
        let id = surface.id
        let idString = id.uuidString.lowercased()
        let controller: BaseTerminalController
        do { controller = try self.controller(of: surface) } catch let e as ControlError {
            reply(.failure(e)); return
        } catch { reply(.failure(ControlError(.internalError, "\(error)"))); return }
        if controller is QuickTerminalController, Array(controller.surfaceTree).count == 1 {
            // Its last pane is hidden with the Quick Terminal, not closed.
            reply(.failure(ControlError(.invalid, "the Quick Terminal's last pane is hidden, not closed")))
            return
        }
        let window = controller.window
        controller.closeSurface(surface, withConfirmation: surface.needsConfirmClose)
        let deadline = Date().addingTimeInterval(closeWait)
        func answer(_ state: String, _ note: String? = nil) {
            var result: [String: JSON] = ["id": .string(idString), "state": .string(state)]
            if let note { result["note"] = .string(note) }
            reply(.ok(result))
        }
        func exists() -> Bool { ControlCommands.panes().contains { $0.surface.id == id } }
        func check() {
            if !exists() { return answer("closed") }
            if let sheet = window?.attachedSheet {
                guard Date() < deadline else {
                    // Withdraw the question: an abort is not a yes.
                    window?.endSheet(sheet, returnCode: .abort)
                    DispatchQueue.main.async {
                        exists() ? answer("cancelled", "no answer within \(Int(closeWait)) s") : answer("closed")
                    }
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { check() }
                return
            }
            answer("cancelled")
        }
        // The question, when there is one, goes up on the next turn.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { check() }
    }
}
