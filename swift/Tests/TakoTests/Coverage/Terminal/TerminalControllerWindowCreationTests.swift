/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Testing
import AppKit
@testable import Tako
@testable import TakoKit

@MainActor
struct TerminalControllerWindowNibNameConfigTests {
    @Test func windowDecorationsFalseReturnsTheDefaultNib() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("tako-\(UUID().uuidString).conf")
        try "window-decoration = none".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        setenv("TAKO_CONFIG_PATH", file.path, 1)
        defer { unsetenv("TAKO_CONFIG_PATH") }

        try withRealAppDelegate { _ in
            let (controller, window) = TerminalTestSupport.makeController()
            defer { TerminalTestSupport.tearDown(controller, window) }
            #expect(controller.windowNibName == "Terminal")
        }
    }
}

@MainActor
struct TerminalControllerDerivedConfigDefaultTests {
    @Test func defaultInitUsesSystemDefaults() {
        let config = TerminalController.DerivedConfig()
        #expect(config.macosWindowButtons == .visible)
        #expect(config.macosTitlebarStyle == .default)
        #expect(config.maximize == false)
        #expect(config.windowPositionX == nil)
        #expect(config.windowPositionY == nil)
    }
}

@MainActor
struct TerminalControllerNewWindowSchedulingTests {
    @Test func newWindowSchedulesPresentationAndBecomesVisible() async throws {
        try await withInjectedWindowSystem {
            let app = Tako.App()
            let controller = TerminalController.newWindow(app)
            defer { controller.window.map { TerminalTestSupport.tearDown(controller, $0) } }

            for _ in 0..<200 where controller.window?.isVisible != true {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(controller.window?.isVisible == true)
        }
    }

    @Test func newWindowRegistersUndoThatClosesAndRedoThatRecreates() async throws {
        try await withRealAppDelegate { appDelegate in
            try await withInjectedWindowSystem {
                let controller = TerminalController.newWindow(appDelegate.tako)
                for _ in 0..<200 where controller.window?.isVisible != true {
                    try await Task.sleep(nanoseconds: 10_000_000)
                }

                let undoManager = try #require(controller.undoManager)
                #expect(undoManager.canUndo)
                undoManager.undo()
                #expect(controller.window?.isVisible != true)

                #expect(undoManager.canRedo)
                undoManager.redo()
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    @Test func newWindowWithTreePositionsAndSchedulesPresentation() async throws {
        try await withInjectedWindowSystem {
            let app = Tako.App()
            let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
            let tree = SplitTree(view: view)
            let controller = TerminalController.newWindow(app, tree: tree, position: NSPoint(x: 50, y: 50))
            defer { controller.window.map { TerminalTestSupport.tearDown(controller, $0) } }

            for _ in 0..<200 where controller.window?.isVisible != true {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(controller.window?.isVisible == true)
        }
    }

    @Test func newWindowWithTreeWithoutPositionCascades() async throws {
        try await withInjectedWindowSystem {
            let app = Tako.App()
            let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
            let tree = SplitTree(view: view)
            let controller = TerminalController.newWindow(app, tree: tree)
            defer { controller.window.map { TerminalTestSupport.tearDown(controller, $0) } }

            for _ in 0..<200 where controller.window?.isVisible != true {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(controller.window?.isVisible == true)
        }
    }

    @Test func newWindowWithTreeRegistersUndoAndRedoWhenConfirmUndoIsFalse() async throws {
        try await withRealAppDelegate { appDelegate in
            try await withInjectedWindowSystem {
                let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
                let tree = SplitTree(view: view)
                let controller = TerminalController.newWindow(appDelegate.tako, tree: tree, confirmUndo: false)
                for _ in 0..<200 where controller.window?.isVisible != true {
                    try await Task.sleep(nanoseconds: 10_000_000)
                }

                let undoManager = try #require(controller.undoManager)
                #expect(undoManager.canUndo)
                undoManager.undo()
                #expect(undoManager.canRedo)
                undoManager.redo()
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }
}

@MainActor
struct TerminalControllerNewTabSchedulingTests {
    @Test func newTabJoinsTheParentGroupAndSchedulesPresentation() async throws {
        try await withRealAppDelegate { appDelegate in
            let (parent, parentWindow) = TerminalTestSupport.loaded()
            defer { TerminalTestSupport.tearDown(parent, parentWindow) }
            parentWindow.orderFrontRegardless()

            try await withInjectedWindowSystem {
                let child = try #require(TerminalController.newTab(appDelegate.tako, from: parentWindow))
                defer { child.window.map { TerminalTestSupport.tearDown(child, $0) } }
                let childWindow = try #require(child.window)

                #expect(Tako.CustomTabGroup.group(for: parentWindow).windows.contains(childWindow))

                for _ in 0..<200 where child.window?.isVisible != true {
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                #expect(child.window?.isVisible == true)

                let undoManager = try #require(parent.undoManager)
                #expect(undoManager.canUndo)
                undoManager.undo()
                #expect(undoManager.canRedo)
                undoManager.redo()

                // The tab-labeling fixup is scheduled 0.1s out.
                try await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    @Test func newTabWithEndPositionJoinsAfterTheLastTab() async throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("tako-\(UUID().uuidString).conf")
        try "window-new-tab-position = end".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let app = Tako.App(configPath: file.path)

        try await withInjectedWindowSystem {
            let (parent, parentWindow) = TerminalTestSupport.loaded()
            defer { TerminalTestSupport.tearDown(parent, parentWindow) }
            parentWindow.orderFrontRegardless()

            let child = try #require(TerminalController.newTab(app, from: parentWindow))
            defer { child.window.map { TerminalTestSupport.tearDown(child, $0) } }

            for _ in 0..<200 where child.window?.isVisible != true {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            #expect(child.window?.isVisible == true)
        }
    }
}
