/*
 * tako — The UI tests' paste helper never overwrites another writer's clipboard
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import XCTest

/// On a private named pasteboard, never the shared one; no app is launched.
final class TakoPasteboardGuardTests: XCTestCase {
    private typealias H = TakoScopedAppearanceHelpers

    @MainActor func testOnlyItsOwnTextIsReplacedByTheEarlierContents() {
        let board = NSPasteboard(name: NSPasteboard.Name("TakoUITestPasteboard-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setString("owner", forType: .string)

        var during: String?
        let restored = H.withPasteboardText("draft", on: board) { during = board.string(forType: .string) }
        XCTAssertEqual(restored, .restored)
        XCTAssertEqual(during, "draft", "the text is on the pasteboard while it is pasted")
        XCTAssertEqual(board.string(forType: .string), "owner", "the earlier contents come back")

        var outcome: H.PasteboardOutcome?
        XCTExpectFailure("a write by someone else during the paste is reported") {
            outcome = H.withPasteboardText("draft", on: board) {
                board.clearContents()
                board.setString("newer", forType: .string)
            }
        }
        XCTAssertEqual(outcome, .keptNewerContents)
        XCTAssertEqual(board.string(forType: .string), "newer", "another writer's newer clipboard is kept")
    }
}
