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
import WebKit
@testable import Tako

/// A form in an overlay answers the agent that opened it: no script runs in
/// the page; the form submits to tako-submit:, the overlay takes that
/// navigation, and `overlay open --wait` gets the fields.
@Suite(.serialized) @MainActor
struct OverlayFormBridgeTests {
    private func url(_ s: String) -> URL { URL(string: s)! }

    @Test func fieldsAreReadInTheFormsOrderWithRepeatsAndFormEncoding() throws {
        let s = try OverlaySubmission.parse(url("tako-submit:?name=Alex+P%C3%A4&tags=a&tags=b&action=approve&empty=")).get()
        #expect(s.names == ["name", "tags", "action", "empty"])
        #expect(s.values["name"] == ["Alex Pä"])
        #expect(s.values["tags"] == ["a", "b"])
        #expect(s.json["tags"] == .array([.string("a"), .string("b")]))
        #expect(s.json["action"] == .string("approve"))
        #expect(s.json["empty"] == .string(""))
        // A literal plus arrives encoded.
        #expect(try OverlaySubmission.parse(url("tako-submit:?q=1%2B1")).get().values["q"] == ["1+1"])
    }

    @Test func aFormWithNoFieldsIsAnEmptySubmissionAndOtherURLsAreNone() throws {
        #expect(try OverlaySubmission.parse(url("tako-submit:")).get().names.isEmpty)
        #expect(OverlaySubmission.parse(url("https://example.com/?a=1")) == .failure(.notASubmission))
        #expect(OverlaySubmission.parse(url("tako-asset://local/x?a=1")) == .failure(.notASubmission))
    }

    @Test func moreThanTheBridgeTakesIsRefused() {
        let big = "tako-submit:?v=" + String(repeating: "x", count: OverlaySubmission.maxBytes)
        #expect(OverlaySubmission.parse(url(big)) == .failure(.tooLarge))
        let many = "tako-submit:?" + (0...OverlaySubmission.maxFields).map { "f\($0)=1" }.joined(separator: "&")
        #expect(OverlaySubmission.parse(url(many)) == .failure(.tooLarge))
    }

    @Test func theOverlaysPolicyLetsFormsSubmitOnlyToTheBridge() {
        let csp = DocumentRenderer.defaultCSP
        #expect(csp.contains("form-action tako-submit:"))
        #expect(!csp.contains("form-action 'none'"))
        #expect(csp.contains("script-src 'none'"), "still no script")
        #expect(csp.contains("connect-src 'none'"), "still no network")
    }

    // MARK: - The store

    private func overlayFile(_ html: String = "<form action=\"tako-submit:\"><button name=a value=1>Go</button></form>") throws -> (URL, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tako-form-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("form.html")
        try html.write(to: file, atomically: true, encoding: .utf8)
        return (dir, file)
    }

    @Test func aSubmissionReachesTheWaiterClosesTheOverlayAndIsKept() throws {
        let store = OverlayStore.shared
        store.reset()
        defer { store.reset() }
        let (dir, file) = try overlayFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pane = UUID()
        try store.openOverlay(paneId: pane, path: file.path, surfacePwd: dir.path)
        var outcomes: [OverlayOutcome] = []
        store.awaitOutcome(paneId: pane) { outcomes.append($0) }
        store.submit(paneId: pane, url: url("tako-submit:?a=1"))
        let expected = try OverlaySubmission.parse(url("tako-submit:?a=1")).get()
        #expect(outcomes == [.submitted(expected)])
        #expect(!store.hasOverlay(paneId: pane), "the form has done its work")
        #expect(store.lastSubmissions[pane] == expected)
        #expect(!store.isAwaited(paneId: pane))
    }

    @Test func closingReplacingOrASecondWaitEndsTheWaitWithoutASubmission() throws {
        let store = OverlayStore.shared
        store.reset()
        defer { store.reset() }
        let (dir, file) = try overlayFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pane = UUID()
        var outcomes: [String] = []
        try store.openOverlay(paneId: pane, path: file.path, surfacePwd: dir.path)
        store.awaitOutcome(paneId: pane) { _ in outcomes.append("first") }
        store.awaitOutcome(paneId: pane) { o in outcomes.append(o == .closed ? "second closed" : "second other") }
        #expect(outcomes == ["first"], "a second wait ends the first")
        try store.openOverlay(paneId: pane, path: file.path, surfacePwd: dir.path)
        #expect(outcomes == ["first", "second closed"], "an overlay opened over it ends its wait")
        store.awaitOutcome(paneId: pane) { o in outcomes.append(o == .closed ? "third closed" : "third other") }
        store.closeOverlay(paneId: pane)
        #expect(outcomes.last == "third closed")
        #expect(store.lastSubmissions[pane] == nil)
    }

    @Test func anOversizedFormIsRefusedAndTheOverlayStaysOpen() throws {
        let store = OverlayStore.shared
        store.reset()
        defer { store.reset() }
        let (dir, file) = try overlayFile()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pane = UUID()
        try store.openOverlay(paneId: pane, path: file.path, surfacePwd: dir.path)
        var outcome: OverlayOutcome?
        store.awaitOutcome(paneId: pane) { outcome = $0 }
        store.submit(paneId: pane, url: url("tako-submit:?v=" + String(repeating: "x", count: OverlaySubmission.maxBytes)))
        if case .refused = outcome {} else { Issue.record("expected a refusal, got \(String(describing: outcome))") }
        #expect(store.hasOverlay(paneId: pane))
    }

