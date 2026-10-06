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

@Suite
@MainActor
struct ProgressTests {
    @Test func allFourProgressStatesAndClear() {
        let tracker = Tako.CrabTracker()

        #expect(tracker.progressState == .none)
        #expect(tracker.progress == nil)

        // State 1: normal
        tracker.progressReported(state: 1, value: 50)
        #expect(tracker.progressState == .normal)
        #expect(tracker.progress == 50)

        // State 2: error
        tracker.progressReported(state: 2, value: 80)
        #expect(tracker.progressState == .error)
        #expect(tracker.progress == 80)

        // State 3: indeterminate
        tracker.progressReported(state: 3, value: nil)
        #expect(tracker.progressState == .indeterminate)
        #expect(tracker.progress == nil)

        // State 4: paused
        tracker.progressReported(state: 4, value: 30)
        #expect(tracker.progressState == .paused)
        #expect(tracker.progress == 30)

        // State 0: clear / none
        tracker.progressReported(state: 0, value: nil)
        #expect(tracker.progressState == .none)
        #expect(tracker.progress == nil)

        // Unknown state: resets to none
        tracker.progressReported(state: 1, value: 90)
        tracker.progressReported(state: 99, value: 50)
        #expect(tracker.progressState == .none)
        #expect(tracker.progress == nil)
    }

    @Test func commandEndAndConnectionLostClearsProgress() {
        let tracker = Tako.CrabTracker()

        // Command finish clears progress
        tracker.progressReported(state: 1, value: 75)
        #expect(tracker.progress == 75)
        tracker.commandEnded(exitCode: 0)
        #expect(tracker.progressState == .none)
        #expect(tracker.progress == nil)

        // Connection lost clears progress
        tracker.progressReported(state: 4, value: 25)
        #expect(tracker.progress == 25)
        tracker.connectionLost()
        #expect(tracker.progressState == .none)
        #expect(tracker.progress == nil)
    }

    @Test func paneProgressBarRenderingAndStyles() {
        let view = TakoTerminalNSView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        view.layout()

        #expect(view.paneProgressBarLayer.isHidden == true)

        // Normal state (green)
        view.updateProgressBar(state: .normal, progress: 50)
        #expect(view.paneProgressBarLayer.isHidden == false)
        #expect(view.activeProgressState == .normal)
        #expect(view.activeProgressValue == 50)
        #expect(view.paneProgressBarLayer.frame.width == 200.0) // 50% of 400

        // Error state (red)
        view.updateProgressBar(state: .error, progress: 25)
        #expect(view.paneProgressBarLayer.isHidden == false)
        #expect(view.activeProgressState == .error)
        #expect(view.paneProgressBarLayer.frame.width == 100.0) // 25% of 400

        // Paused state (orange)
        view.updateProgressBar(state: .paused, progress: 75)
        #expect(view.paneProgressBarLayer.isHidden == false)
        #expect(view.activeProgressState == .paused)
        #expect(view.paneProgressBarLayer.frame.width == 300.0) // 75% of 400

        // Indeterminate state (centered, 35% width)
        view.updateProgressBar(state: .indeterminate, progress: nil)
        #expect(view.paneProgressBarLayer.isHidden == false)
        #expect(view.activeProgressState == .indeterminate)
        let expectedWidth: CGFloat = 400.0 * 0.35 // 140
        #expect(view.paneProgressBarLayer.frame.width == expectedWidth)
        #expect(view.paneProgressBarLayer.frame.minX == (400.0 - expectedWidth) / 2)

        // None state (hidden)
        view.updateProgressBar(state: .none, progress: nil)
        #expect(view.paneProgressBarLayer.isHidden == true)

        // Disabling paneProgressBarEnabled hides the bar even if state != .none
        view.updateProgressBar(state: .normal, progress: 60)
        #expect(view.paneProgressBarLayer.isHidden == false)
        view.paneProgressBarEnabled = false
        #expect(view.paneProgressBarLayer.isHidden == true)
        view.paneProgressBarEnabled = true
        #expect(view.paneProgressBarLayer.isHidden == false)
    }

