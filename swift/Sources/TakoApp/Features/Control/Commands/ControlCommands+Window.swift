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

extension ControlCommands {
    /// One terminal window as `takoctl` sees it: its tabs share one window
    /// on screen, the one shown standing for all of them.
    @MainActor
    struct WindowGroup {
        let id: String
        let group: Tako.CustomTabGroup
        let controllers: [TerminalController]

        /// The tab on screen, or the first one.
        var shown: TerminalController? {
            controllers.first { $0.window === group.selectedWindow } ?? controllers.first
        }
    }

    /// Every terminal window, in the order their tabs were opened.
    static func windowGroups(_ controllers: [TerminalController] = TerminalController.all) -> [WindowGroup] {
        var order: [ObjectIdentifier] = []
        var found: [ObjectIdentifier: (Tako.CustomTabGroup, [TerminalController])] = [:]
        for controller in controllers {
            guard let window = controller.window, !Tako.CustomTabGroup.isClosed(window) else { continue }
            let group = Tako.CustomTabGroup.group(for: window)
            let key = ObjectIdentifier(group)
            if found[key] == nil { order.append(key) }
            found[key, default: (group, [])].1.append(controller)
        }
        return order.compactMap { key in
            guard let (group, members) = found[key] else { return nil }
            return WindowGroup(id: "window-\(key.hexString)", group: group, controllers: members)
        }
    }

    /// The window a request means: `--window ID`, else the target pane's.
    static func windowGroup(_ request: ControlRequest, all: [Pane],
                            groups: [WindowGroup]? = nil) throws -> WindowGroup {
        let groups = groups ?? windowGroups()
        if let id = request.args["window"]?.string, id != "new" {
            guard let match = groups.first(where: { $0.id == id }) else {
                throw ControlError(.notFound, "no window \(id); takoctl window list names them")
            }
            return match
        }
        let surface = try target(request, all)
        guard let controller = BaseTerminalController.owningController(for: surface) as? TerminalController,
              let window = controller.window,
              let match = groups.first(where: { $0.group === Tako.CustomTabGroup.group(for: window) }) else {
            throw ControlError(.invalid, "the pane is not in a terminal window (the Quick Terminal has none)")
        }
        return match
    }

    static func describe(_ window: WindowGroup) -> [String: JSON] {
        let shown = window.shown
        let frame = shown?.window?.frame ?? .zero
        return [
            "id": .string(window.id),
            "tabs": .number(Double(window.controllers.count)),
            "frame": .object(["x": .number(frame.minX), "y": .number(frame.minY),
                              "width": .number(frame.width), "height": .number(frame.height)]),
            "minimized": .bool(shown?.window?.isMiniaturized ?? false),
            "fullscreen": .bool(shown?.fullscreenStyle?.isFullscreen ?? false),
            "key": .bool(window.controllers.contains { $0.window?.isKeyWindow == true }),
            "visible": .bool(shown?.window?.isVisible ?? false),
        ]
    }

    /// `takoctl window`: list, new, minimize, restore, fullscreen, focus and
    /// frame. `close` asks the user and is answered by `windowClose`.
    static func windowCommand(_ request: ControlRequest, all: [Pane]) throws -> [String: JSON] {
        let action = request.args["action"]?.string ?? "list"
        if action == "list" {
            return ["windows": .array(windowGroups().map { .object(describe($0)) })]
        }
        if action == "new" {
            return try newWindow(request, all: all)
        }
        let target = try windowGroup(request, all: all)
        guard let shown = target.shown, let window = shown.window else {
            throw ControlError(.notFound, "the window \(target.id) has no tab on screen")
        }
        switch action {
        case "state", "get":
            break
        case "minimize":
            if !window.isMiniaturized { window.miniaturize(nil) }
        case "restore", "unminimize":
            if window.isMiniaturized { window.deminiaturize(nil) }
        case "fullscreen":
            let want = try fullscreenWanted(request.args, now: shown.fullscreenStyle?.isFullscreen ?? false)
            if want != (shown.fullscreenStyle?.isFullscreen ?? false) {
                shown.toggleFullscreen(mode: shown.tako.config.windowFullscreen ?? .native)
            }
        case "focus":
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        case "frame":
            if let frame = try requestedFrame(request.args) {
                window.setFrame(frame, display: true)
            }
        default:
            throw ControlError(.invalid, "unknown window action \"\(action)\"; use list, new, state, minimize, restore, fullscreen, focus, frame or close")
        }
        return describe(target)
    }

    /// `fullscreen on|off|toggle` (toggle when not said).
    nonisolated static func fullscreenWanted(_ args: [String: JSON], now: Bool) throws -> Bool {
        switch args["value"]?.string ?? "toggle" {
        case "on", "true", "yes": return true
        case "off", "false", "no": return false
        case "toggle": return !now
        case let other: throw ControlError(.invalid, "fullscreen takes on, off or toggle, not \"\(other)\"")
        }
    }

    /// `frame X Y W H`, in screen points from the bottom left as AppKit and
    /// layout files have it; nil when only asked.
    nonisolated static func requestedFrame(_ args: [String: JSON]) throws -> NSRect? {
        guard let raw = args["frame"] else { return nil }
        guard case .array(let items) = raw, items.count == 4,
              let x = items[0].number, let y = items[1].number, let w = items[2].number, let h = items[3].number,
              [x, y, w, h].allSatisfy(\.isFinite) else {
            throw ControlError(.invalid, "\"frame\" must be four numbers: x y width height")
        }
        guard w >= 100, h >= 60, w <= 100_000, h <= 100_000 else {
            throw ControlError(.invalid, "a window frame must be at least 100 x 60 points")
        }
        return NSRect(x: x, y: y, width: w, height: h)
    }

    /// `window new`: a window of its own with one pane, in the state asked.
    private static func newWindow(_ request: ControlRequest, all: [Pane]) throws -> [String: JSON] {
        guard let tako = all.first?.controller?.tako ?? (NSApp.delegate as? AppDelegate)?.tako else {
            throw ControlError(.internalError, "no Tako app instance available")
        }
        _ = try ControlPaneState.requested(request.args)
        let frame = try requestedFrame(request.args)
        let config = try ControlLayout.config(request.args)
        let controller = TerminalController.newWindow(tako, withBaseConfig: config)
        guard let pane = controller.surfaceTree.first, let window = controller.window else {
            throw ControlError(.internalError, "the window was not created")
        }
        if let creator = request.client ?? request.args["client"]?.string {
            InputOwnershipStore.shared.setCreatorClient(paneId: pane.id, client: creator)
        }
        if let frame { window.setFrame(frame, display: true) }
        var result = try ControlPaneState.applyRequested(request.args, to: pane)
        recordActivity(for: request, on: pane.id, action: "window new")
        result["window"] = .string(windowID(window))
        return result
    }
}
