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

    /// Closes the pane the way closing it by hand does, asking first when
    /// that would. Answers what happened: `closed`, or `confirming` while
    /// the question is on screen -- never `closed` before it is.
    static func close(_ surface: Tako.SurfaceView, all: () -> [ControlCommands.Pane]) throws -> String {
        let id = surface.id
        try controller(of: surface).closeSurface(surface, withConfirmation: true)
        return all().contains(where: { $0.surface.id == id }) ? "confirming" : "closed"
    }
}