    @Test func aggregateProgressCalculationsAcrossPanes() {
        let app = Tako.App()
        let surface1 = Tako.SurfaceView(app, baseConfig: .init(), uuid: UUID())
        let surface2 = Tako.SurfaceView(app, baseConfig: .init(), uuid: UUID())
        let surface3 = Tako.SurfaceView(app, baseConfig: .init(), uuid: UUID())

        // Empty surfaces list
        #expect(Tako.CrabTabBinding.aggregateProgress(for: []) == nil)

        // All idle / none
        #expect(Tako.CrabTabBinding.aggregateProgress(for: [surface1, surface2, surface3]) == nil)

        // Normal averaging
        surface1.crab.progressReported(state: 1, value: 20)
        surface2.crab.progressReported(state: 1, value: 60)
        let agg1 = Tako.CrabTabBinding.aggregateProgress(for: [surface1, surface2, surface3])
        #expect(agg1?.state == .normal)
        #expect(agg1?.progress == 40) // (20 + 60) / 2

        // Paused takes precedence over normal
        surface3.crab.progressReported(state: 4, value: 80)
        let agg2 = Tako.CrabTabBinding.aggregateProgress(for: [surface1, surface2, surface3])
        #expect(agg2?.state == .paused)
        #expect(agg2?.progress == 80)

        // Error takes precedence over paused and normal
        surface2.crab.progressReported(state: 2, value: 10)
        let agg3 = Tako.CrabTabBinding.aggregateProgress(for: [surface1, surface2, surface3])
        #expect(agg3?.state == .error)
        #expect(agg3?.progress == 10)

        // Indeterminate when only indeterminate is reporting
        surface1.crab.progressReported(state: 0, value: nil)
        surface2.crab.progressReported(state: 0, value: nil)
        surface3.crab.progressReported(state: 3, value: nil)
        let agg4 = Tako.CrabTabBinding.aggregateProgress(for: [surface1, surface2, surface3])
        #expect(agg4?.state == .indeterminate)
        #expect(agg4?.progress == nil)
    }

    @Test func progressStyleConfigParsingAndOptionSet() throws {
        // Defaults to all
        let emptyConfig = Tako.Config()
        #expect(emptyConfig.progressStyle == .all)
        #expect(emptyConfig.progressStyle.showsInDock == true)
        #expect(emptyConfig.progressStyle.showsInTab == true)
        #expect(emptyConfig.progressStyle.showsInHeader == true)
        #expect(emptyConfig.progressStyle.showsInWindow == true)
        #expect(emptyConfig.progressStyle == true)

        // Turn all off
        let offConfig = try TemporaryConfig("progress-style = none")
        #expect(offConfig.progressStyle == .none)
        #expect(offConfig.progressStyle.showsInDock == false)
        #expect(offConfig.progressStyle.showsInTab == false)
        #expect(offConfig.progressStyle.showsInHeader == false)
        #expect(offConfig.progressStyle.showsInWindow == false)
        #expect(offConfig.progressStyle == false)

        // Turn all off with false
        let falseConfig = try TemporaryConfig("progress-style = false")
        #expect(falseConfig.progressStyle == .none)

        // Specific surfaces
        let partialConfig = try TemporaryConfig("progress-style = dock, header")
        #expect(partialConfig.progressStyle.showsInDock == true)
        #expect(partialConfig.progressStyle.showsInHeader == true)
        #expect(partialConfig.progressStyle.showsInTab == false)
        #expect(partialConfig.progressStyle.showsInWindow == false)

        let tabWindowConfig = try TemporaryConfig("progress-style = tab, window")
        #expect(tabWindowConfig.progressStyle.showsInDock == false)
        #expect(tabWindowConfig.progressStyle.showsInHeader == false)
        #expect(tabWindowConfig.progressStyle.showsInTab == true)
        #expect(tabWindowConfig.progressStyle.showsInWindow == true)
    }

