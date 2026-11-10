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

/// `takoctl window`: windows by the id `tree` gives them, their frame,
/// new windows in a given pane state, and closing one the way ⇧⌘W does.
@MainActor @Suite(.serialized)
struct ControlWindowTests {
    private func send(_ args: [String: JSON], _ all: [ControlCommands.Pane]) -> ControlResponse {
        let previous = ControlCommands.mode
        ControlCommands.mode = .on
        defer { ControlCommands.mode = previous }
        return ControlCommands.handle(ControlRequest(cmd: "window", args: args), all: all)
    }

    private func panes(_ controller: TerminalController) -> [ControlCommands.Pane] {
        Array(controller.surfaceTree).map {
            ControlCommands.Pane(surface: $0, windowID: "w", tabID: "t", controller: controller)
        }
    }

    private func result(_ response: ControlResponse) -> [String: JSON]? {
        if case .ok(let result) = response { return result }
        return nil
    }

    private func failure(_ response: ControlResponse) -> String? {
        if case .failure(let error) = response { return error.message }
        return nil
    }

    @Test func aWindowIsListedAndNamedAsTheTreeNamesIt() throws {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { window.close(); TerminalTestSupport.tearDown(controller, window) }
        let all = panes(controller)
        let id = ControlCommands.windowID(window)
        let listed = result(send(["action": .string("list")], all))?["windows"]?.array ?? []
        #expect(listed.contains { $0.object?["id"]?.string == id })
        let state = try #require(result(send(["action": .string("state")], all)))
        #expect(state["id"]?.string == id && state["tabs"]?.number == 1)
        #expect(ControlCommands.tree(all, active: nil)["windows"]?.array?.isEmpty == false)
        #expect(failure(send(["action": .string("state"), "window": .string("window-nope")], all))?
            .contains("no window window-nope") == true)
    }

    @Test func theFrameIsReadAndSetInScreenPoints() throws {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { window.close(); TerminalTestSupport.tearDown(controller, window) }
        let all = panes(controller)
        let frame: [JSON] = [.number(120), .number(140), .number(900), .number(560)]
        let set = try #require(result(send(["action": .string("frame"), "frame": .array(frame)], all)))
        #expect(window.frame == NSRect(x: 120, y: 140, width: 900, height: 560))
        #expect(set["frame"]?.object?["width"]?.number == 900)
        let read = try #require(result(send(["action": .string("frame")], all)))
        #expect(read["frame"]?.object?["x"]?.number == 120)
        let tiny: [JSON] = [.number(0), .number(0), .number(40), .number(40)]
        #expect(failure(send(["action": .string("frame"), "frame": .array(tiny)], all))?.contains("at least") == true)
        #expect(failure(send(["action": .string("frame"), "frame": .array([.number(1)])], all))?.contains("four numbers") == true)
        #expect(window.frame.width == 900, "a refused frame changes nothing")
    }

    @Test func fullscreenSaysOnOffOrToggle() throws {
        #expect(try ControlCommands.fullscreenWanted([:], now: false))
        #expect(try !ControlCommands.fullscreenWanted([:], now: true))
        #expect(try ControlCommands.fullscreenWanted(["value": .string("on")], now: true))
        #expect(try !ControlCommands.fullscreenWanted(["value": .string("off")], now: false))
        #expect(throws: ControlError.self) { try ControlCommands.fullscreenWanted(["value": .string("maybe")], now: false) }
        let (controller, window) = TerminalTestSupport.loaded()
        defer { window.close(); TerminalTestSupport.tearDown(controller, window) }
        // Already out of full screen: off is answered without a transition.
        let off = try #require(result(send(["action": .string("fullscreen"), "value": .string("off")], panes(controller))))
        #expect(off["fullscreen"]?.bool == false)
    }

    @Test func aNewWindowOpensWithItsPaneInTheStateAsked() throws {
        let previous = TerminalController.system
        TerminalController.system = TerminalTestSupport.injectedWindowSystem()
        defer { TerminalController.system = previous }
        let (controller, window) = TerminalTestSupport.loaded()
        defer { window.close(); TerminalTestSupport.tearDown(controller, window) }
        let all = panes(controller)
        #expect(failure(send(["action": .string("new"), "state": .string("upside-down")], all))?
            .contains("unknown pane state") == true)
        let made = try #require(result(send(["action": .string("new"), "state": .string("maximized")], all)))
        let id = try #require(made["id"]?.string.flatMap(UUID.init(uuidString:)))
        let created = try #require(TerminalController.all.first { controller in
            controller.surfaceTree.contains { $0.id == id }
        })
        defer { created.window?.close() }
        let pane = try #require(created.surfaceTree.first)
        #expect(created.canvasMode(of: pane) == .maximized)
        #expect(made["window"]?.string == created.window.map(ControlCommands.windowID))
    }

    @Test func closingAWindowAnswersOnceItHasGone() async throws {
        let previous = TerminalController.system
        TerminalController.system = TerminalTestSupport.injectedWindowSystem()
        defer { TerminalController.system = previous }
        let (keep, keepWindow) = TerminalTestSupport.loaded()
        defer { keepWindow.close(); TerminalTestSupport.tearDown(keep, keepWindow) }
        let (controller, window) = TerminalTestSupport.loaded()
        controller.showWindow(nil)
        let all = panes(controller)
        let previousMode = ControlCommands.mode
        ControlCommands.mode = .on
        defer { ControlCommands.mode = previousMode }
        let answer: ControlResponse = await withCheckedContinuation { done in
            ControlCommands.handle(ControlRequest(cmd: "window", args: ["action": .string("close")]), all: all) {
                done.resume(returning: $0)
            }
        }
        #expect(result(answer)?["state"]?.string == "closed")
        #expect(!window.isVisible)
    }

    @Test func requestedFramesAreFourSaneNumbers() throws {
        #expect(try ControlCommands.requestedFrame([:]) == nil)
        let frame = try ControlCommands.requestedFrame(["frame": .array([.number(-50), .number(0), .number(800), .number(600)])])
        #expect(frame == NSRect(x: -50, y: 0, width: 800, height: 600), "a second screen may be left of the first")
        #expect(throws: ControlError.self) {
            try ControlCommands.requestedFrame(["frame": .array([.number(0), .number(0), .number(.infinity), .number(600)])])
        }
        #expect(throws: ControlError.self) { try ControlCommands.requestedFrame(["frame": .string("0,0,800,600")]) }
    }
}
