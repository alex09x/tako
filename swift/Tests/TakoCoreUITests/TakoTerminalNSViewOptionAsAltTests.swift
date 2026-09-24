import Foundation
import XCTest
@testable import TakoCoreUI

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

/// `optionAsAlt` decides whether an Option-held key is encoded straight to
/// ESC + base key, or left to compose through the input context as today.
@MainActor
final class TakoTerminalNSViewOptionAsAltTests: XCTestCase {
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.accessory)
        TakoTerminalNSView.isMetalDisabledForTesting = true
    }

    /// Left and right Option both set `.option` in `modifierFlags`; only the
    /// device-dependent bits AppKit also sets tell them apart.
    private func optionEvent(deviceBits: UInt, characters: String, unmodified: String, keyCode: UInt16) -> NSEvent {
        let flags = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | deviceBits)
        return NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: unmodified,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    private let leftOptionBit: UInt = 0x20
    private let rightOptionBit: UInt = 0x40

    // MARK: - OptionAsAlt.appliesTo

    func testOffNeverApplies() {
        let event = optionEvent(deviceBits: leftOptionBit, characters: "@", unmodified: "2", keyCode: 19)
        XCTAssertFalse(OptionAsAlt.off.appliesTo(event))
    }

    func testOnAlwaysApplies() {
        let event = optionEvent(deviceBits: rightOptionBit, characters: "@", unmodified: "2", keyCode: 19)
        XCTAssertTrue(OptionAsAlt.on.appliesTo(event))
    }

    func testLeftAppliesOnlyToTheLeftOptionKey() {
        let leftEvent = optionEvent(deviceBits: leftOptionBit, characters: "@", unmodified: "2", keyCode: 19)
        let rightEvent = optionEvent(deviceBits: rightOptionBit, characters: "@", unmodified: "2", keyCode: 19)
        XCTAssertTrue(OptionAsAlt.left.appliesTo(leftEvent))
        XCTAssertFalse(OptionAsAlt.left.appliesTo(rightEvent))
    }

    func testRightAppliesOnlyToTheRightOptionKey() {
        let leftEvent = optionEvent(deviceBits: leftOptionBit, characters: "@", unmodified: "2", keyCode: 19)
        let rightEvent = optionEvent(deviceBits: rightOptionBit, characters: "@", unmodified: "2", keyCode: 19)
        XCTAssertFalse(OptionAsAlt.right.appliesTo(leftEvent))
        XCTAssertTrue(OptionAsAlt.right.appliesTo(rightEvent))
    }

    // MARK: - keyDown

    /// The default: Option composes. The composed character goes out as
    /// typed, without an ESC -- Option is not a modifier here.
    func testDefaultLeavesOptionComposing() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalNSViewDelegate()
        view.delegate = delegate
        XCTAssertEqual(view.optionAsAlt, .off)

        let event = optionEvent(deviceBits: leftOptionBit, characters: "@", unmodified: "2", keyCode: 19)
        view.keyDown(with: event)

        XCTAssertEqual(delegate.inputDataReceived, Data([0x40]),
                       "an Option that composes has made the character; no ESC goes with it")
    }

    /// `.on`: the base key produced without Option is sent, not the composed
    /// character, and ESC still prefixes it (Alt behaviour).
    func testOnSendsTheBaseKeyNotTheComposedCharacter() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalNSViewDelegate()
        view.delegate = delegate
        view.optionAsAlt = .on

        let event = optionEvent(deviceBits: leftOptionBit, characters: "@", unmodified: "2", keyCode: 19)
        view.keyDown(with: event)

        XCTAssertEqual(delegate.inputDataReceived, Data([0x1b, 0x32]),
                       "expected ESC + the base '2', not the Option-composed '@'")
    }

    /// `.left` applies for the left Option key.
    func testLeftAppliesToLeftOptionPress() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalNSViewDelegate()
        view.delegate = delegate
        view.optionAsAlt = .left

        let event = optionEvent(deviceBits: leftOptionBit, characters: "@", unmodified: "2", keyCode: 19)
        view.keyDown(with: event)

        XCTAssertEqual(delegate.inputDataReceived, Data([0x1b, 0x32]))
    }

    /// `.left` leaves the right Option key composing, unaffected.
    /// A key that types nothing keeps Option as a modifier in every mode:
    /// Option+Left is word-left in a shell.
    func testOptionWithAnArrowIsReportedAsAltEvenWhenOptionComposes() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalNSViewDelegate()
        view.delegate = delegate

        let event = optionEvent(deviceBits: leftOptionBit, characters: "\u{F702}", unmodified: "\u{F702}", keyCode: 123)
        view.keyDown(with: event)

        XCTAssertEqual(delegate.inputDataReceived, Data("\u{1b}[1;3D".utf8))
    }

    func testLeftLeavesRightOptionComposing() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalNSViewDelegate()
        view.delegate = delegate
        view.optionAsAlt = .left

        let event = optionEvent(deviceBits: rightOptionBit, characters: "@", unmodified: "2", keyCode: 19)
        view.keyDown(with: event)

        XCTAssertEqual(delegate.inputDataReceived, Data([0x40]),
                       "right Option should still compose while only left is configured as Alt")
    }

    /// `.right` applies for the right Option key.
    func testRightAppliesToRightOptionPress() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalNSViewDelegate()
        view.delegate = delegate
        view.optionAsAlt = .right

        let event = optionEvent(deviceBits: rightOptionBit, characters: "@", unmodified: "2", keyCode: 19)
        view.keyDown(with: event)

        XCTAssertEqual(delegate.inputDataReceived, Data([0x1b, 0x32]))
    }
}
#endif
