import Foundation
import XCTest
@testable import TakoCoreUI

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

/// `link-url` (Command-hover underlines and Command-click opens a detected
/// URL or OSC 8 hyperlink) and `cursor-click-to-move` (a plain click on the
/// cursor's own prompt line walks the cursor there with arrow keys).
@MainActor
final class TakoTerminalNSViewLinkAndCursorClickTests: XCTestCase {
    private func makeView() -> TakoTerminalNSView {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 1400, height: 400))
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func point(forColumn col: Int, row: Int = 0, in view: TakoTerminalNSView) -> NSPoint {
        let origin = view.cellOrigin(row: row, col: col)
        return NSPoint(x: origin.x + max(view.cellWidth, 1) / 2,
                       y: origin.y + max(view.cellHeight, 1) / 2)
    }

    private func mouseEvent(
        _ type: NSEvent.EventType, column: Int, row: Int = 0, in view: TakoTerminalNSView,
        modifiers: NSEvent.ModifierFlags = [], clickCount: Int = 1
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point(forColumn: column, row: row, in: view),
            modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1
        )!
    }

    private func withOpener(_ opener: @escaping (URL) -> Void, _ body: () -> Void) {
        let previous = TakoTerminalNSView.openURL
        TakoTerminalNSView.openURL = opener
        defer { TakoTerminalNSView.openURL = previous }
        body()
    }

    private func withConfirmOpenURL(
        _ hook: @escaping (URL, TakoTerminalNSView.LinkSecurityWarning, NSWindow?, @escaping (Bool) -> Void) -> Void,
        _ body: () -> Void
    ) {
        let previous = TakoTerminalNSView.confirmOpenURL
        TakoTerminalNSView.confirmOpenURL = hook
        defer { TakoTerminalNSView.confirmOpenURL = previous }
        body()
    }

    // MARK: - link-url: plain-text URL detection

    func testCommandClickOnAPlainURLOpensIt() {
        let view = makeView()
        view.feed(data: Data("see https://example.com/path for docs".utf8))
        var opened: [URL] = []
        withOpener({ opened.append($0) }) {
            view.mouseDown(with: mouseEvent(.leftMouseDown, column: 10, in: view, modifiers: [.command]))
        }
        XCTAssertEqual(opened, [URL(string: "https://example.com/path")!])
    }

    func testCommandHoverOverAURLUnderlinesItAndSetsThePointingHandCursor() {
        let view = makeView()
        view.feed(data: Data("see https://example.com/path for docs".utf8))
        view.mouseMoved(with: mouseEvent(.mouseMoved, column: 10, in: view, modifiers: [.command]))
        XCTAssertEqual(view.hoveredLink?.url, URL(string: "https://example.com/path")!)

        view.mouseMoved(with: mouseEvent(.mouseMoved, column: 10, in: view, modifiers: []))
        XCTAssertNil(view.hoveredLink, "releasing Command must clear the hover")
    }

    /// The bug this pins: deleting the flag check would make every URL
    /// clickable, which the disabled test below would silently pass through.
    func testLinkURLDisabledLeavesPlainURLsUnclickable() {
        let view = makeView()
        view.linkURLDetectionEnabled = false
        view.feed(data: Data("see https://example.com/path for docs".utf8))
        var opened: [URL] = []
        withOpener({ opened.append($0) }) {
            view.mouseDown(with: mouseEvent(.leftMouseDown, column: 10, in: view, modifiers: [.command]))
        }
        XCTAssertTrue(opened.isEmpty)
    }

    func testCommandClickWithoutAURLStartsNoOpener() {
        let view = makeView()
        view.feed(data: Data("no links here".utf8))
        var opened: [URL] = []
        withOpener({ opened.append($0) }) {
            view.mouseDown(with: mouseEvent(.leftMouseDown, column: 2, in: view, modifiers: [.command]))
        }
        XCTAssertTrue(opened.isEmpty)
    }

    // MARK: - link-url: OSC 8 hyperlinks keep working regardless of the flag

    func testCommandClickOnAnOSC8HyperlinkOpensItsURI() {
        let view = makeView()
        view.linkURLDetectionEnabled = false
        view.feed(data: Data("\u{1b}]8;;http://osc8.example\u{7}click me\u{1b}]8;;\u{7}".utf8))
        var opened: [URL] = []
        withOpener({ opened.append($0) }) {
            view.mouseDown(with: mouseEvent(.leftMouseDown, column: 2, in: view, modifiers: [.command]))
        }
        XCTAssertEqual(opened, [URL(string: "http://osc8.example")!])
    }

    // MARK: - E8: Safer hyperlinks

    func testOSC8LinkHoverShowsRealTargetAndTooltipAndHUD() {
        let view = makeView()
        let delegate = MockTerminalNSViewDelegate()
        view.delegate = delegate
        view.feed(data: Data("\u{1b}]8;;https://example.org/destination\u{7}Documentation\u{1b}]8;;\u{7}".utf8))

        // Hover over the link without Command held
        view.mouseMoved(with: mouseEvent(.mouseMoved, column: 2, in: view, modifiers: []))
        XCTAssertEqual(view.hoveredLinkTarget, "https://example.org/destination")
        XCTAssertEqual(view.toolTip, "https://example.org/destination")
        XCTAssertEqual(view.currentHoveredLink?.url.absoluteString, "https://example.org/destination")
        XCTAssertEqual(view.currentHoveredLink?.text, "Documentation")
        XCTAssertFalse(view.currentHoveredLink?.isMismatch ?? true)
        XCTAssertTrue(view.currentHoveredLink?.isSchemeAllowedWithoutPrompt ?? false)
        XCTAssertEqual(delegate.hoveredLinks.last, "https://example.org/destination")

        // Hover off the link
        view.mouseMoved(with: mouseEvent(.mouseMoved, column: 40, in: view, modifiers: []))
        XCTAssertNil(view.hoveredLinkTarget)
        XCTAssertNil(view.toolTip)
        XCTAssertNil(view.currentHoveredLink)
        XCTAssertNil(delegate.hoveredLinks.last!)
    }

    func testSafeSchemesOpenWithoutConfirmationPrompt() {
        let view = makeView()
        let safeURLs = [
            "https://example.com/secure",
            "http://example.com/insecure",
            "file:///Users/alex/test.txt"
        ]

        for urlString in safeURLs {
            view.feed(data: Data("\u{1b}[2J\u{1b}[H".utf8))
            view.feed(data: Data("\u{1b}]8;;\(urlString)\u{7}Link\u{1b}]8;;\u{7}".utf8))
            let link = view.linkRange(at: (row: 0, col: 1))
            XCTAssertNotNil(link)
            XCTAssertTrue(link?.isSchemeAllowedWithoutPrompt ?? false)

            var opened: [URL] = []
            var promptTriggered = false
            withConfirmOpenURL({ _, _, _, completion in
                promptTriggered = true
                completion(true)
            }) {
                withOpener({ opened.append($0) }) {
                    view.mouseDown(with: mouseEvent(.leftMouseDown, column: 1, in: view, modifiers: [.command]))
                }
            }

            XCTAssertFalse(promptTriggered, "Safe scheme \(urlString) must not prompt for confirmation")
            XCTAssertEqual(opened, [URL(string: urlString)!])
        }
    }

    func testUnsafeSchemesRequireConfirmationPrompt() {
        let view = makeView()
        let unsafeURLs = [
            "mailto:user@example.com",
            "ssh://user@remote.host",
            "tel:1234567890",
            "custom-app://open/thing"
        ]

        for urlString in unsafeURLs {
            view.feed(data: Data("\u{1b}[2J\u{1b}[H".utf8))
            view.feed(data: Data("\u{1b}]8;;\(urlString)\u{7}Unsafe\u{1b}]8;;\u{7}".utf8))
            let link = view.linkRange(at: (row: 0, col: 1))
            XCTAssertNotNil(link)
            XCTAssertFalse(link?.isSchemeAllowedWithoutPrompt ?? true)

            // 1. When user declines confirmation, openURL is NOT called
            var opened: [URL] = []
            var observedWarning: TakoTerminalNSView.LinkSecurityWarning?
            withConfirmOpenURL({ _, warning, _, completion in
                observedWarning = warning
                completion(false)
            }) {
                withOpener({ opened.append($0) }) {
                    view.mouseDown(with: mouseEvent(.leftMouseDown, column: 1, in: view, modifiers: [.command]))
                }
            }

            XCTAssertNotNil(observedWarning)
            if case .unsafeScheme(let scheme) = observedWarning {
                XCTAssertEqual(scheme, URL(string: urlString)!.scheme)
            } else {
                XCTFail("Expected unsafeScheme warning but got \(String(describing: observedWarning))")
            }
            XCTAssertTrue(opened.isEmpty, "Declined confirmation must abort opening URL")

            // 2. When user approves confirmation, openURL IS called
            withConfirmOpenURL({ _, _, _, completion in
                completion(true)
            }) {
                withOpener({ opened.append($0) }) {
                    view.mouseDown(with: mouseEvent(.leftMouseDown, column: 1, in: view, modifiers: [.command]))
                }
            }

            XCTAssertEqual(opened, [URL(string: urlString)!])
        }
    }

    func testDeceptiveLinkMismatchTriggersSuspiciousWarningAndCriticalPrompt() {
        let view = makeView()
        // Text looks like paypal.com, but target URL is attacker.org
        let payload = "\u{1b}]8;;https://attacker.org/steal\u{7}https://paypal.com/login\u{1b}]8;;\u{7}"
        view.feed(data: Data(payload.utf8))

        let link = view.linkRange(at: (row: 0, col: 5))
        XCTAssertNotNil(link)
        XCTAssertTrue(link?.isMismatch ?? false)
        XCTAssertTrue(link?.tooltipText.contains("Suspicious destination mismatch") ?? false)

        // Hover shows mismatch tooltip and hoveredLinkTarget
        view.mouseMoved(with: mouseEvent(.mouseMoved, column: 5, in: view, modifiers: []))
        XCTAssertEqual(view.hoveredLinkTarget, "https://attacker.org/steal")
        XCTAssertTrue(view.toolTip?.contains("Suspicious destination mismatch") ?? false)

        // Command-click prompts for confirmation with .urlMismatch warning
        var opened: [URL] = []
        var observedWarning: TakoTerminalNSView.LinkSecurityWarning?

        // Decline first
        withConfirmOpenURL({ _, warning, _, completion in
            observedWarning = warning
            completion(false)
        }) {
            withOpener({ opened.append($0) }) {
                view.mouseDown(with: mouseEvent(.leftMouseDown, column: 5, in: view, modifiers: [.command]))
            }
        }

        XCTAssertNotNil(observedWarning)
        if case .urlMismatch(let text, let target) = observedWarning {
            XCTAssertTrue(text.contains("paypal.com"))
            XCTAssertEqual(target, URL(string: "https://attacker.org/steal")!)
        } else {
            XCTFail("Expected urlMismatch warning but got \(String(describing: observedWarning))")
        }
        XCTAssertTrue(opened.isEmpty)

        // Approve
        withConfirmOpenURL({ _, _, _, completion in
            completion(true)
        }) {
            withOpener({ opened.append($0) }) {
                view.mouseDown(with: mouseEvent(.leftMouseDown, column: 5, in: view, modifiers: [.command]))
            }
        }

        XCTAssertEqual(opened, [URL(string: "https://attacker.org/steal")!])
    }

    func testDetectLinkMismatchRules() {
        // Plain text should not trigger mismatch
        XCTAssertFalse(TakoTerminalNSView.detectLinkMismatch(text: "Click here for release notes", targetURL: URL(string: "https://github.com/release")!))
        XCTAssertFalse(TakoTerminalNSView.detectLinkMismatch(text: "documentation", targetURL: URL(string: "https://docs.example.com")!))

        // Same domain (with or without www, with or without scheme)
        XCTAssertFalse(TakoTerminalNSView.detectLinkMismatch(text: "https://example.com/docs", targetURL: URL(string: "https://example.com/other")!))
        XCTAssertFalse(TakoTerminalNSView.detectLinkMismatch(text: "example.com", targetURL: URL(string: "https://www.example.com")!))
        XCTAssertFalse(TakoTerminalNSView.detectLinkMismatch(text: "www.example.com", targetURL: URL(string: "https://example.com")!))

        // Different domain -> Mismatch!
        XCTAssertTrue(TakoTerminalNSView.detectLinkMismatch(text: "paypal.com", targetURL: URL(string: "https://evil.com")!))
        XCTAssertTrue(TakoTerminalNSView.detectLinkMismatch(text: "https://apple.com/support", targetURL: URL(string: "https://phishing.site/apple")!))
        XCTAssertTrue(TakoTerminalNSView.detectLinkMismatch(text: "www.bank.com", targetURL: URL(string: "https://other.com")!))
        XCTAssertTrue(TakoTerminalNSView.detectLinkMismatch(text: "subdomain.example.com", targetURL: URL(string: "https://attacker.com")!))

        // File URL matching filename is safe
        XCTAssertFalse(TakoTerminalNSView.detectLinkMismatch(text: "report.pdf", targetURL: URL(fileURLWithPath: "/tmp/report.pdf")))
    }

    func testLinkContextMenuProvidesOpenAndCopy() {
        let view = makeView()
        view.feed(data: Data("\u{1b}]8;;https://example.com/destination\u{7}Docs\u{1b}]8;;\u{7}".utf8))

        let menu = view.menu(for: mouseEvent(.rightMouseDown, column: 2, in: view))
        XCTAssertNotNil(menu)
        XCTAssertEqual(menu?.title, "Link")

        let openItem = menu?.items.first { $0.action == #selector(TakoTerminalNSView.openLinkContextAction(_:)) }
        XCTAssertNotNil(openItem)
        XCTAssertEqual(openItem?.title, "Open Link")
        XCTAssertTrue(view.validateUserInterfaceItem(openItem!), "Open Link must be enabled by validateUserInterfaceItem")

        let copyItem = menu?.items.first { $0.action == #selector(TakoTerminalNSView.copyLinkContextAction(_:)) }
        XCTAssertNotNil(copyItem)
        XCTAssertEqual(copyItem?.title, "Copy Link")
        XCTAssertTrue(view.validateUserInterfaceItem(copyItem!), "Copy Link must be enabled by validateUserInterfaceItem")

        var copiedText: String?
        view.copyStringConsumer = { copiedText = $0 }
        view.perform(copyItem!.action, with: copyItem)
        XCTAssertEqual(copiedText, "https://example.com/destination")

        var opened: [URL] = []
        withOpener({ opened.append($0) }) {
            view.perform(openItem!.action, with: openItem)
        }
        XCTAssertEqual(opened, [URL(string: "https://example.com/destination")!])
    }

    // MARK: - cursor-click-to-move

    private func leftArrowBytes(_ view: TakoTerminalNSView) -> Data {
        view.core.encodeKey(event: FfiKeyEvent(
            key: .left, text: "", physicalText: "", unshiftedText: "",
            shift: false, alt: false, ctrl: false, superKey: false,
            press: true, repeat: false, composing: false
        ))
    }

    private func rightArrowBytes(_ view: TakoTerminalNSView) -> Data {
        view.core.encodeKey(event: FfiKeyEvent(
            key: .right, text: "", physicalText: "", unshiftedText: "",
            shift: false, alt: false, ctrl: false, superKey: false,
            press: true, repeat: false, composing: false
        ))
    }

    private func click(column: Int, row: Int = 0, modifiers: NSEvent.ModifierFlags = [], in view: TakoTerminalNSView) {
        view.mouseDown(with: mouseEvent(.leftMouseDown, column: column, row: row, in: view, modifiers: modifiers))
        view.mouseUp(with: mouseEvent(.leftMouseUp, column: column, row: row, in: view, modifiers: modifiers))
    }

    func testClickOnTheCursorsPromptLineMovesTheCursorLeft() {
        let view = makeView()
        let delegate = MockTerminalNSViewDelegate()
        view.delegate = delegate
        view.feed(data: Data("\u{1b}]133;A\u{7}$ hello".utf8))
        XCTAssertTrue(view.core.cursorIsAtPrompt())
        XCTAssertEqual(view.core.cursorCol(), 7)
        delegate.inputDataReceived = Data()

        click(column: 2, in: view)

        let expected = Data((0..<5).map { _ in leftArrowBytes(view) }.reduce(Data(), +))
        XCTAssertEqual(delegate.inputDataReceived, expected)
    }

    func testClickRightOfTheCursorOnItsPromptLineMovesItRight() {
        let view = makeView()
        let delegate = MockTerminalNSViewDelegate()
        view.delegate = delegate
        view.feed(data: Data("\u{1b}]133;A\u{7}$ hi".utf8))
        XCTAssertEqual(view.core.cursorCol(), 4)
        delegate.inputDataReceived = Data()

        click(column: 8, in: view)

        let expected = Data((0..<4).map { _ in rightArrowBytes(view) }.reduce(Data(), +))
        XCTAssertEqual(delegate.inputDataReceived, expected)
    }

    /// The disabled-key half of the contract: with the feature off, a click
    /// away from the cursor must not move it at all.
    func testCursorClickToMoveDisabledDoesNotMoveTheCursor() {
        let view = makeView()
        let delegate = MockTerminalNSViewDelegate()
        view.delegate = delegate
        view.cursorClickToMove = false
        view.feed(data: Data("\u{1b}]133;A\u{7}$ hello".utf8))
        delegate.inputDataReceived = Data()

        click(column: 2, in: view)

        XCTAssertTrue(delegate.inputDataReceived.isEmpty)
    }

    /// Not at a prompt (no OSC 133;A was ever seen on this row) -- a click
    /// elsewhere on the line must not be treated as cursor placement.
    func testClickAwayFromAPromptDoesNotMoveTheCursor() {
        let view = makeView()
        let delegate = MockTerminalNSViewDelegate()
        view.delegate = delegate
        view.feed(data: Data("just some output, no prompt mark".utf8))
        delegate.inputDataReceived = Data()

        click(column: 2, in: view)

        XCTAssertTrue(delegate.inputDataReceived.isEmpty)
    }

    /// Upstream also accepts Option+click anywhere on the prompt line, not
    /// only on the cursor's own row.
    func testOptionClickMovesTheCursorFromAnotherRowOnTheSamePrompt() {
        let view = makeView()
        let delegate = MockTerminalNSViewDelegate()
        view.delegate = delegate
        // Two separate prompt rows, both marked by their own OSC 133;A; the
        // cursor sits on the second, and row 0 is not where it is -- only
        // Option+click reaches it.
        view.feed(data: Data("\u{1b}]133;A\u{7}$ first\r\n".utf8))
        view.feed(data: Data("\u{1b}]133;A\u{7}$ second".utf8))
        XCTAssertEqual(view.core.cursorRow(), 1)
        delegate.inputDataReceived = Data()

        click(column: 2, row: 0, in: view)
        XCTAssertTrue(delegate.inputDataReceived.isEmpty, "a plain click off the cursor's row must not move it")

        click(column: 2, row: 0, modifiers: [.option], in: view)
        XCTAssertFalse(delegate.inputDataReceived.isEmpty, "Option+click on another row of the same prompt must move the cursor")
    }
}
#endif
