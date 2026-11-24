/*
 * tako — User tab names publish a sidebar invalidation
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Combine
import Testing
@testable import Tako

@Suite(.serialized) @MainActor
struct ControllerTitleSidebarTests {
    @Test func givingAndClearingATabNamePublishesItsNewValue() throws {
        let fixture = try PrivateSurfaceFixture()
        defer { fixture.cleanUp() }
        let surface = fixture.surface()
        let (controller, window) = TerminalTestSupport.makeController(baseConfig: fixture.configuration,
                                                                    surfaceTree: .init(view: surface))
        window.windowController = controller
        defer { TerminalTestSupport.tearDown(controller, window) }
        var published: [String?] = []
        let observation = NotificationCenter.default.publisher(for: .init("TakoTabTitleDidChange"))
            .sink { note in
                guard (note.object as? BaseTerminalController) === controller else { return }
                published.append(controller.titleOverride)
            }
        defer { observation.cancel() }

        controller.titleOverride = "Given name"
        #expect(window.title == "Given name")
        #expect(published == ["Given name"], "an otherwise quiet pane must invalidate its sidebar name")
        controller.titleOverride = "Given name"
        #expect(published.count == 1, "setting the same name must not invalidate the sidebar again")
        controller.titleOverride = nil
        #expect(published == ["Given name", nil], "clearing a name must restore the automatic title on screen")
    }
}
