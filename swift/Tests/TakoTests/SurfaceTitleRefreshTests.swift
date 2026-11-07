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
    @Test func identicalTitlesPublishOnlyOnce() {
        let surface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        defer { surface.close() }
        var values: [String] = []
        let watch = surface.$titleText.dropFirst().sink { values.append($0) }
        defer { watch.cancel() }
        for _ in 0..<500 { surface.title = "Agent working" }
        #expect(values == ["Agent working"])
    }

    @Test func repeatedProtocolTitlesDoNotRequestChromeLayouts() {
        let surface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        defer { surface.close() }
        var requests = 0
        surface.onTitleChange = { _ in requests += 1 }
        for _ in 0..<500 { surface.applyTerminalTitle("Agent working") }
        #expect(requests == 1)
        #expect(surface.titleText == "Agent working")
        surface.applyTerminalTitle("Agent done")
        #expect(requests == 2)
        #expect(surface.titleText == "Agent done")
        surface.applyTerminalTitle("")
        #expect(requests == 3)
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
}
