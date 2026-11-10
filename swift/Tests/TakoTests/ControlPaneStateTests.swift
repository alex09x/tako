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
import Testing
@testable import Tako

/// `takoctl pane`: every canvas state reachable from every other, the same
/// live pane and process throughout, and a script that never steals the
/// keyboard it was told to leave alone.
@MainActor @Suite(.serialized)
struct ControlPaneStateTests {
    struct Tab {
        let controller: TerminalController
        let window: NSWindow
        let a: Tako.SurfaceView
        let b: Tako.SurfaceView
        var all: [ControlCommands.Pane] {
            Array(controller.surfaceTree).map {
                ControlCommands.Pane(surface: $0, windowID: "w", tabID: "t", controller: controller)
            }
        }
    }

    private func tab() throws -> Tab {
        let (controller, window) = TerminalTestSupport.loaded()
        window.setContentSize(NSSize(width: 1200, height: 700))
        let a = try #require(controller.focusedSurface)
        let b = try #require(controller.newSplit(at: a, direction: .right))
        controller.floatingCanvas.reduceMotionProvider = { true }
        return Tab(controller: controller, window: window, a: a, b: b)
    }

    private func close(_ tab: Tab) {
        tab.window.close()
        TerminalTestSupport.tearDown(tab.controller, tab.window)
    }

    private func pane(_ action: String, _ surface: Tako.SurfaceView, in tab: Tab,
                      _ extra: [String: JSON] = [:]) -> ControlResponse {
        let previous = ControlCommands.mode
        ControlCommands.mode = .on
        defer { ControlCommands.mode = previous }
        var args: [String: JSON] = ["action": .string(action), "target": .string(surface.id.uuidString)]
        args.merge(extra) { _, new in new }
        return ControlCommands.handle(ControlRequest(cmd: "pane", args: args), all: tab.all)
    }

    private func state(_ response: ControlResponse) -> String? {
        if case .ok(let result) = response { return result["state"]?.string }
        return nil
    }

    private func failure(_ response: ControlResponse) -> String? {
        if case .failure(let error) = response { return error.message }
        return nil
    }

