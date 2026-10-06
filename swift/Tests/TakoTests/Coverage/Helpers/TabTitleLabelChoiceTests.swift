/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Testing
import Foundation
import AppKit
@testable import Tako

/// Which of a tab button's private labels the inline editor copies its
/// style and frame from. AppKit's tab buttons hold several labels, some
/// hidden, so the choice is a ranked fallback.
@MainActor
struct TabTitleLabelChoiceTests {
    private func label(
        _ text: String,
        width: CGFloat = 50,
        hidden: Bool = false,
        alpha: CGFloat = 1,
        centered: Bool = false
    ) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.frame = NSRect(x: 0, y: 0, width: width, height: 16)
        field.isHidden = hidden
        field.alphaValue = alpha
        field.alignment = centered ? .center : .natural
        return field
    }

    @Test func aVisibleExactMatchWinsOverEverythingElse() {
        let wide = label("other", width: 200, centered: true)
        let hiddenMatch = label("zsh", hidden: true)
        let match = label("  zsh ")
        let chosen = TabTitleEditor.sourceTabTitleLabel(from: [wide, hiddenMatch, match], matching: "zsh")
        #expect(chosen === match)
    }

    @Test func aHiddenExactMatchBeatsTheHeuristic() {
        let wide = label("other", width: 200, centered: true)
        let faded = label("zsh", alpha: 0)
        let chosen = TabTitleEditor.sourceTabTitleLabel(from: [wide, faded], matching: "zsh")
        #expect(chosen === faded)
    }

    @Test func withoutAMatchTheWidestVisibleCenteredLabelWins() {
        let wideLeft = label("left", width: 300)
        let narrowCentered = label("a", width: 40, centered: true)
        let wideCentered = label("b", width: 120, centered: true)
        let hiddenCentered = label("c", width: 500, hidden: true, centered: true)
        let chosen = TabTitleEditor.sourceTabTitleLabel(
            from: [wideLeft, narrowCentered, wideCentered, hiddenCentered], matching: "renamed")
        #expect(chosen === wideCentered)
    }

    @Test func withoutACenteredLabelTheWidestVisibleOneWins() {
        let narrow = label("a", width: 40)
        let wide = label("b", width: 120)
        let empty = label("   ", width: 400)
        let chosen = TabTitleEditor.sourceTabTitleLabel(from: [narrow, wide, empty], matching: "")
        #expect(chosen === wide)
    }

    @Test func withNothingVisibleTheWidestLabelOfAllIsUsed() {
        let hidden = label("a", width: 90, hidden: true)
        let empty = label("", width: 150)
        let chosen = TabTitleEditor.sourceTabTitleLabel(from: [hidden, empty], matching: "x")
        #expect(chosen === empty)
    }

    @Test func noLabelsMeansNoSource() {
        #expect(TabTitleEditor.sourceTabTitleLabel(from: [], matching: "x") == nil)
    }
}
