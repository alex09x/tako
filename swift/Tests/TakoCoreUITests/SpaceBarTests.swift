import Foundation
import XCTest
@testable import TakoCoreUI

/// What the space bar sends, whatever the keyboard layout made of it.
final class SpaceBarTests: XCTestCase {
    func testNoBreakSpacesBecomePlainSpaces() {
        XCTAssertEqual(SpaceBar.text(forCommitted: "\u{00A0}"), " ")
        XCTAssertEqual(SpaceBar.text(forCommitted: "\u{202F}"), " ")
    }

    /// A Japanese input method commits a full-width space outside a
    /// conversion, and a conversion commits its text on the space bar. Both
    /// are what the person asked for.
    func testEverythingElseGoesThroughUnchanged() {
        for committed in [" ", "\u{3000}", "日本語", "\u{00A0}\u{00A0}", "a\u{00A0}"] {
            XCTAssertEqual(SpaceBar.text(forCommitted: committed), committed)
        }
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

/// An input context that commits a fixed string for every key, the way a
/// keyboard layout commits a no-break space for Option+Space.
private final class CommittingInputContext: NSTextInputContext {
    var commit = ""

    override func handleEvent(_ event: NSEvent) -> Bool {
        client.insertText(commit, replacementRange: NSRange(location: NSNotFound, length: 0))
        return true
    }
}

/// A surface whose input context the test chooses. The real one belongs to
/// the text input system, which decides what a key commits from the user's
/// layout -- not something a test can set.
private final class ComposingTerminalNSView: TakoTerminalNSView {
    var composer: NSTextInputContext?

    override var inputContext: NSTextInputContext? { composer }
}

@MainActor
final class TakoTerminalNSViewSpaceBarTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        TakoTerminalNSView.isMetalDisabledForTesting = true
    }

    private let space: UInt16 = 49

    private func spaceEvent(_ flags: NSEvent.ModifierFlags, characters: String) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: " ",
            isARepeat: false, keyCode: space
        )!
    }

    private func bytes(
        for event: NSEvent,
        committing commit: String? = nil,
        optionAsAlt: OptionAsAlt = .off
    ) -> Data {
        let view = ComposingTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        if let commit {
            let context = CommittingInputContext(client: view)
            context.commit = commit
            view.composer = context
        }
        view.optionAsAlt = optionAsAlt
        let delegate = MockTerminalNSViewDelegate()
        view.delegate = delegate
        view.keyDown(with: event)
        return delegate.inputDataReceived
    }

    func testSpaceShiftSpaceAndControlSpace() {
        XCTAssertEqual(bytes(for: spaceEvent([], characters: " ")), Data([0x20]))
        XCTAssertEqual(bytes(for: spaceEvent([.shift], characters: " ")), Data([0x20]))
        XCTAssertEqual(bytes(for: spaceEvent([.control], characters: "\u{0}")), Data([0x00]),
                       "ctrl+space is NUL, the Emacs mark and a common tmux prefix")
    }

    /// Twice in a row is two spaces. Prose editors turn a double space into
    /// ". "; a terminal has no business doing the same.
    func testTwoSpacesAreTwoSpaces() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalNSViewDelegate()
        view.delegate = delegate
        view.keyDown(with: spaceEvent([], characters: " "))
        view.keyDown(with: spaceEvent([], characters: " "))
        XCTAssertEqual(delegate.inputDataReceived, Data([0x20, 0x20]))
    }

    /// The layout commits U+00A0 for Option+Space; what reaches the shell
    /// is a space it can split words on.
    func testOptionSpaceCommittedAsANoBreakSpaceSendsASpace() {
        XCTAssertEqual(bytes(for: spaceEvent([.option], characters: "\u{00A0}"), committing: "\u{00A0}"),
                       Data([0x20]))
        XCTAssertEqual(bytes(for: spaceEvent([.option, .shift], characters: "\u{202F}"), committing: "\u{202F}"),
                       Data([0x20]))
    }

    /// With no input method to compose through, a composing Option on the
    /// space bar is still no modifier: a space, not ESC + space.
    func testOptionSpaceWithoutAnInputMethodSendsASpace() {
        XCTAssertEqual(bytes(for: spaceEvent([.option], characters: "\u{00A0}")), Data([0x20]))
    }

    /// Option configured as Alt is a modifier by request: ESC + space.
    func testOptionSpaceAsAltSendsEscapeSpace() {
        XCTAssertEqual(bytes(for: spaceEvent([.option], characters: "\u{00A0}"), optionAsAlt: .on),
                       Data([0x1b, 0x20]))
    }

    /// What an input method means by the space bar is kept: a full-width
    /// space typed in Japanese mode is not a no-break space.
    func testOtherSpaceBarCommitsAreKept() {
        XCTAssertEqual(bytes(for: spaceEvent([], characters: " "), committing: "\u{3000}"),
                       Data("\u{3000}".utf8))
    }

    /// Only the space bar is special: Option on a key that types nothing is
    /// still reported, so Option+Backspace deletes a word.
    func testOptionOnOtherNamedKeysIsStillAlt() {
        let backspace = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.option],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}",
            isARepeat: false, keyCode: 51
        )!
        XCTAssertEqual(bytes(for: backspace), Data([0x1b, 0x7f]))
    }
}
#endif