    @Test func everyStateIsReachableAndTheShelfRemembersWhereThePaneWas() throws {
        let tab = try tab()
        defer { close(tab) }
        let pty = tab.b.pty
        #expect(state(pane("state", tab.b, in: tab)) == "tiled")
        #expect(state(pane("float", tab.b, in: tab)) == "floating")
        #expect(state(pane("maximize", tab.b, in: tab)) == "maximized")
        #expect(state(pane("minimize", tab.b, in: tab)) == "minimized")
        if case .ok(let result) = pane("state", tab.b, in: tab) {
            #expect(result["restoresTo"]?.string == "maximized")
        } else {
            Issue.record("pane state failed")
        }
        #expect(state(pane("restore", tab.b, in: tab)) == "maximized", "off the shelf, back as it left")
        #expect(state(pane("unmaximize", tab.b, in: tab)) == "floating", "and out of maximized to where it floated")
        #expect(state(pane("dock", tab.b, in: tab)) == "tiled")
        #expect(state(pane("set", tab.b, in: tab, ["state": .string("minimized")])) == "minimized")
        #expect(state(pane("set", tab.b, in: tab, ["state": .string("floating")])) == "floating",
                "set goes straight from the shelf to floating")
        #expect(tab.b.pty === pty, "the same process throughout")
    }

    @Test func aStateAlreadyHeldChangesNothing() throws {
        let tab = try tab()
        defer { close(tab) }
        let before = tab.controller.floatingCanvas.state(for: tab.a.id)
        #expect(state(pane("dock", tab.a, in: tab)) == "tiled")
        #expect(state(pane("restore", tab.a, in: tab)) == "tiled", "nothing to restore")
        #expect(tab.controller.floatingCanvas.state(for: tab.a.id) == before)
    }

    @Test func withoutSelectTheKeyboardStaysWhereItWas() throws {
        let tab = try tab()
        defer { close(tab) }
        tab.controller.focusedSurface = tab.a
        #expect(state(pane("float", tab.b, in: tab, ["select": .bool(false)])) == "floating")
        #expect(tab.controller.focusedSurface === tab.a)
        #expect(state(pane("maximize", tab.b, in: tab, ["select": .bool(false)])) == "maximized")
        #expect(tab.controller.focusedSurface === tab.a)
        // Minimizing the pane that has the keyboard hands it to the next one.
        #expect(state(pane("minimize", tab.a, in: tab, ["select": .bool(false)])) == "minimized")
        #expect(tab.controller.focusedSurface === tab.b)
    }

    @Test func aClickLikeChangeBringsThePaneForward() throws {
        let tab = try tab()
        defer { close(tab) }
        tab.controller.focusedSurface = tab.a
        #expect(state(pane("float", tab.b, in: tab)) == "floating")
        #expect(tab.controller.focusedSurface === tab.b)
        #expect(tab.controller.floatingCanvas.topmostVisiblePane?.surfaceId == tab.b.id)
    }

    @Test func badRequestsAreRefusedAndChangeNothing() throws {
        let tab = try tab()
        defer { close(tab) }
        #expect(failure(pane("set", tab.b, in: tab))?.contains("needs a state") == true)
        #expect(failure(pane("set", tab.b, in: tab, ["state": .string("sideways")]))?.contains("unknown pane state") == true)
        #expect(failure(pane("spin", tab.b, in: tab))?.contains("unknown pane action") == true)
        #expect(failure(pane("move", tab.b, in: tab, ["window": .string("window-1")]))?.contains("not supported") == true)
        #expect(state(pane("state", tab.b, in: tab)) == "tiled")
    }

    @Test func theTreeSaysEachPanesState() throws {
        let tab = try tab()
        defer { close(tab) }
        _ = pane("minimize", tab.b, in: tab, ["select": .bool(false)])
        let tree = ControlCommands.tree(tab.all, active: nil)
        let panes = tree["windows"]?.array?.first?.object?["tabs"]?.array?.first?.object?["panes"]?.array ?? []
        let states = Dictionary(uniqueKeysWithValues: panes.compactMap { pane -> (String, String)? in
            guard let id = pane.object?["id"]?.string, let state = pane.object?["state"]?.string else { return nil }
            return (id, state)
        })
        #expect(states[tab.a.id.uuidString.lowercased()] == "tiled")
        #expect(states[tab.b.id.uuidString.lowercased()] == "minimized")
    }

    @Test func aFrameFloatsThePaneThereAsDraggingDoes() throws {
        let tab = try tab()
        defer { close(tab) }
        let frame: [JSON] = [.number(40), .number(60), .number(420), .number(300)]
        guard case .ok(let set) = pane("frame", tab.b, in: tab, ["frame": .array(frame)]) else {
            Issue.record("pane frame failed")
            return
        }
        #expect(set["state"]?.string == "floating" && set["grid"]?.bool == false)
        #expect(set["rect"]?.object?["width"]?.number == 420 && set["frame"]?.object?["x"]?.number == 40)
        let huge: [JSON] = [.number(-500), .number(0), .number(420), .number(300)]
        _ = pane("frame", tab.b, in: tab, ["frame": .array(huge)])
        #expect((tab.controller.floatingCanvas.state(for: tab.b.id)?.rect.minX ?? -1) >= 0, "clamped to the tab")
        let tiny: [JSON] = [.number(0), .number(0), .number(120), .number(80)]
        #expect(failure(pane("frame", tab.b, in: tab, ["frame": .array(tiny)]))?.contains("at least 260") == true)
        _ = pane("minimize", tab.b, in: tab)
        #expect(failure(pane("frame", tab.b, in: tab, ["frame": .array(frame)]))?.contains("restore it") == true)
    }

    @Test func stateNamesGridMembershipAndWhatTheShelfGivesBack() throws {
        let tab = try tab()
        defer { close(tab) }
        _ = pane("maximize", tab.a, in: tab)
        _ = pane("minimize", tab.a, in: tab)
        guard case .ok(let state) = pane("state", tab.a, in: tab) else {
            Issue.record("pane state failed")
            return
        }
        #expect(state["grid"]?.bool == true, "still a tile underneath")
        #expect(state["restoresMaximized"]?.bool == true && state["restoresTo"]?.string == "maximized")
        #expect(state["frame"] == nil && state["zOrder"]?.number != nil)
    }

    @Test func writingIntoAPaneOnTheShelfLeavesItThereAndTheKeyboardAlone() throws {
        let tab = try tab()
        defer { close(tab) }
        tab.controller.focusedSurface = tab.a
        // A live process to write to: these test panes start none of their own.
        tab.b.pty = PTY(cols: 80, rows: 24, workingDirectory: NSTemporaryDirectory(), program: ["/bin/sleep", "60"])
        defer { tab.b.pty?.terminate() }
        #expect(tab.b.pty?.alive == true)
        _ = pane("minimize", tab.b, in: tab, ["select": .bool(false)])
        let previous = ControlCommands.mode
        ControlCommands.mode = .on
        defer { ControlCommands.mode = previous }
        let sent = ControlCommands.handle(ControlRequest(cmd: "type", args: [
            "target": .string(tab.b.id.uuidString), "text": .string("echo hi")]), all: tab.all)
        if case .failure(let error) = sent { Issue.record("type failed: \(error.message)") }
        #expect(tab.controller.canvasMode(of: tab.b) == .minimized)
        #expect(tab.controller.focusedSurface === tab.a)
    }

    @Test func aSplitOpensStraightIntoItsStateAndSaysSo() throws {
        let tab = try tab()
        defer { close(tab) }
        let previous = ControlCommands.mode
        ControlCommands.mode = .on
        defer { ControlCommands.mode = previous }
        let refused = ControlCommands.handle(ControlRequest(cmd: "split", args: [
            "target": .string(tab.a.id.uuidString), "state": .string("sideways")]), all: tab.all)
        #expect(failure(refused)?.contains("unknown pane state") == true)
        #expect(Array(tab.controller.surfaceTree).count == 2, "nothing was created")
        // With motion on, a state change would animate; a created pane must not.
        tab.controller.floatingCanvas.reduceMotionProvider = { false }
        let made = ControlCommands.handle(ControlRequest(cmd: "split", args: [
            "target": .string(tab.a.id.uuidString), "state": .string("floating"), "select": .bool(false)]), all: tab.all)
        guard case .ok(let result) = made, let id = result["id"]?.string.flatMap(UUID.init(uuidString:)) else {
            Issue.record("split failed: \(made)")
            return
        }
        #expect(result["state"]?.string == "floating")
        #expect(tab.controller.floatingCanvas.activeTransition?.surfaceId != id, "no animation from a tile it never was")
    }

    @Test func aPaneMovesToAWindowOfItsOwnButALonePaneDoesNot() throws {
        let previous = TerminalController.system
        TerminalController.system = TerminalTestSupport.injectedWindowSystem()
        defer { TerminalController.system = previous }
        let tab = try tab()
        defer { close(tab) }
        let pty = tab.b.pty
        guard case .ok(let result) = pane("move", tab.b, in: tab) else {
            Issue.record("pane move failed")
            return
        }
        #expect(result["window"]?.string?.hasPrefix("window-") == true)
        #expect(!tab.controller.surfaceTree.contains(tab.b))
        let moved = try #require(BaseTerminalController.owningController(for: tab.b))
        defer { moved.window?.close() }
        #expect(moved !== tab.controller && tab.b.pty === pty)
        let source = tab.window.stableTabIdentifier, destination = try #require(moved.window).stableTabIdentifier
        #expect(WorkspaceStore.shared.workspace(forTab: destination)?.id == WorkspaceStore.shared.workspace(forTab: source)?.id,
                "the new window stays in the pane's workspace")
        let lone = ControlCommands.Pane(surface: tab.b, windowID: "w2", tabID: "t2", controller: moved)
        let previousMode = ControlCommands.mode
        ControlCommands.mode = .on
        defer { ControlCommands.mode = previousMode }
        let again = ControlCommands.handle(ControlRequest(cmd: "pane", args: [
            "action": .string("move"), "target": .string(tab.b.id.uuidString)]), all: [lone])
        #expect(failure(again)?.contains("alone in its tab") == true)
    }
}