    // MARK: - WebKit, as the overlay configures it

    /// A real form, in a web view set up like the overlay's -- page script
    /// off, the overlay's CSP in the page -- submitted as a click would.
    @Test func aFormSubmittedInTheWebViewReachesTheStore() async throws {
        let store = OverlayStore.shared
        store.reset()
        defer { store.reset() }
        let html = """
        <form action="tako-submit:">
          <input name="who" value="Alex P">
          <label><input type="checkbox" name="tags" value="court" checked></label>
          <label><input type="checkbox" name="tags" value="urgent" checked></label>
          <select name="pick"><option>one</option><option selected>two</option></select>
          <button name="action" value="approve">Approve</button>
        </form>
        """
        let (dir, file) = try overlayFile(html)
        defer { try? FileManager.default.removeItem(at: dir) }
        let pane = UUID()
        let state = try store.openOverlay(paneId: pane, path: file.path, surfacePwd: dir.path)
        var outcome: OverlayOutcome?
        store.awaitOutcome(paneId: pane) { outcome = $0 }

        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        let coordinator = SandboxedWebView.Coordinator(overlay: state, theme: nil)
        webView.navigationDelegate = coordinator
        webView.loadHTMLString(DocumentRenderer.injectThemeAndCSP(into: html, theme: nil),
                               baseURL: URL(string: "tako-asset://local/")!)
        for _ in 0..<100 where webView.isLoading { try await Task.sleep(nanoseconds: 50_000_000) }
        // What a click on Approve does; page script stays off, this runs outside the page.
        _ = try? await webView.evaluateJavaScript(
            "document.forms[0].requestSubmit(document.querySelector('button'))", in: nil, contentWorld: .defaultClient)
        for _ in 0..<100 where outcome == nil { try await Task.sleep(nanoseconds: 50_000_000) }

        guard case .submitted(let s)? = outcome else { Issue.record("no submission: \(String(describing: outcome))"); return }
        #expect(s.names == ["who", "tags", "pick", "action"])
        #expect(s.values["who"] == ["Alex P"])
        #expect(s.values["tags"] == ["court", "urgent"])
        #expect(s.values["pick"] == ["two"])
        #expect(s.values["action"] == ["approve"])
        #expect(!store.hasOverlay(paneId: pane))
        _ = coordinator
    }

    // MARK: - takoctl overlay open --wait

    private final class Replies: @unchecked Sendable { var all: [ControlResponse] = [] }

    private func openAndWait(_ store: OverlayStore, timeout: Double? = nil) throws -> (Tako.SurfaceView, Replies, URL) {
        let (dir, file) = try overlayFile()
        let surface = Tako.SurfaceView(frame: .zero)
        surface.pwd = dir.path
        let pane = ControlCommands.Pane(surface: surface, windowID: "w", tabID: "t", stableTabID: "t")
        var args: [String: JSON] = ["subcommand": .string("open"), "file": .string(file.path), "wait": .bool(true)]
        if let timeout { args["timeout"] = .number(timeout) }
        let replies = Replies()
        let mode = ControlCommands.mode
        ControlCommands.mode = .on
        defer { ControlCommands.mode = mode }
        ControlCommands.handle(ControlRequest(cmd: "overlay", args: args), all: [pane]) { replies.all.append($0) }
        return (surface, replies, dir)
    }

    @Test func overlayOpenWaitAnswersWithTheFieldsOnceSubmitted() throws {
        let store = OverlayStore.shared
        store.reset()
        defer { store.reset() }
        let (surface, replies, dir) = try openAndWait(store)
        defer { try? FileManager.default.removeItem(at: dir); surface.close() }
        #expect(replies.all.isEmpty, "it waits")
        #expect(store.hasOverlay(paneId: surface.id))
        store.submit(paneId: surface.id, url: url("tako-submit:?b=2&a=1&a=3"))
        #expect(replies.all.count == 1)
        guard case .ok(let result)? = replies.all.first else { Issue.record("\(replies.all)"); return }
        #expect(result["submitted"] == .bool(true))
        #expect(result["fields"] == .object(["b": .string("2"), "a": .array([.string("1"), .string("3")])]))
        #expect(result["order"] == .array([.string("b"), .string("a")]))
    }

    @Test func overlayOpenWaitFailsWhenClosedFirstOrOutOfTime() throws {
        let store = OverlayStore.shared
        store.reset()
        defer { store.reset() }
        let (surface, replies, dir) = try openAndWait(store)
        defer { try? FileManager.default.removeItem(at: dir); surface.close() }
        store.closeOverlay(paneId: surface.id)
        guard case .failure(let closed)? = replies.all.first else { Issue.record("\(replies.all)"); return }
        #expect(closed.message.contains("closed without a submission"))

        let (surface2, late, dir2) = try openAndWait(store, timeout: 0.3)
        defer { try? FileManager.default.removeItem(at: dir2); surface2.close() }
        let deadline = Date().addingTimeInterval(3)
        while late.all.isEmpty, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        guard case .failure(let timedOut)? = late.all.first else { Issue.record("\(late.all)"); return }
        #expect(timedOut.code == .timeout)
        #expect(!store.hasOverlay(paneId: surface2.id), "a form nobody will read goes with the wait")
        #expect(late.all.count == 1)
    }
}
