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

@Suite(.serialized)
@MainActor
struct PromptTests {
    private func makeSurface(
        title: String = "Test Pane",
        pwd: String = "/Users/alex/tako"
    ) -> (Tako.SurfaceView, BaseTerminalController) {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        view.title = title
        view.pwd = pwd
        let tree = SplitTree<Tako.SurfaceView>(view: view)
        let controller = BaseTerminalController(Tako.App(), surfaceTree: tree)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        win.windowController = controller
        controller.window = win
        return (view, controller)
    }

    @Test func choicePromptSetsWaitingForInputAndResolvesWithChoice() throws {
        PromptManager.shared.reset()
        NotificationStore.shared.clear()
        let (surface, _controller) = makeSurface()

        var answeredResult: ControlResponse?
        let req = ControlRequest(
            cmd: "ask",
            args: [
                "message": .string("Which database?"),
                "choices": .array([.string("postgres"), .string("sqlite")]),
                "title": .string("DB Setup")
            ],
            from: nil
        )

        try PromptManager.shared.ask(request: req, surface: surface) { response in
            answeredResult = response
        }

        #expect(surface.crab.paneStatus == .waitingForInput)
        #expect(surface.crab.statusText == "Which database?")
        #expect(NotificationStore.shared.records.count == 1)
        #expect(NotificationStore.shared.records.first?.body == "Which database?")
        #expect(PromptManager.shared.activeCount == 1)

        let prompt = try #require(PromptManager.shared.activePrompts(for: surface.id).first)
        #expect(prompt.title == "DB Setup")
        #expect(prompt.type == .choice(choices: ["postgres", "sqlite"]))

        // Answer with index 1 ("sqlite")
        PromptManager.shared.answerChoice(promptId: prompt.id, index: 1)

        let resp = try #require(answeredResult)
        guard case .ok(let dict) = resp else {
            Issue.record("Expected .ok response")
            return
        }
        #expect(dict["answer"] == .string("sqlite"))
        #expect(dict["choice"] == .string("sqlite"))
        #expect(dict["index"] == .number(1))
        #expect(dict["type"] == .string("choice"))

        // Status restored / cleared
        #expect(surface.crab.paneStatus != .waitingForInput)
        #expect(PromptManager.shared.activeCount == 0)
        #expect(NotificationStore.shared.records.first?.unread == false)
    }

    @Test func confirmPromptAnswersWithConfirmation() throws {
        PromptManager.shared.reset()
        let (surface, _controller) = makeSurface()

        var answeredResult: ControlResponse?
        let req = ControlRequest(
            cmd: "ask",
            args: [
                "message": .string("Deploy now?"),
                "confirm": .bool(true),
                "confirm_text": .string("Ship"),
                "cancel_text": .string("Abort")
            ],
            from: nil
        )

        try PromptManager.shared.ask(request: req, surface: surface) { response in
            answeredResult = response
        }

        let prompt = try #require(PromptManager.shared.activePrompts(for: surface.id).first)
        #expect(prompt.type == .confirm(confirmText: "Ship", cancelText: "Abort"))

        PromptManager.shared.answerConfirm(promptId: prompt.id, confirmed: true, text: "Ship")

        let resp = try #require(answeredResult)
        guard case .ok(let dict) = resp else {
            Issue.record("Expected .ok response")
            return
        }
        #expect(dict["answer"] == .string("Ship"))
        #expect(dict["confirmed"] == .bool(true))
        #expect(dict["type"] == .string("confirm"))
    }

    @Test func textPromptAnswersWithUserText() throws {
        PromptManager.shared.reset()
        let (surface, _controller) = makeSurface()

        var answeredResult: ControlResponse?
        let req = ControlRequest(
            cmd: "ask",
            args: [
                "message": .string("Enter branch name"),
                "placeholder": .string("feat/...")
            ],
            from: nil
        )

        try PromptManager.shared.ask(request: req, surface: surface) { response in
            answeredResult = response
        }

        let prompt = try #require(PromptManager.shared.activePrompts(for: surface.id).first)
        #expect(prompt.type == .text(placeholder: "feat/...", defaultText: ""))

        PromptManager.shared.answerText(promptId: prompt.id, text: "feat/login")

        let resp = try #require(answeredResult)
        guard case .ok(let dict) = resp else {
            Issue.record("Expected .ok response")
            return
        }
        #expect(dict["answer"] == .string("feat/login"))
        #expect(dict["type"] == .string("text"))
    }

    @Test func timeoutWithDefaultValueReturnsSuccess() throws {
        PromptManager.shared.reset()
        let (surface, _controller) = makeSurface()

        var answeredResult: ControlResponse?
        let req = ControlRequest(
            cmd: "ask",
            args: [
                "message": .string("Continue?"),
                "default": .string("yes"),
                "timeout": .number(0.05) // 50ms timeout
            ],
            from: nil
        )

        try PromptManager.shared.ask(request: req, surface: surface) { response in
            answeredResult = response
        }

        let prompt = try #require(PromptManager.shared.activePrompts(for: surface.id).first)
        #expect(prompt.defaultValue == "yes")

        // Wait for timeout to expire (0.05s)
        let deadline = Date().addingTimeInterval(0.6)
        while answeredResult == nil && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        let resp = try #require(answeredResult)
        guard case .ok(let dict) = resp else {
            Issue.record("Expected .ok response with default value on timeout")
            return
        }
        #expect(dict["answer"] == .string("yes"))
        #expect(dict["default"] == .bool(true))
    }