#if canImport(UIKit)
import UIKit

@MainActor
final class TakoTerminalViewSpaceBarTests: XCTestCase {
    private func typing(_ keys: [String]) -> Data {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate
        keys.forEach(view.insertText)
        return delegate.inputDataReceived
    }

    /// The software keyboard's defaults are for prose. Each of these, left
    /// on, types something into a shell that nobody typed.
    func testTheKeyboardIsToldThisIsNotProse() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertEqual(view.autocapitalizationType, UITextAutocapitalizationType.none, "`ls` would go out as `Ls`")
        XCTAssertEqual(view.autocorrectionType, .no)
        XCTAssertEqual(view.spellCheckingType, .no)
        XCTAssertEqual(view.smartQuotesType, .no, "a curly quote does not quote a shell word")
        XCTAssertEqual(view.smartDashesType, .no, "`--flag` would become an em dash")
        XCTAssertEqual(view.smartInsertDeleteType, .no)
        XCTAssertEqual(view.inlinePredictionType, .no)

        // UIKit reads these through the Objective-C runtime. A property that
        // did not satisfy the protocol's optional requirement would read fine
        // from Swift and leave the keyboard on its defaults, so read them the
        // way UIKit does.
        let expected: [String: Int] = [
            "autocapitalizationType": UITextAutocapitalizationType.none.rawValue,
            "autocorrectionType": UITextAutocorrectionType.no.rawValue,
            "spellCheckingType": UITextSpellCheckingType.no.rawValue,
            "smartQuotesType": UITextSmartQuotesType.no.rawValue,
            "smartDashesType": UITextSmartDashesType.no.rawValue,
            "smartInsertDeleteType": UITextSmartInsertDeleteType.no.rawValue,
            "inlinePredictionType": UITextInlinePredictionType.no.rawValue,
        ]
        for (trait, value) in expected {
            guard view.responds(to: NSSelectorFromString(trait)) else {
                XCTFail("UIKit cannot see \(trait); the keyboard keeps its default")
                continue
            }
            XCTAssertEqual(view.value(forKey: trait) as? Int, value, trait)
        }
    }

    func testTwoSpacesAreTwoSpaces() {
        XCTAssertEqual(typing(["z", " ", " ", "q"]), Data("z  q".utf8))
    }

    /// Option+Space on a hardware keyboard.
    func testANoBreakSpaceArrivesAsASpace() {
        XCTAssertEqual(typing(["\u{00A0}"]), Data([0x20]))
    }

    func testControlSpaceIsNul() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate
        guard let command = view.keyCommands?.first(where: {
            $0.input == " " && $0.modifierFlags == .control
        }) else {
            return XCTFail("no key command for ctrl+space: it would arrive as a plain space")
        }
        view.perform(Selector(("handleKeyCommand:")), with: command)
        XCTAssertEqual(delegate.inputDataReceived, Data([0x00]))
    }
}
#endif