    @Test func controlCommandsProgressIPC() {
        let oldMode = ControlCommands.mode
        ControlCommands.mode = .on
        defer { ControlCommands.mode = oldMode }

        let app = Tako.App()
        let surface = Tako.SurfaceView(app, baseConfig: .init(), uuid: UUID())
        let controller = TerminalController(app)
        let pane = ControlCommands.Pane(surface: surface, windowID: "w1", tabID: "t1", controller: controller)

        // Set normal progress
        let setReq = ControlRequest(
            cmd: "progress",
            args: ["target": .string(surface.id.uuidString), "action": .string("set"), "value": .number(65)],
            from: nil)
        let setRes = ControlCommands.handle(setReq, all: [pane])
        if case .ok(let dict) = setRes {
            #expect(dict["state"] == .string("normal"))
            #expect(dict["progress"] == .number(65))
        } else {
            Issue.record("Expected ok response for progress set")
        }
        #expect(surface.crab.progressState == .normal)
        #expect(surface.crab.progress == 65)

        // Get progress
        let getReq = ControlRequest(
            cmd: "progress",
            args: ["target": .string(surface.id.uuidString), "action": .string("get")],
            from: nil)
        let getRes = ControlCommands.handle(getReq, all: [pane])
        if case .ok(let dict) = getRes {
            #expect(dict["state"] == .string("normal"))
            #expect(dict["progress"] == .number(65))
        } else {
            Issue.record("Expected ok response for progress get")
        }

        // Direct number action (e.g. action: "45")
        let numReq = ControlRequest(
            cmd: "progress",
            args: ["target": .string(surface.id.uuidString), "action": .string("45")],
            from: nil)
        let numRes = ControlCommands.handle(numReq, all: [pane])
        if case .ok(let dict) = numRes {
            #expect(dict["state"] == .string("normal"))
            #expect(dict["progress"] == .number(45))
        } else {
            Issue.record("Expected ok response for numeric progress action")
        }
        #expect(surface.crab.progress == 45)

        // Set error
        let errReq = ControlRequest(
            cmd: "progress",
            args: ["target": .string(surface.id.uuidString), "action": .string("error"), "value": .number(90)],
            from: nil)
        let errRes = ControlCommands.handle(errReq, all: [pane])
        if case .ok(let dict) = errRes {
            #expect(dict["state"] == .string("error"))
            #expect(dict["progress"] == .number(90))
        } else {
            Issue.record("Expected ok response for progress error")
        }
        #expect(surface.crab.progressState == .error)

        // Set indeterminate
        let indetReq = ControlRequest(
            cmd: "progress",
            args: ["target": .string(surface.id.uuidString), "action": .string("indeterminate")],
            from: nil)
        let indetRes = ControlCommands.handle(indetReq, all: [pane])
        if case .ok(let dict) = indetRes {
            #expect(dict["state"] == .string("indeterminate"))
        } else {
            Issue.record("Expected ok response for progress indeterminate")
        }
        #expect(surface.crab.progressState == .indeterminate)

        // Set pause
        let pauseReq = ControlRequest(
            cmd: "progress",
            args: ["target": .string(surface.id.uuidString), "action": .string("pause"), "value": .number(20)],
            from: nil)
        let pauseRes = ControlCommands.handle(pauseReq, all: [pane])
        if case .ok(let dict) = pauseRes {
            #expect(dict["state"] == .string("paused"))
            #expect(dict["progress"] == .number(20))
        } else {
            Issue.record("Expected ok response for progress pause")
        }
        #expect(surface.crab.progressState == .paused)

        // Clear
        let clearReq = ControlRequest(
            cmd: "progress",
            args: ["target": .string(surface.id.uuidString), "action": .string("clear")],
            from: nil)
        let clearRes = ControlCommands.handle(clearReq, all: [pane])
        if case .ok(let dict) = clearRes {
            #expect(dict["state"] == .string("none"))
        } else {
            Issue.record("Expected ok response for progress clear")
        }
        #expect(surface.crab.progressState == .none)
        #expect(surface.crab.progress == nil)

        // Invalid action
        let badReq = ControlRequest(
            cmd: "progress",
            args: ["target": .string(surface.id.uuidString), "action": .string("invalid_action")],
            from: nil)
        let badRes = ControlCommands.handle(badReq, all: [pane])
        if case .failure(let err) = badRes {
            #expect(err.code == .invalid)
        } else {
            Issue.record("Expected failure response for invalid progress action")
        }
    }
}
