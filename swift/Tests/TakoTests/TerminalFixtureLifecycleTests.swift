/*
 * tako — The manually loaded test window must receive its real close lifecycle
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */
import AppKit
import Testing
@testable import Tako

@Suite(.serialized) @MainActor
struct TerminalFixtureLifecycleTests {
    @Test func aLoadedFixtureClosesItsHostingGraphThroughTheRealDelegate() throws {
        var configuration = Tako.SurfaceConfiguration()
        configuration.program = ["/bin/sleep", "600"]
        configuration.allowsSessionPersistence = false
        let (controller, window) = TerminalTestSupport.loaded(baseConfig: configuration)
        defer { TerminalTestSupport.tearDown(controller, window) }
        _ = try #require(window.contentView)
        _ = Tako.CustomTabGroup.group(for: window)

        #expect(window.delegate === controller, "Terminal.xib connects this delegate in the app")
        window.close()

        #expect(window.contentView == nil, "the close delegate must break the hosting graph")
        #expect(Tako.CustomTabGroup.isClosed(window))
    }
}
