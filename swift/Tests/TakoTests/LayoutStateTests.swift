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
import Foundation
import Testing
@testable import Tako

/// Layout files say where each pane sits on its tab and how its window is
/// shown; a saved layout says it back, and a bad state opens nothing.
@MainActor @Suite(.serialized)
struct LayoutStateTests {
    private func document(_ json: String) throws -> LayoutDocument {
        try JSONDecoder().decode(LayoutDocument.self, from: Data(json.utf8))
    }

    @Test func statesSurviveAReadAndAWrite() throws {
        let doc = try document("""
        {"version": 1, "windows": [{"state": "fullscreen", "tabs": [{"root": {"direction": "horizontal", "ratio": 0.5,
          "left": {"cwd": "/tmp"}, "right": {"cwd": "/tmp", "state": "minimized"}}}]}]}
        """)
        #expect(doc.windows.first?.state == "fullscreen")
        #expect(doc.allPanes.map(\.state) == [nil, "minimized"])
        let full = try document("""
        {"version": 1, "windows": [], "tabs": [{"root": {"state": "minimized", "grid": false, "restoresMaximized": true,
          "rect": {"x": 10, "y": 20, "width": 400, "height": 300}}}]}
        """)
        let pane = try #require(full.allPanes.first)
        #expect(pane.grid == false && pane.restoresMaximized == true && pane.rect?.width == 400)
        #expect(try JSONDecoder().decode(LayoutDocument.self, from: JSONEncoder().encode(full)) == full)
        let again = try JSONDecoder().decode(LayoutDocument.self, from: JSONEncoder().encode(doc))
        #expect(again == doc)
        try LayoutManager.validateStates(doc)
    }

