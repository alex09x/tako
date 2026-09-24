//
//  TakoTitleUITests.swift
//  TakoUITests
//
//  Created by luca on 13.10.2025.
//

import XCTest

final class TakoTitleUITests: TakoCustomConfigCase {
    override func setUp() async throws {
        try await super.setUp()
        try updateConfig(#"title = "TakoUITestsLaunchTests""#)
    }

    @MainActor
    func testTitle() throws {
        let app = try takoApplication()
        app.launch()

        XCTAssertEqual(app.windows.firstMatch.title, "TakoUITestsLaunchTests", "Oops, `title=` doesn't work!")
    }
}