    @Test func timeoutWithoutDefaultReturnsFailure() throws {
        PromptManager.shared.reset()
        let (surface, _controller) = makeSurface()

        var answeredResult: ControlResponse?
        let req = ControlRequest(
            cmd: "ask",
            args: [
                "message": .string("Pick a color"),
                "choices": .array([.string("red"), .string("blue")]),
                "timeout": .number(0.05) // 50ms timeout
            ],
            from: nil
        )

        try PromptManager.shared.ask(request: req, surface: surface) { response in
            answeredResult = response
        }

        let deadline = Date().addingTimeInterval(0.6)
        while answeredResult == nil && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        let resp = try #require(answeredResult)
        guard case .failure(let err) = resp else {
            Issue.record("Expected .failure response on timeout")
            return
        }
        #expect(err.code == .timeout)
    }

    @Test func paneClosedFailsActivePromptsWithNotFound() throws {
        PromptManager.shared.reset()
        let (surface, _controller) = makeSurface()

        var answeredResult: ControlResponse?
        let req = ControlRequest(
            cmd: "ask",
            args: ["message": .string("Waiting...")],
            from: nil
        )

        try PromptManager.shared.ask(request: req, surface: surface) { response in
            answeredResult = response
        }

        #expect(PromptManager.shared.activeCount == 1)

        // Close pane
        PromptManager.shared.paneClosed(surfaceId: surface.id)

        let resp = try #require(answeredResult)
        guard case .failure(let err) = resp else {
            Issue.record("Expected .failure on pane closure")
            return
        }
        #expect(err.code == .notFound)
        #expect(PromptManager.shared.activeCount == 0)
    }

    @Test func cancelPromptFailsWithInvalid() throws {
        PromptManager.shared.reset()
        let (surface, _controller) = makeSurface()

        var answeredResult: ControlResponse?
        let req = ControlRequest(
            cmd: "ask",
            args: ["message": .string("Cancel me")],
            from: nil
        )

        try PromptManager.shared.ask(request: req, surface: surface) { response in
            answeredResult = response
        }

        let prompt = try #require(PromptManager.shared.activePrompts(for: surface.id).first)
        PromptManager.shared.cancel(promptId: prompt.id, reason: "user dismissed")

        let resp = try #require(answeredResult)
        guard case .failure(let err) = resp else {
            Issue.record("Expected .failure on cancel")
            return
        }
        #expect(err.code == .invalid)
    }

    @Test func clientDisconnectResolvesPromptAndCleansUpState() throws {
        PromptManager.shared.reset()
        let (surface, _controller) = makeSurface()

        var answeredResult: ControlResponse?
        nonisolated(unsafe) var isClientGone = false
        var req = ControlRequest(
            cmd: "ask",
            args: ["message": .string("Are you there?")],
            from: nil
        )
        req.clientGone = { isClientGone }

        try PromptManager.shared.ask(request: req, surface: surface) { response in
            answeredResult = response
        }

        #expect(PromptManager.shared.activeCount == 1)
        #expect(surface.crab.paneStatus == .waitingForInput)

        // Simulate client process death / socket disconnect
        isClientGone = true

        let deadline = Date().addingTimeInterval(1.0)
        while answeredResult == nil && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        let resp = try #require(answeredResult)
        guard case .failure(let err) = resp else {
            Issue.record("Expected .failure when client disconnects")
            return
        }
        #expect(err.code == .timeout)
        #expect(err.message.contains("disconnected"))
        #expect(PromptManager.shared.activeCount == 0)
        #expect(surface.crab.paneStatus != .waitingForInput)
    }

    @Test func multiplePromptsInWindowIsolateDialogDismissal() throws {
        PromptManager.shared.reset()
        let (surface, controller) = makeSurface()
        guard let win = controller.window else {
            Issue.record("Window missing")
            return
        }

        var answeredResult1: ControlResponse?
        var answeredResult2: ControlResponse?

        let req1 = ControlRequest(
            cmd: "ask",
            args: ["message": .string("Question 1"), "confirm": .bool(true)],
            from: nil
        )
        let req2 = ControlRequest(
            cmd: "ask",
            args: ["message": .string("Question 2"), "confirm": .bool(true)],
            from: nil
        )

        try PromptManager.shared.ask(request: req1, surface: surface) { resp in
            answeredResult1 = resp
        }
        try PromptManager.shared.ask(request: req2, surface: surface) { resp in
            answeredResult2 = resp
        }

        #expect(PromptManager.shared.activeCount == 2)
        let prompt1 = try #require(PromptManager.shared.activePrompts(for: surface.id).first { $0.message == "Question 1" })
        let prompt2 = try #require(PromptManager.shared.activePrompts(for: surface.id).first { $0.message == "Question 2" })

        // Resolving prompt 1 does not fail or resolve prompt 2
        PromptManager.shared.answerConfirm(promptId: prompt1.id, confirmed: true, text: "Confirm")

        let resp1 = try #require(answeredResult1)
        guard case .ok(let dict1) = resp1 else {
            Issue.record("Expected prompt 1 to be answered")
            return
        }
        #expect(dict1["answer"] == .string("Confirm"))
        #expect(answeredResult2 == nil)
        #expect(PromptManager.shared.activeCount == 1)
        #expect(PromptManager.shared.activePrompt(for: prompt2.id) != nil)

        // Now resolve prompt 2
        PromptManager.shared.answerConfirm(promptId: prompt2.id, confirmed: true, text: "Confirm")
        let resp2 = try #require(answeredResult2)
        guard case .ok = resp2 else {
            Issue.record("Expected prompt 2 to be answered")
            return
        }
        #expect(PromptManager.shared.activeCount == 0)
    }
}
