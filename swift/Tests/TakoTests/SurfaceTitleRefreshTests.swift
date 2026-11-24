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
import Combine
import Testing
@testable import Tako

@MainActor
struct SurfaceTitleRefreshTests {
    @Test func rapidDistinctTitlesDoNotRepublishTheWholeSurfaceForEveryFrame() {
        let surface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        defer { surface.close() }
        var values: [String] = []
        let watch = surface.$titleText.dropFirst().sink { values.append($0) }
        defer { watch.cancel() }
        for i in 0..<500 { surface.title = "Agent frame \(i)" }
        #expect(surface.title == "Agent frame 499", "raw terminal metadata remains immediate")
        TerminalTestSupport.waitUntil(timeout: 0.25) { false }
        #expect(values.last == "Agent frame 499")
        #expect(values.count <= 2, "one burst must not invalidate every sidebar/window 500 times")
    }

    @Test func identicalTitlesPublishOnlyOnce() {
        let surface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        defer { surface.close() }
        var values: [String] = []
        let watch = surface.$titleText.dropFirst().sink { values.append($0) }
        defer { watch.cancel() }
        for _ in 0..<500 { surface.title = "Agent working" }
        TerminalTestSupport.waitUntil(timeout: 1) { values == ["Agent working"] }
        #expect(values == ["Agent working"])
    }

    @Test func repeatedProtocolTitlesDoNotRequestChromeLayouts() {
        let surface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        defer { surface.close() }
        var requests = 0
        surface.onTitleChange = { _ in requests += 1 }
        for _ in 0..<500 { surface.applyTerminalTitle("Agent working") }
        #expect(requests == 1)
        TerminalTestSupport.waitUntil(timeout: 1) { surface.titleText == "Agent working" }
        #expect(surface.titleText == "Agent working")
        surface.applyTerminalTitle("Agent done")
        #expect(requests == 2)
        TerminalTestSupport.waitUntil(timeout: 1) { surface.titleText == "Agent done" }
        #expect(surface.titleText == "Agent done")
        surface.applyTerminalTitle("")
        #expect(requests == 3)
        TerminalTestSupport.waitUntil(timeout: 1) { surface.titleText.isEmpty }
        #expect(surface.titleText.isEmpty)
    }

    @Test func aTitleBurstSchedulesOneRefreshReadingTheLatestState() {
        var scheduled: [TabBarRefreshCoalescer.Action] = []
        var latest = ""
        var displayed: [String] = []
        let refresh = TabBarRefreshCoalescer(schedule: { scheduled.append($0) }) {
            displayed.append(latest)
        }
        for i in 0..<500 {
            latest = "Title \(i)"
            refresh.request()
        }
        #expect(scheduled.count == 1)
        #expect(displayed.isEmpty)
        scheduled.removeFirst()()
        #expect(displayed == ["Title 499"])
        latest = "Next frame"
        refresh.request()
        #expect(scheduled.count == 1)
        scheduled.removeFirst()()
        #expect(displayed == ["Title 499", "Next frame"])
    }

    @Test func focusFlushCannotBeUndoneByAnOlderScheduledTitle() {
        let surface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        defer { surface.close() }
        surface.title = "Old title"
        surface.title = "Latest title"
        surface.publishCurrentTitle()
        #expect(surface.titleText == "Latest title")
        TerminalTestSupport.waitUntil(timeout: 0.25) { false }
        #expect(surface.titleText == "Latest title")
    }
}
