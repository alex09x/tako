/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

#if canImport(UIKit)
import Foundation
import Metal
import QuartzCore
import UIKit
import XCTest
@testable import TakoCoreUI

@MainActor
extension TakoTerminalViewTests {
    func testCommandLifecycleEventsReachTheSurfaceHost() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate

        view.feed(data: Data("\u{1b}]133;C\u{7}".utf8))
        view.feed(data: Data("\u{1b}]133;D;17\u{7}".utf8))
        view.feed(data: Data("\u{1b}]133;D\u{7}".utf8))

        XCTAssertEqual(delegate.commandStartCount, 1)
        XCTAssertEqual(delegate.commandExitCodes.count, 2)
        XCTAssertEqual(delegate.commandExitCodes[0], 17)
        XCTAssertNil(delegate.commandExitCodes[1])
    }

    func testSoftWrapAccessibilityAndPlainText() {
        let core = TakoCore(cols: 5, rows: 4)
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), core: core)
        view.feed(data: Data("ABCDEFGH\r\nIJ".utf8))
        let text = view.plainText(startRow: 0, maxRows: 4)
        XCTAssertEqual(text, "ABCDEFGH\nIJ")
        XCTAssertEqual(view.accessibilityValue, "ABCDEFGH\nIJ")
    }

    func testSynchronizedOutputRedrawSuppression() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))

        // Begin synchronized update: \e[?2026h
        view.feed(data: Data("\u{001B}[?2026h".utf8))
        XCTAssertTrue(view.core.isSynchronizedOutputActive())

        view.feed(data: Data("Buffered content during sync\r\n".utf8))

        // End synchronized update: \e[?2026l
        view.feed(data: Data("\u{001B}[?2026l".utf8))
        XCTAssertFalse(view.core.isSynchronizedOutputActive())
    }

    func testHostRedrawDecisionsForNormalDamageOpenSyncAndCloseFlush() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.redrawNow()
        XCTAssertFalse(view.redrawPending)

        // 1. Normal damage: outcome.hasDamage == true, outcome.synchronizedOutputActive == false
        let normalOutcome = view.core.feedWithOutcome(bytes: Data("Normal Damage\r\n".utf8))
        XCTAssertTrue(normalOutcome.hasDamage)
        XCTAssertFalse(normalOutcome.synchronizedOutputActive)
        view.feed(data: Data("Normal Damage 2\r\n".utf8))
        XCTAssertTrue(view.redrawPending, "Normal damage must schedule a redraw")
        view.redrawNow()
        XCTAssertFalse(view.redrawPending)

        // 2. Open synchronized output: mode 2026 active
        let syncOpenOutcome = view.core.feedWithOutcome(bytes: Data("\u{001B}[?2026h".utf8))
        XCTAssertTrue(syncOpenOutcome.synchronizedOutputActive)

        let syncDamageOutcome = view.core.feedWithOutcome(bytes: Data("Sync output text\r\n".utf8))
        XCTAssertTrue(syncDamageOutcome.synchronizedOutputActive)
        XCTAssertFalse(syncDamageOutcome.hasDamage,
                       "damage notifications stay suppressed until synchronized output closes")

        view.feed(data: Data("Sync output text 2\r\n".utf8))
        XCTAssertFalse(view.redrawPending, "Redraw must be suppressed while synchronized output is active")

        // 3. Close/flush: mode 2026 inactive, retained damage causes redraw
        let syncCloseOutcome = view.core.feedWithOutcome(bytes: Data("\u{001B}[?2026l".utf8))
        XCTAssertFalse(syncCloseOutcome.synchronizedOutputActive)
        XCTAssertTrue(syncCloseOutcome.hasDamage, "Accumulated damage must be present when sync output closes")

        view.feed(data: Data("\u{001B}[?2026l".utf8))
        XCTAssertTrue(view.redrawPending, "Closing synchronized output with pending damage must schedule a redraw")
    }

    func testPasteEncoding() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = MockTerminalViewDelegate()
        view.delegate = delegate

        let multiLineText = "Line 1\nLine 2"
        view.insertText(multiLineText)

        XCTAssertFalse(delegate.inputDataReceived.isEmpty)
        let received = String(data: delegate.inputDataReceived, encoding: .utf8)
        XCTAssertNotNil(received)
        XCTAssertTrue(received?.contains("Line 1") ?? false)
    }

    func testRepeatedCreateDestroyNoRetainedTimers() {
        for i in 1...30 {
            let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
            view.feed(data: Data("Iter \(i)\r\n".utf8))
            // Out of scope -> deinit should invalidate timer cleanly
        }
    }

    func testUIEditMenuInteractionReuse() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let controller = UIViewController()
        controller.view.addSubview(view)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        view.feed(data: Data("Edit Menu Test\r\n".utf8))

        guard view.becomeFirstResponder() else {
            throw XCTSkip("the standalone XCTest process has no UIApplication responder chain; the hosted UI walkthrough covers this path")
        }

        let longPressSel = Selector(("handleLongPress:"))
        let longPress = MockLongPressGestureRecognizer()

        for _ in 0..<5 {
            view.core.startSelection(row: 0, col: 0, mode: .linear)
            view.core.extendSelection(row: 0, col: 4)
            longPress.state = .ended
            _ = view.perform(longPressSel, with: longPress)
        }

        XCTAssertTrue(view.isFirstResponder, "Long-press selection must retain first-responder status")

        if #available(iOS 16.0, *) {
            let editMenuInteractions = view.interactions.filter { $0 is UIEditMenuInteraction }
            XCTAssertLessThanOrEqual(editMenuInteractions.count, 1)
        }
    }

    @available(iOS 16.0, *)
    func testEditMenuDelegateOffersCopyOnlyWhenSelectionExists() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.feed(data: Data("Copy Delegate Test\r\n".utf8))

        let menuDelegate = TakoTerminalViewEditMenuDelegate(terminalView: view)
        let interaction = UIEditMenuInteraction(delegate: menuDelegate)
        let config = UIEditMenuConfiguration(identifier: nil, sourcePoint: .zero)

        XCTAssertFalse(view.core.hasSelection())
        let emptyMenu = menuDelegate.editMenuInteraction(interaction, menuFor: config, suggestedActions: [])
        XCTAssertEqual(emptyMenu?.children.count, 0, "no selection must not offer a Copy action")

        view.core.startSelection(row: 0, col: 0, mode: .linear)
        view.core.extendSelection(row: 0, col: 5)
        XCTAssertTrue(view.core.hasSelection())

        let menuWithSelection = menuDelegate.editMenuInteraction(interaction, menuFor: config, suggestedActions: [])
        guard let copyAction = menuWithSelection?.children.first as? UIAction else {
            return XCTFail("expected exactly one UIAction offering Copy")
        }
        XCTAssertEqual(menuWithSelection?.children.count, 1)
        XCTAssertEqual(copyAction.title, "Copy")
    }

    @available(iOS 16.0, *)
    func testEditMenuDelegateCopyActionInvokesExistingCopyPath() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.feed(data: Data("Copy Invocation Test\r\n".utf8))
        view.core.startSelection(row: 0, col: 0, mode: .linear)
        view.core.extendSelection(row: 0, col: 3)
        XCTAssertTrue(view.core.hasSelection())

        let expectedText = view.selectedText
        XCTAssertNotNil(expectedText)
        var copiedText: String?
        view.copyStringConsumer = { copiedText = $0 }

        let menuDelegate = TakoTerminalViewEditMenuDelegate(terminalView: view)
        let interaction = UIEditMenuInteraction(delegate: menuDelegate)
        let config = UIEditMenuConfiguration(identifier: nil, sourcePoint: .zero)
        guard let copyAction = menuDelegate.editMenuInteraction(
            interaction,
            menuFor: config,
            suggestedActions: []
        )?.children.first as? UIAction else {
            return XCTFail("expected a Copy UIAction while a selection exists")
        }

        copyAction.performWithSender(nil, target: nil)

        XCTAssertEqual(copiedText, expectedText,
                       "the delegate's Copy action must invoke the view's existing copy(_:) implementation")
    }

    func testRectangularSelectionSnapshotAndSelectedText() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.feed(data: Data("AAAA\r\nBBBB\r\nCCCC\r\n".utf8))

        view.core.startSelection(row: 0, col: 1, mode: .rectangular)
        view.core.extendSelection(row: 2, col: 2)

        XCTAssertTrue(view.core.hasSelection())
        let snapshot = view.core.snapshot()
        XCTAssertNotNil(snapshot.selection)
        XCTAssertEqual(snapshot.selection?.mode, .rectangular)
        XCTAssertEqual(snapshot.selection?.startCol, 1)
        XCTAssertEqual(snapshot.selection?.endCol, 2)

        let selected = view.selectedText
        XCTAssertEqual(selected, "AA\nBB\nCC")
    }

    func testTerminalScreenPasteBracketedPasteMode() {
        let core = TakoCore(cols: 80, rows: 24)
        core.feed(bytes: Data("\u{001B}[?2004h".utf8))

        let pasteText = "echo hello"
        let encoded = core.encodePaste(text: pasteText)
        let pasteString = String(data: encoded, encoding: .utf8) ?? ""

        XCTAssertTrue(pasteString.contains("\u{001B}[200~"))
        XCTAssertTrue(pasteString.contains("echo hello"))
        XCTAssertTrue(pasteString.contains("\u{001B}[201~"))
    }

    func testScrollbackSelectionTextHighlightAndDrags() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))

        var text = ""
        for i in 1...50 {
            text += "History Line \(i)\r\n"
        }
        view.feed(data: Data(text.utf8))
        XCTAssertGreaterThan(view.scrollbackLength, 0)

        view.scrollViewportUp(lines: 10)
        XCTAssertEqual(view.viewportOffset, 10)

        view.core.startSelection(row: 0, col: 0, mode: .linear)
        view.core.extendSelection(row: 0, col: 13)

        let selected = view.selectedText
        XCTAssertNotNil(selected)
        XCTAssertTrue(selected?.contains("History Line") ?? false)

        let range = view.core.selectionRange()
        XCTAssertNotNil(range)
        XCTAssertEqual(range?.startRow, 0)
        XCTAssertEqual(range?.endRow, 0)

        view.core.startSelection(row: 2, col: 10, mode: .linear)
        view.core.extendSelection(row: 0, col: 0)
        let reverseSelected = view.selectedText
        XCTAssertNotNil(reverseSelected)

        view.core.clearSelection()
        XCTAssertNil(view.selectedText)
        XCTAssertNil(view.core.selectionRange())

        view.scrollViewportToBottom()
        XCTAssertEqual(view.viewportOffset, 0)
    }

    func testReverseRectangularSelectionAndRenderingInputs() {
        let view = TakoTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        view.feed(data: Data("AAAA\r\nBBBB\r\nCCCC\r\n".utf8))

        // Drag bottom-right (row 2, col 2) to top-left (row 0, col 1)
        view.core.startSelection(row: 2, col: 2, mode: .rectangular)
        view.core.extendSelection(row: 0, col: 1)

        XCTAssertTrue(view.core.hasSelection())
        XCTAssertEqual(view.selectedText, "AA\nBB\nCC")

        let range = view.core.selectionRange()
        XCTAssertNotNil(range)
        XCTAssertEqual(range?.startRow, 0)
        XCTAssertEqual(range?.endRow, 2)
        XCTAssertEqual(range?.startCol, 1)
        XCTAssertEqual(range?.endCol, 2)
    }


}
#endif
