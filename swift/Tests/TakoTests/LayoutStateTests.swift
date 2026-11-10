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
