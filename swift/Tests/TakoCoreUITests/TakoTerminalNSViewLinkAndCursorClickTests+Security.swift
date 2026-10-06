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
import XCTest
@testable import TakoCoreUI

@MainActor
extension TakoTerminalNSViewLinkAndCursorClickTests {
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

        // Mailto links
        XCTAssertFalse(TakoTerminalNSView.detectLinkMismatch(text: "mailto:support@paypal.com", targetURL: URL(string: "mailto:support@paypal.com")!))
        XCTAssertFalse(TakoTerminalNSView.detectLinkMismatch(text: "mailto:support@paypal.com", targetURL: URL(string: "https://paypal.com/help")!))
        XCTAssertTrue(TakoTerminalNSView.detectLinkMismatch(text: "mailto:support@paypal.com", targetURL: URL(string: "https://evil.com")!))
        XCTAssertTrue(TakoTerminalNSView.detectLinkMismatch(text: "mailto:support@paypal.com", targetURL: URL(string: "mailto:phish@evil.com")!))
    }

    func testLinkContextMenuProvidesOpenAndCopy() {
        let view = makeView()
        view.feed(data: Data("\u{1b}]8;;https://example.com/destination\u{7}Docs\u{1b}]8;;\u{7}".utf8))

        let menu = view.menu(for: mouseEvent(.rightMouseDown, column: 2, in: view))
        XCTAssertNotNil(menu)
        XCTAssertEqual(menu?.title, "Link")

        let openItem = menu?.items.first { $0.action == #selector(TakoTerminalNSView.openLinkContextAction(_:)) }
        XCTAssertNotNil(openItem)
        XCTAssertEqual(openItem?.title, "Open https://example.com/destination")
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

}