    @Test func anUnknownStateIsRefusedBeforeAnythingOpens() throws {
        let pane = try document(#"{"version": 1, "windows": [], "tabs": [{"root": {"state": "sideways"}}]}"#)
        #expect(throws: ControlError.self) { try LayoutManager.validateStates(pane) }
        let window = try document(#"{"version": 1, "windows": [{"state": "hidden", "tabs": [{"root": {}}]}]}"#)
        #expect(throws: ControlError.self) { try LayoutManager.validateStates(window) }
        #expect(throws: ControlError.self) { try LayoutManager.apply(document: pane, isTrusted: true, app: Tako.App()) }
    }

    private func threePanes() throws -> (TerminalController, NSWindow, [Tako.SurfaceView]) {
        let (controller, window) = TerminalTestSupport.loaded()
        window.setContentSize(NSSize(width: 1100, height: 700))
        controller.floatingCanvas.reduceMotionProvider = { true }
        let a = try #require(controller.focusedSurface)
        let b = try #require(controller.newSplit(at: a, direction: .right))
        _ = try #require(controller.newSplit(at: b, direction: .down))
        return (controller, window, Array(controller.surfaceTree))
    }

    @Test func aSavedTabOpensWithEveryPaneWhereItWasAndRestoresTheSame() throws {
        let (source, sourceWindow, s) = try threePanes()
        defer { sourceWindow.close(); TerminalTestSupport.tearDown(source, sourceWindow) }
        // s[1]: floating at its own rect, then on the shelf.
        _ = try ControlPaneState.setFrame(s[1], to: CGRect(x: 60, y: 80, width: 420, height: 300))
        source.setCanvasMode(s[1], to: .minimized, reveal: false)
        // s[2]: floating, maximized, then on the shelf.
        source.setCanvasMode(s[2], to: .floating, reveal: false)
        source.setCanvasMode(s[2], to: .maximized, reveal: false)
        source.setCanvasMode(s[2], to: .minimized, reveal: false)
        let doc = try LayoutManager.capture(window: sourceWindow)
        let reread = try JSONDecoder().decode(LayoutDocument.self, from: JSONEncoder().encode(doc))
        let tab = try #require(reread.effectiveWindows.first?.tabs.first)
        try LayoutManager.validateStates(reread)

        let (target, targetWindow, t) = try threePanes()
        defer { targetWindow.close(); TerminalTestSupport.tearDown(target, targetWindow) }
        LayoutPanePresentation.apply(tab, to: target)
        let a = source.floatingCanvas, b = target.floatingCanvas
        for (x, y) in zip(s, t) {
            #expect(target.canvasMode(of: y) == source.canvasMode(of: x))
            #expect(b.isTiled(y.id) == a.isTiled(x.id), "grid membership")
            #expect(b.state(for: y.id)?.restoreMode == a.state(for: x.id)?.restoreMode, "what the shelf gives back")
        }
        #expect(b.state(for: t[1].id)?.rect == a.state(for: s[1].id)?.rect, "its own rectangle")

        // Off the shelf: s[1] floats where it was; s[2] comes back maximized,
        // and out of maximized it floats, not a tile.
        let previous = ControlCommands.mode
        ControlCommands.mode = .on
        defer { ControlCommands.mode = previous }
        let all = t.map { ControlCommands.Pane(surface: $0, windowID: "w", tabID: "t", controller: target) }
        func pane(_ action: String, _ surface: Tako.SurfaceView) {
            let response = ControlCommands.handle(ControlRequest(cmd: "pane", args: [
                "action": .string(action), "target": .string(surface.id.uuidString), "select": .bool(false)]), all: all)
            if case .failure(let error) = response { Issue.record("pane \(action): \(error.message)") }
        }
        pane("restore", t[1])
        #expect(target.canvasMode(of: t[1]) == .floating)
        #expect(b.state(for: t[1].id)?.rect == a.state(for: s[1].id)?.rect)
        pane("restore", t[2])
        #expect(target.canvasMode(of: t[2]) == .maximized)
        pane("unmaximize", t[2])
        #expect(target.canvasMode(of: t[2]) == .floating && !b.isTiled(t[2].id),
                "a floating pane maximized goes back to floating, not to a tile")
    }

    @Test func aFileWithOnlyStatesKeepsItsOldMeaning() throws {
        let (controller, window, s) = try threePanes()
        defer { window.close(); TerminalTestSupport.tearDown(controller, window) }
        let doc = try document("""
        {"version": 1, "windows": [], "tabs": [{"root": {"direction": "horizontal", "ratio": 0.5,
          "left": {}, "right": {"direction": "vertical", "ratio": 0.5,
            "left": {"state": "floating"}, "right": {"state": "minimized"}}}}]}
        """)
        LayoutPanePresentation.apply(try #require(doc.tabs?.first), to: controller)
        #expect(controller.canvasMode(of: s[1]) == .floating)
        #expect(controller.canvasMode(of: s[2]) == .minimized)
        #expect(controller.floatingCanvas.isTiled(s[2].id), "minimized alone means a tile on the shelf")
    }

    @Test func contradictoryPresentationsAreRefused() throws {
        for pane in [#"{"state": "floating", "grid": true}"#, #"{"grid": false}"#,
                     #"{"state": "maximized", "restoresMaximized": true}"#,
                     #"{"state": "floating", "rect": {"x": 0, "y": 0, "width": 10, "height": 10}}"#] {
            let doc = try document(#"{"version": 1, "windows": [], "tabs": [{"root": "# + pane + #"}]}"#)
            #expect(throws: ControlError.self, "\(pane)") { try LayoutManager.validateStates(doc) }
        }
    }

    @Test func aSavedLayoutSaysWhichPanesAreOffTheGrid() throws {
        let (controller, window) = TerminalTestSupport.loaded()
        defer { window.close(); TerminalTestSupport.tearDown(controller, window) }
        window.setContentSize(NSSize(width: 1100, height: 700))
        controller.floatingCanvas.reduceMotionProvider = { true }
        let a = try #require(controller.focusedSurface)
        let b = try #require(controller.newSplit(at: a, direction: .right))
        let c = try #require(controller.newSplit(at: b, direction: .down))
        controller.setCanvasMode(b, to: .floating, reveal: false)
        controller.setCanvasMode(c, to: .minimized, reveal: false)
        let doc = try LayoutManager.capture(window: window)
        let states = Dictionary(uniqueKeysWithValues: zip(Array(controller.surfaceTree).map(\.id), doc.allPanes.map(\.state)))
        #expect(states[a.id] == .some(nil), "tiled is left out")
        #expect(states[b.id] == "floating")
        #expect(states[c.id] == "minimized")
        #expect(doc.windows.first?.state == nil)
    }
}
