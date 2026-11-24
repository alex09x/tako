/*
 * tako — Agent identity icons
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Testing
@testable import Tako

@Suite @MainActor
struct SetupAgentIconTests {
    @Test func everyProviderHasADistinctDrawableSmallIconWithoutAnInstalledApp() throws {
        _ = NSApplication.shared
        var representations = Set<Data>()
        for provider in SetupAgentProvider.allCases {
            let image = SetupAgentIconResolver.renderVectorFallback(for: provider, size: 16)
            #expect(image.size == NSSize(width: 16, height: 16))
            let data = try #require(image.tiffRepresentation)
            representations.insert(data)
        }
        #expect(representations.count == 6)
    }
}
