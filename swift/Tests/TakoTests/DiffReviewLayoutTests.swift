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
import SwiftUI
import Testing
@testable import Tako

@Suite(.serialized) @MainActor
struct DiffReviewLayoutTests {
    @Test(arguments: [389.0, 900.0])
    func insertedReviewFitsItsPane(width: Double) throws {
        _ = NSApplication.shared
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent("tako-layout-\(UUID())")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        try git(["init", "-b", "main"], in: repo)
        let file = repo.appendingPathComponent("review_test.txt")
        try "before\n".write(to: file, atomically: true, encoding: .utf8)
        try git(["add", "."], in: repo)
        try git(["-c", "user.name=Layout Test", "-c", "user.email=layout@example.invalid",
                 "commit", "-m", "fixture"], in: repo)
        try "after\n".write(to: file, atomically: true, encoding: .utf8)

        let surface = Tako.SurfaceView(frame: .zero)
        let store = DiffReviewStore.shared
        defer { store.closeReview(paneId: surface.id) }
        let probe = SwiftUIMotionProbe(Tako.InspectableSurface(surfaceView: surface, isSplit: true),
                                       size: CGSize(width: width, height: 438))
        defer { probe.close() }
        let session = try store.openReview(paneId: surface.id, taskName: repo.path,
                                           projectPath: repo.path, baseBranch: "main")
        #expect(session.files.map(\.path) == ["review_test.txt"])
        probe.settle(0.35)
        try expectVisibleReview(probe, phase: "inserted", width: width)
        _ = try store.addComment(paneId: surface.id, file: "review_test.txt", line: 1, text: "layout note")
        probe.settle(0.1)
        try expectVisibleReview(probe, phase: "rebuilt", width: width)
    }

    private func expectVisibleReview(_ probe: SwiftUIMotionProbe, phase: String, width: Double) throws {
        probe.host.layoutSubtreeIfNeeded()
        let scrolls = scrollViews(probe.host)
        #expect(scrolls.count == 2, "file list and diff viewer must both be rendered")
        for scroll in scrolls {
            let frame = probe.host.convert(scroll.bounds, from: scroll)
            expectContained(frame, in: probe.host.bounds, label: "\(width) \(phase) scroll")
            let document = try #require(scroll.documentView)
            #expect(document.frame.width > 0 && document.frame.height > 0, "review content must be laid out")
            #expect(scroll.hitTest(CGPoint(x: scroll.frame.midX, y: scroll.frame.midY)) != nil,
                    "review scroll views must accept input")
        }
        for split in splitViews(probe.host) {
            expectContained(probe.host.convert(split.bounds, from: split), in: probe.host.bounds,
                            label: "\(width) \(phase) split")
        }
        if width == 900 {
            let split = try #require(splitViews(probe.host).first)
            #expect(split.isVertical, "wide reviews retain the resizable side-by-side split")
        }
    }

    private func expectContained(_ frame: CGRect, in bounds: CGRect, label: String) {
        print("DiffReview geometry \(label)=\(frame) bounds=\(bounds)")
        #expect(frame.width.isFinite && frame.height.isFinite && frame.width > 0 && frame.height > 0, "\(label)")
        #expect(bounds.insetBy(dx: -1, dy: -1).contains(frame), "\(label) overflows its pane")
    }

    private func scrollViews(_ view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }

    private func splitViews(_ view: NSView) -> [NSSplitView] {
        (view as? NSSplitView).map { [$0] } ?? view.subviews.flatMap(splitViews)
    }

    private func git(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "git \(arguments)")
    }
}
