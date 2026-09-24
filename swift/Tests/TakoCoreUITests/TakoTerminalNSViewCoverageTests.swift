import Foundation
import XCTest
@testable import TakoCoreUI

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import CoreGraphics
import Metal

@MainActor
final class CoverageMockDelegate: TakoTerminalNSViewDelegate {
    var inputDataReceived = Data()
    var deviceReplyDataReceived = Data()
    var lastResizedCols: Int?
    var lastResizedRows: Int?
    var resizeCount = 0
    var lastTitle: String?
    var bellCount = 0
    var commandStartCount = 0
    var commandExitCodes: [Int32?] = []
    var clipboardCopies: [String] = []
    var lastWorkingDirectory: String?
    var scrollPositions: [Double] = []
    var contentChangeCount = 0
    var restoredCheckpoints: [TerminalCheckpointRestore] = []

    func terminalView(_ view: TakoTerminalNSView, sendInputData data: Data) {
        inputDataReceived.append(data)
    }

    func terminalView(_ view: TakoTerminalNSView, sendDeviceReplyData data: Data) {
        deviceReplyDataReceived.append(data)
    }

    func terminalView(_ view: TakoTerminalNSView, didResizeCols cols: Int, rows: Int) {
        resizeCount += 1
        lastResizedCols = cols
        lastResizedRows = rows
    }

    func terminalView(_ view: TakoTerminalNSView, didRestoreCheckpoint restore: TerminalCheckpointRestore) {
        restoredCheckpoints.append(restore)
    }

    func terminalView(_ view: TakoTerminalNSView, didChangeTitle title: String) {
        lastTitle = title
    }

    func terminalViewDidBell(_ view: TakoTerminalNSView) {
        bellCount += 1
    }

    func terminalViewCommandDidStart(_ view: TakoTerminalNSView) {
        commandStartCount += 1
    }

    func terminalView(_ view: TakoTerminalNSView, commandDidEnd exitCode: Int32?) {
        commandExitCodes.append(exitCode)
    }

    func terminalView(_ view: TakoTerminalNSView, didRequestClipboardCopy text: String) {
        clipboardCopies.append(text)
    }

    func terminalView(_ view: TakoTerminalNSView, didChangeWorkingDirectory url: String) {
        lastWorkingDirectory = url
    }

    func terminalView(_ view: TakoTerminalNSView, didScrollTo position: Double) {
        scrollPositions.append(position)
    }

    func terminalViewDidChangeContent(_ view: TakoTerminalNSView) {
        contentChangeCount += 1
    }
}

final class MockValidatedItem: NSObject, NSValidatedUserInterfaceItem {
    let action: Selector?
    let tag: Int
    init(action: Selector?, tag: Int = 0) {
        self.action = action
        self.tag = tag
        super.init()
    }
}

final class MockDraggingInfo: NSObject, NSDraggingInfo {
    let pasteboard: NSPasteboard
    init(pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
        super.init()
    }

    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .copy }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 0 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var namesOfPromisedFilesDroppedAtDestination: [String]? { nil }
    var draggingFormation: NSDraggingFormation { get { .default } set {} }
    var animatesToDestination: Bool { get { false } set {} }
    var numberOfValidItemsForDrop: Int { get { 0 } set {} }
    func enumerateDraggingItems(
        options: NSDraggingItemEnumerationOptions = [],
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

private class SubclassedTerminalView: TakoTerminalNSView {
    var titleChangedNotifications = 0
    override func titleDidChange() {
        super.titleDidChange()
        titleChangedNotifications += 1
    }
}

@MainActor
final class TakoTerminalNSViewCoverageTests: XCTestCase {

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.accessory)
        TakoTerminalNSView.isMetalDisabledForTesting = true
    }

    @MainActor private func drawForTesting(_ view: TakoTerminalNSView) {
        let size = NSSize(width: max(view.bounds.width, 10), height: max(view.bounds.height, 10))
        let image = NSImage(size: size)
        image.lockFocus()
        view.draw(view.bounds)
        image.unlockFocus()
    }

    private func makeHostedView(frame: NSRect = NSRect(x: 0, y: 0, width: 800, height: 600)) -> (TakoTerminalNSView, NSWindow) {
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let view = TakoTerminalNSView(frame: frame)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        view.layoutSubtreeIfNeeded()
        return (view, window)
    }

    // MARK: - 1. Initialization, Coder, and Subclassing

    func testCoderInitialization() throws {
        let archiver = NSKeyedArchiver(requiringSecureCoding: false)
        archiver.finishEncoding()
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archiver.encodedData)
        let view = TakoTerminalNSView(coder: unarchiver)
        XCTAssertNotNil(view)
        XCTAssertEqual(view?.cols, 80)
        XCTAssertEqual(view?.rows, 24)
    }

    func testSubclassAndTitleDidChange() {
        let view = SubclassedTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertEqual(view.titleChangedNotifications, 0)
        view.title = "Updated Title"
        XCTAssertEqual(view.title, "Updated Title")
        XCTAssertEqual(view.titleChangedNotifications, 1)
    }

    func testThemeMutationUpdatesMetricsAndInvalidatesDisplay() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        var customTheme = TerminalTheme.takoDefault
        customTheme.fontSize = 18.0
        customTheme.fontFamily = "Monaco"
        customTheme.cellWidth = 11.0
        customTheme.cellHeight = 22.0
        customTheme.cursorBlink = true

        view.theme = customTheme
        XCTAssertEqual(CTFontGetSize(view.renderer.metrics.font), 18.0)
        XCTAssertEqual(view.cellWidth, 11.0)
        XCTAssertEqual(view.cellHeight, 22.0)
        XCTAssertTrue(view.redrawPending)
        XCTAssertNotNil(view.blinkTimer)
    }

    // MARK: - 2. Accessibility

    func testAccessibilityProtocolProperties() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.feed(data: Data("Accessible Row 1\r\nAccessible Row 2".utf8))

        XCTAssertTrue(view.isAccessibilityElement())
        XCTAssertEqual(view.accessibilityRole(), .textArea)
        XCTAssertEqual(view.accessibilityLabel(), "Terminal")

        let value = view.accessibilityValue() as? String
        XCTAssertNotNil(value)
        XCTAssertTrue(value?.contains("Accessible Row 1") == true)
        XCTAssertEqual(view.accessibilityNumberOfCharacters(), value?.count ?? 0)

        XCTAssertNil(view.accessibilitySelectedText())
        view.core.startSelection(row: 0, col: 0, mode: .linear)
        view.core.extendSelection(row: 0, col: 10)
        XCTAssertEqual(view.accessibilitySelectedText(), "Accessible")
    }

    // MARK: - 3. Checkpoints

    func testCheckpointsExportImportAndInspect() throws {
        let (view, _) = makeHostedView()
        let delegate = CoverageMockDelegate()
        view.delegate = delegate

        view.feed(data: Data("Preserved before checkpoint\r\n".utf8))

        let version = view.checkpointVersion
        XCTAssertGreaterThan(version, 0)
        XCTAssertTrue(view.supportsCheckpointVersion(version))
        XCTAssertFalse(view.supportsCheckpointVersion(0xFFFFFF))

        let blob = try view.exportCheckpoint()
        XCTAssertFalse(blob.isEmpty)

        let info = try view.inspectCheckpoint(blob)
        XCTAssertEqual(info.version, version)
        XCTAssertEqual(Int(info.cols), view.cols)
        XCTAssertEqual(Int(info.rows), view.rows)

        view.feed(data: Data("Added after checkpoint\r\n".utf8))
        XCTAssertTrue(view.plainText(startRow: 1, maxRows: 1).contains("Added after checkpoint"))

        let restore = try view.importCheckpoint(blob)
        XCTAssertEqual(restore.cols, view.cols)
        XCTAssertEqual(restore.rows, view.rows)
        XCTAssertEqual(delegate.restoredCheckpoints.count, 1)
        XCTAssertGreaterThanOrEqual(delegate.contentChangeCount, 1)
        XCTAssertTrue(view.plainText(startRow: 0, maxRows: 1).contains("Preserved before checkpoint"))

        XCTAssertThrowsError(try view.importCheckpoint(Data([0, 1, 2, 3])))
    }

    // MARK: - 4. Parser Outcomes & Host Callbacks

    func testWorkingDirectoryAndURLParsing() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = CoverageMockDelegate()
        view.delegate = delegate

        view.feed(data: Data("\u{1b}]7;file://localhost/Volumes/data/repo/path\u{07}".utf8))
        XCTAssertEqual(delegate.lastWorkingDirectory, "/Volumes/data/repo/path")
        XCTAssertEqual(view.workingDirectory, "/Volumes/data/repo/path")

        view.feed(data: Data("\u{1b}]7;/direct/unix/path\u{07}".utf8))
        XCTAssertEqual(delegate.lastWorkingDirectory, "/direct/unix/path")
        XCTAssertEqual(view.workingDirectory, "/direct/unix/path")
    }

    func testSynchronizedOutputHoldingRedraw() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        view.feed(data: Data("\u{1b}[?2026h".utf8))
        XCTAssertTrue(view.core.isSynchronizedOutputActive())

        view.scheduleRedraw()
        view.redrawNow()

        view.feed(data: Data("Buffer updated during sync\r\n".utf8))
        XCTAssertTrue(view.core.isSynchronizedOutputActive())

        view.feed(data: Data("\u{1b}[?2026l".utf8))
        XCTAssertFalse(view.core.isSynchronizedOutputActive())
        XCTAssertTrue(view.plainText(startRow: 0, maxRows: 1).contains("Buffer updated during sync"))
    }

    func testScrollPositionNotificationOnBufferMutation() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let delegate = CoverageMockDelegate()
        view.delegate = delegate

        let lines = (0..<100).map { "Line \($0)" }.joined(separator: "\r\n") + "\r\n"
        view.feed(data: Data(lines.utf8))

        view.scrollPosition = 0.5
        XCTAssertEqual(view.scrollPosition, 0.5, accuracy: 0.05)

        view.scrollViewportUp(lines: 10)
        XCTAssertFalse(delegate.scrollPositions.isEmpty)

        view.scrollViewportDown(lines: 5)
        XCTAssertGreaterThan(delegate.scrollPositions.count, 1)

        view.scrollViewportToBottom()
        XCTAssertEqual(view.viewportOffset, 0)
    }

    // MARK: - 5. Scroll & Viewport API

    func testScrollAPI() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let lines = (0..<50).map { "Row \($0)" }.joined(separator: "\r\n") + "\r\n"
        view.feed(data: Data(lines.utf8))

        XCTAssertTrue(view.bufferText.contains("Row 0"))
        XCTAssertGreaterThan(view.scrollbackLength, 0)

        view.scrollToOffset(10)
        XCTAssertEqual(view.viewportOffset, 10)

        view.scrollToOffset(0)
        XCTAssertEqual(view.viewportOffset, 0)

        let edgeText = view.plainText(startRow: 1000, maxRows: 10)
        XCTAssertEqual(edgeText, "")

        let clampedText = view.plainText(startRow: -5, maxRows: -2)
        XCTAssertFalse(clampedText.isEmpty)

        let origin = view.cellOrigin(row: 2, col: 5)
        XCTAssertEqual(origin.x, view.gridLayout.left + 5 * view.cellWidth)

        let cell = view.cellAt(NSPoint(x: origin.x + 2, y: origin.y + 2))
        XCTAssertEqual(cell.row, 2)
        XCTAssertEqual(cell.col, 5)

        let clampedMin = view.cellAt(NSPoint(x: -100, y: 10000))
        XCTAssertEqual(clampedMin.row, 0)
        XCTAssertEqual(clampedMin.col, 0)

        let clampedMax = view.cellAt(NSPoint(x: 10000, y: -10000))
        XCTAssertEqual(clampedMax.row, view.rows - 1)
        XCTAssertEqual(clampedMax.col, view.cols - 1)

        view.setMouseCell((row: 3, col: 4))
        XCTAssertEqual(view.mouseCell?.row, 3)
        XCTAssertEqual(view.mouseCell?.col, 4)
        view.setMouseCell(nil)
        XCTAssertNil(view.mouseCell)

        XCTAssertNotNil(view.presentationCadence)
        XCTAssertNil(view.metalRendererForTesting)
    }

    // MARK: - 6. Metal Palette & Colors

    func testMetalColorAndPaletteEncodings() {
        let theme = TerminalTheme.takoDefault
        let paletteDisplay = TakoTerminalNSView.metalPalette(for: theme, encoding: .displayEncoded)
        XCTAssertEqual(paletteDisplay.background.w, Float(theme.backgroundOpacity))

        let paletteLinear = TakoTerminalNSView.metalPalette(for: theme, encoding: .linear)
        XCTAssertEqual(paletteLinear.background.w, Float(theme.backgroundOpacity))

        let gray1 = CGColor(gray: 0.5, alpha: 1.0)
        let color1 = TakoTerminalNSView.metalColor(gray1, alpha: 0.8, encoding: .displayEncoded)
        XCTAssertEqual(color1.w, 0.8)

        let rgb = CGColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 0.9)
        let colorRGB = TakoTerminalNSView.metalColor(rgb, encoding: .displayEncoded)
        XCTAssertEqual(colorRGB.w, 0.9)

        let colorRGBAlpha = TakoTerminalNSView.metalColor(rgb, alpha: 0.5, encoding: .linear)
        XCTAssertEqual(colorRGBAlpha.w, 0.5)

        let size = TakoTerminalNSView.drawableSize(for: CGSize(width: 800.7, height: 600.2), scale: 2.0)
        XCTAssertEqual(size.width, 1601.0)
        XCTAssertEqual(size.height, 1200.0)

        let clampedSize = TakoTerminalNSView.drawableSize(for: CGSize(width: 0, height: 0), scale: 0.5)
        XCTAssertEqual(clampedSize.width, 1.0)
        XCTAssertEqual(clampedSize.height, 1.0)
    }

    // MARK: - 7. Window, Backing, Tracking and Resizing

    func testWindowLifecycleAndBackingProperties() {
        let (view, window) = makeHostedView()
        let delegate = CoverageMockDelegate()
        view.delegate = delegate

        view.viewDidChangeBackingProperties()
        view.viewDidHide()
        view.viewDidUnhide()

        NotificationCenter.default.post(
            name: NSWindow.didResignKeyNotification,
            object: window
        )
        NotificationCenter.default.post(
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )

        let unrelatedWindow = NSWindow()
        NotificationCenter.default.post(
            name: NSWindow.didResignKeyNotification,
            object: unrelatedWindow
        )

        view.setFrameSize(NSSize(width: 500, height: 350))
        view.setFrameSize(NSSize(width: 500, height: 350))
        view.flushPendingResizeForTesting()
        XCTAssertNotNil(delegate.lastResizedCols)
        XCTAssertNotNil(delegate.lastResizedRows)

        view.updateTrackingAreas()
        XCTAssertFalse(view.trackingAreas.isEmpty)

        window.contentView = nil
        XCTAssertNil(view.window)
    }

    // MARK: - 8. First Responder and Focus

    func testFirstResponderTransitionsAndMarkedTextCleanup() {
        let (view, window) = makeHostedView()
        window.makeFirstResponder(view)

        let exp = expectation(description: "responder activation")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1.0)

        view.setMarkedText("unfinished", selectedRange: NSRange(location: 10, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())

        _ = view.resignFirstResponder()
        XCTAssertFalse(view.hasMarkedText())
    }

    func testShouldHoldInputContextPermutations() {
        XCTAssertTrue(TakoTerminalNSView.shouldHoldInputContext(hasWindow: true, isKeyWindow: true, isFirstResponder: true, isHidden: false))
        XCTAssertFalse(TakoTerminalNSView.shouldHoldInputContext(hasWindow: false, isKeyWindow: true, isFirstResponder: true, isHidden: false))
        XCTAssertFalse(TakoTerminalNSView.shouldHoldInputContext(hasWindow: true, isKeyWindow: false, isFirstResponder: true, isHidden: false))
        XCTAssertFalse(TakoTerminalNSView.shouldHoldInputContext(hasWindow: true, isKeyWindow: true, isFirstResponder: false, isHidden: false))
        XCTAssertFalse(TakoTerminalNSView.shouldHoldInputContext(hasWindow: true, isKeyWindow: true, isFirstResponder: true, isHidden: true))
    }

    // MARK: - 9. Keyboard Input Encoding

    func testKeyboardInputNamedKeysAndModifiers() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = CoverageMockDelegate()
        view.delegate = delegate

        let namedKeyCodes: [(UInt16, String)] = [
            (49, " "),      // Space
            (48, "\t"),     // Tab
            (53, "\u{1b}"), // Escape
            (51, "\u{7f}"), // Backspace
            (126, "\u{1b}[A"), // Up
            (125, "\u{1b}[B"), // Down
            (124, "\u{1b}[C"), // Right
            (123, "\u{1b}[D"), // Left
            (115, "\u{1b}[H"), // Home
            (119, "\u{1b}[F"), // End
            (116, "\u{1b}[5~"), // PageUp
            (121, "\u{1b}[6~"), // PageDown
            (117, "\u{1b}[3~"), // Delete forward
            (122, "\u{1b}OP"),  // F1
            (120, "\u{1b}OQ"),  // F2
            (99, "\u{1b}OR"),   // F3
            (118, "\u{1b}OS"),  // F4
            (96, "\u{1b}[15~"), // F5
            (97, "\u{1b}[17~"), // F6
            (98, "\u{1b}[18~"), // F7
            (100, "\u{1b}[19~"), // F8
            (101, "\u{1b}[20~"), // F9
            (109, "\u{1b}[21~"), // F10
            (103, "\u{1b}[23~"), // F11
            (111, "\u{1b}[24~"), // F12
        ]

        for (keyCode, expectedPrefix) in namedKeyCodes {
            delegate.inputDataReceived.removeAll()
            let event = NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "",
                charactersIgnoringModifiers: "",
                isARepeat: false,
                keyCode: keyCode
            )!
            view.keyDown(with: event)
            let received = String(data: delegate.inputDataReceived, encoding: .utf8) ?? ""
            XCTAssertFalse(received.isEmpty, "No data received for keyCode \(keyCode)")
            if keyCode == 49 {
                XCTAssertEqual(received, " ")
            } else if keyCode == 48 {
                XCTAssertEqual(received, "\t")
            } else {
                XCTAssertTrue(received.hasPrefix("\u{1b}") || received.hasPrefix("\r") || received.hasPrefix("\u{7f}"), "Unexpected sequence for keyCode \(keyCode): \(received.debugDescription)")
            }
        }

        delegate.inputDataReceived.removeAll()
        let shiftUp = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: true,
            keyCode: 126
        )!
        view.keyDown(with: shiftUp)
        XCTAssertFalse(delegate.inputDataReceived.isEmpty)

        delegate.inputDataReceived.removeAll()
        let cmdA = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        )!
        view.keyDown(with: cmdA)
        XCTAssertTrue(delegate.inputDataReceived.isEmpty, "Command-modified keys must not send direct PTY bytes")

        delegate.inputDataReceived.removeAll()
        let emptyEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: 0
        )!
        view.keyDown(with: emptyEvent)
        XCTAssertTrue(delegate.inputDataReceived.isEmpty)
    }

    func testTypingWhileScrolledUpRevealsLiveScreen() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let lines = (0..<50).map { "Line \($0)" }.joined(separator: "\r\n") + "\r\n"
        view.feed(data: Data(lines.utf8))

        view.scrollViewportUp(lines: 10)
        XCTAssertGreaterThan(view.viewportOffset, 0)

        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "x",
            charactersIgnoringModifiers: "x",
            isARepeat: false,
            keyCode: 7
        )!
        view.keyDown(with: event)
        XCTAssertEqual(view.viewportOffset, 0, "Typing must reveal live screen")
    }

    // MARK: - 10. Mouse Events & Reports

    func testMouseReportBytesClampingAndModifiers() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.feed(data: Data("\u{1b}[?1003h\u{1b}[?1006h".utf8))
        let negativeBytes = view.mouseReportBytes(button: .left, action: .press, cell: (-5, -10))
        XCTAssertFalse(negativeBytes.isEmpty)

        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [.shift, .option, .control],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        )!
        let modifiedBytes = view.mouseReportBytes(button: .left, action: .motion, cell: (5, 5), event: event)
        XCTAssertFalse(modifiedBytes.isEmpty)
    }

    func testMouseClickSelectionModes() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.feed(data: Data("hello world this is a test line\r\n".utf8))

        let p = view.cellOrigin(row: 0, col: 2)
        let singleOpt = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: p.x + 2, y: p.y + 2),
            modifierFlags: [.option],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        )!
        view.mouseDown(with: singleOpt)
        XCTAssertEqual(view.core.selectionRange()?.mode, .rectangular)

        let tripleClick = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: p.x + 2, y: p.y + 2),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 3,
            pressure: 1.0
        )!
        view.mouseDown(with: tripleClick)
        XCTAssertTrue(view.core.selectedText()?.contains("hello world") == true)

        let drag = NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: NSPoint(x: p.x + 50, y: p.y + 2),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 3,
            pressure: 1.0
        )!
        view.mouseDragged(with: drag)

        let up = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: NSPoint(x: p.x + 2, y: p.y + 2),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0.0
        )!
        let singleClick = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: p.x + 2, y: p.y + 2),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        )!
        view.mouseDown(with: singleClick)
        view.mouseUp(with: up)
        XCTAssertNil(view.core.selectedText())
    }

    func testRightAndOtherMouseEvents() {
        let (view, _) = makeHostedView()
        let delegate = CoverageMockDelegate()
        view.delegate = delegate

        view.feed(data: Data("\u{1b}[?1003h\u{1b}[?1006h".utf8))

        let rightDown = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: NSPoint(x: 50, y: 550),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        )!
        view.rightMouseDown(with: rightDown)
        XCTAssertFalse(delegate.inputDataReceived.isEmpty)
        delegate.inputDataReceived.removeAll()

        let rightUp = NSEvent.mouseEvent(
            with: .rightMouseUp,
            location: NSPoint(x: 50, y: 550),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0.0
        )!
        view.rightMouseUp(with: rightUp)
        XCTAssertFalse(delegate.inputDataReceived.isEmpty)
        delegate.inputDataReceived.removeAll()

        let otherDown = NSEvent.mouseEvent(
            with: .otherMouseDown,
            location: NSPoint(x: 50, y: 550),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        )!
        view.otherMouseDown(with: otherDown)
        XCTAssertFalse(delegate.inputDataReceived.isEmpty)
        delegate.inputDataReceived.removeAll()

        let otherUp = NSEvent.mouseEvent(
            with: .otherMouseUp,
            location: NSPoint(x: 50, y: 550),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0.0
        )!
        view.otherMouseUp(with: otherUp)
        XCTAssertFalse(delegate.inputDataReceived.isEmpty)
        delegate.inputDataReceived.removeAll()

        let moved = NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(x: 50, y: 550),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0.0
        )!
        view.mouseMoved(with: moved)
        XCTAssertFalse(delegate.inputDataReceived.isEmpty)
        XCTAssertNotNil(view.mouseCell)

        view.mouseEntered(with: moved)
        view.mouseExited(with: moved)
        XCTAssertNil(view.mouseCell)
    }

    // MARK: - 11. Scroll Wheel in All Modes

    private func makeScrollEvent(deltaY: Int32, precise: Bool, phase: NSEvent.Phase = []) -> NSEvent? {
        guard let cg = CGEvent(
            scrollWheelEvent2Source: nil,
            units: precise ? .pixel : .line,
            wheelCount: 1,
            wheel1: deltaY, wheel2: 0, wheel3: 0
        ) else { return nil }
        return NSEvent(cgEvent: cg)
    }

    func testScrollWheelAlternateScreenAlternateScroll() throws {
        let (view, _) = makeHostedView()
        let delegate = CoverageMockDelegate()
        view.delegate = delegate

        view.feed(data: Data("\u{1b}[?1049h\u{1b}[?1007h".utf8))
        XCTAssertTrue(view.isAlternateScreen)
        XCTAssertTrue(view.isAlternateScroll)

        let scrollUpPrecise = try XCTUnwrap(makeScrollEvent(deltaY: 9, precise: true))
        view.scrollWheel(with: scrollUpPrecise)
        let upStr = String(data: delegate.inputDataReceived, encoding: .utf8) ?? ""
        XCTAssertTrue(upStr.contains("\u{1b}[A") || upStr.contains("\u{1b}OA"))
        delegate.inputDataReceived.removeAll()

        let scrollDownNotched = try XCTUnwrap(makeScrollEvent(deltaY: -2, precise: false))
        view.scrollWheel(with: scrollDownNotched)
        let downStr = String(data: delegate.inputDataReceived, encoding: .utf8) ?? ""
        XCTAssertTrue(downStr.contains("\u{1b}[B") || downStr.contains("\u{1b}OB"))
    }

    func testScrollWheelReportingModeWheelUpAndDown() throws {
        let (view, _) = makeHostedView()
        let delegate = CoverageMockDelegate()
        view.delegate = delegate

        view.feed(data: Data("\u{1b}[?1000h\u{1b}[?1006h".utf8))
        delegate.inputDataReceived.removeAll()

        let scrollUp = try XCTUnwrap(makeScrollEvent(deltaY: 6, precise: true))
        view.scrollWheel(with: scrollUp)
        XCTAssertFalse(delegate.inputDataReceived.isEmpty)
        delegate.inputDataReceived.removeAll()

        let scrollDown = try XCTUnwrap(makeScrollEvent(deltaY: -6, precise: true))
        view.scrollWheel(with: scrollDown)
        XCTAssertFalse(delegate.inputDataReceived.isEmpty)
    }

    func testScrollWheelLocalBoundarySettlement() throws {
        let (view, _) = makeHostedView()
        let lines = (0..<30).map { "Line \($0)" }.joined(separator: "\r\n") + "\r\n"
        view.feed(data: Data(lines.utf8))

        let scrollUp = try XCTUnwrap(makeScrollEvent(deltaY: 10, precise: false))
        view.scrollWheel(with: scrollUp)
        XCTAssertGreaterThan(view.viewportOffset, 0)

        let scrollDown = try XCTUnwrap(makeScrollEvent(deltaY: -20, precise: false))
        view.scrollWheel(with: scrollDown)
        XCTAssertEqual(view.viewportOffset, 0)
    }

    // MARK: - 12. Copy, Paste, Select All

    func testCopyPasteAndSelectAll() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = CoverageMockDelegate()
        view.delegate = delegate

        var copied: String?
        view.copyStringConsumer = { copied = $0 }

        view.copy(nil)
        XCTAssertNil(copied)

        view.feed(data: Data("Text to copy\r\n".utf8))
        view.core.startSelection(row: 0, col: 0, mode: .linear)
        view.core.extendSelection(row: 0, col: 4)
        view.copy(nil)
        XCTAssertEqual(copied, "Text")

        view.pasteStringProvider = { nil }
        view.paste(nil)
        XCTAssertTrue(delegate.inputDataReceived.isEmpty)

        let pasteLines = (0..<30).map { "Line \($0)" }.joined(separator: "\r\n") + "\r\n"
        view.feed(data: Data(pasteLines.utf8))
        view.scrollViewportUp(lines: 5)
        XCTAssertGreaterThan(view.viewportOffset, 0)

        view.pasteStringProvider = { "Pasted Live" }
        view.paste(nil)
        XCTAssertEqual(view.viewportOffset, 0)
        XCTAssertEqual(delegate.inputDataReceived, Data("Pasted Live".utf8))

        view.selectAll(nil)
        XCTAssertTrue(view.core.hasSelection())
    }

    // MARK: - 13. Drag and Drop

    func testDraggingEnteredAndPerformDragOperation() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = CoverageMockDelegate()
        view.delegate = delegate

        let emptyPasteboard = NSPasteboard.withUniqueName()
        let emptySender = MockDraggingInfo(pasteboard: emptyPasteboard)
        XCTAssertEqual(view.draggingEntered(emptySender), [])
        XCTAssertFalse(view.performDragOperation(emptySender))

        let urlPasteboard = NSPasteboard.withUniqueName()
        let url1 = URL(fileURLWithPath: "/tmp/path with space/file1.txt")
        let url2 = URL(fileURLWithPath: "/tmp/normal_file2.txt")
        urlPasteboard.writeObjects([url1 as NSURL, url2 as NSURL])
        let urlSender = MockDraggingInfo(pasteboard: urlPasteboard)
        XCTAssertEqual(view.draggingEntered(urlSender), .copy)

        let dragLines = (0..<30).map { "Drag \($0)" }.joined(separator: "\r\n") + "\r\n"
        view.feed(data: Data(dragLines.utf8))
        view.scrollViewportUp(lines: 5)
        XCTAssertGreaterThan(view.viewportOffset, 0)
        XCTAssertTrue(view.performDragOperation(urlSender))
        XCTAssertEqual(view.viewportOffset, 0)
        let pastedURLs = String(data: delegate.inputDataReceived, encoding: .utf8) ?? ""
        XCTAssertTrue(pastedURLs.contains("'/tmp/path with space/file1.txt'"))
        XCTAssertTrue(pastedURLs.contains("/tmp/normal_file2.txt"))

        delegate.inputDataReceived.removeAll()
        let strPasteboard = NSPasteboard.withUniqueName()
        strPasteboard.setString("Dropped Raw String", forType: .string)
        let strSender = MockDraggingInfo(pasteboard: strPasteboard)
        XCTAssertEqual(view.draggingEntered(strSender), .copy)
        XCTAssertTrue(view.performDragOperation(strSender))
        XCTAssertEqual(delegate.inputDataReceived, Data("Dropped Raw String".utf8))
    }

    // MARK: - 14. Services Menu

    func testServicesMenuValidationAndDataTransfer() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = CoverageMockDelegate()
        view.delegate = delegate

        XCTAssertNil(view.validRequestor(forSendType: .string, returnType: .string))
        XCTAssertNotNil(view.validRequestor(forSendType: nil, returnType: .string))

        view.feed(data: Data("Service Selection\r\n".utf8))
        view.core.startSelection(row: 0, col: 0, mode: .linear)
        view.core.extendSelection(row: 0, col: 7)

        XCTAssertTrue((view.validRequestor(forSendType: .string, returnType: .string) as? AnyObject) === view)
        XCTAssertTrue((view.validRequestor(forSendType: .string, returnType: nil) as? AnyObject) === view)

        let pboard = NSPasteboard.withUniqueName()
        XCTAssertTrue(view.writeSelection(to: pboard, types: [.string]))
        XCTAssertEqual(pboard.string(forType: .string), "Service")

        view.core.clearSelection()
        XCTAssertFalse(view.writeSelection(to: pboard, types: [.string]))

        pboard.clearContents()
        pboard.setString("Service Output", forType: .string)
        let serviceLines = (0..<30).map { "Svc \($0)" }.joined(separator: "\r\n") + "\r\n"
        view.feed(data: Data(serviceLines.utf8))
        view.scrollViewportUp(lines: 5)
        XCTAssertGreaterThan(view.viewportOffset, 0)
        XCTAssertTrue(view.readSelection(from: pboard))
        XCTAssertEqual(view.viewportOffset, 0)
        XCTAssertEqual(delegate.inputDataReceived, Data("Service Output".utf8))

        let emptyPboard = NSPasteboard.withUniqueName()
        XCTAssertFalse(view.readSelection(from: emptyPboard))
    }

    // MARK: - 15. NSTextInputClient & UI Validations

    func testNSTextInputClientMethods() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let delegate = CoverageMockDelegate()
        view.delegate = delegate

        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(view.markedRange().location, NSNotFound)
        XCTAssertEqual(view.selectedRange().length, 0)

        view.setMarkedText(NSAttributedString(string: "attr marked"), selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(view.markedRange().length, 11)

        view.setMarkedText(NSAttributedString(string: ""), selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(view.hasMarkedText())

        view.setMarkedText(12345, selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(view.hasMarkedText())

        view.setMarkedText("str marked", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(view.hasMarkedText())
        view.unmarkText()
        XCTAssertFalse(view.hasMarkedText())
        view.unmarkText() // idempotent

        XCTAssertEqual(view.validAttributesForMarkedText(), [])
        XCTAssertEqual(view.characterIndex(for: .zero), 0)

        XCTAssertNil(view.attributedSubstring(forProposedRange: NSRange(location: 0, length: 0), actualRange: nil))

        view.feed(data: Data("Selected Substring\r\n".utf8))
        view.core.startSelection(row: 0, col: 0, mode: .linear)
        view.core.extendSelection(row: 0, col: 8)
        let attr = view.attributedSubstring(forProposedRange: NSRange(location: 0, length: 5), actualRange: nil)
        XCTAssertEqual(attr?.string, "Selected")

        view.insertText(NSAttributedString(string: "\n"), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(delegate.inputDataReceived, Data("\r".utf8))
        delegate.inputDataReceived.removeAll()

        view.insertText("\r", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(delegate.inputDataReceived, Data("\r".utf8))
        delegate.inputDataReceived.removeAll()

        view.insertText("z", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(delegate.inputDataReceived, Data("z".utf8))
        delegate.inputDataReceived.removeAll()

        view.insertText("bulk inserted string", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(delegate.inputDataReceived, Data("bulk inserted string".utf8))
        delegate.inputDataReceived.removeAll()

        view.insertText("", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(delegate.inputDataReceived.isEmpty)

        view.insertText(999, replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(delegate.inputDataReceived.isEmpty)

        view.keyTextAccumulator = "acc_"
        view.insertText("more", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(view.keyTextAccumulator, "acc_more")
        view.keyTextAccumulator = nil

        view.doCommand(by: #selector(NSResponder.insertNewline(_:)))
    }

    func testInputMethodViewRectAndComposingControlHelpers() {
        let normalRect = TakoTerminalNSView.inputMethodViewRect(
            cursorCol: 5,
            cursorRow: 2,
            cols: 80,
            rows: 24,
            cellSize: CGSize(width: 10, height: 20),
            viewHeight: 480,
            range: NSRange(location: 0, length: 1)
        )
        XCTAssertEqual(normalRect.origin.x, 50)
        XCTAssertEqual(normalRect.size.width, 10)

        let zeroRangeRect = TakoTerminalNSView.inputMethodViewRect(
            cursorCol: 78,
            cursorRow: 2,
            cols: 80,
            rows: 24,
            cellSize: CGSize(width: 10, height: 20),
            viewHeight: 480,
            range: NSRange(location: 5, length: 0)
        )
        XCTAssertEqual(zeroRangeRect.size.width, 0)
        XCTAssertEqual(zeroRangeRect.origin.x, 30)

        let overflowRect = TakoTerminalNSView.inputMethodViewRect(
            cursorCol: 70,
            cursorRow: 23,
            cols: 80,
            rows: 24,
            cellSize: CGSize(width: 10, height: 20),
            viewHeight: 480,
            range: NSRange(location: 100, length: 0)
        )
        XCTAssertEqual(overflowRect.origin.x, 800)

        let zeroColsRect = TakoTerminalNSView.inputMethodViewRect(
            cursorCol: 0,
            cursorRow: 0,
            cols: 0,
            rows: 0,
            cellSize: CGSize(width: 10, height: 20),
            viewHeight: 480,
            range: NSRange(location: 0, length: 0)
        )
        XCTAssertEqual(zeroColsRect.origin.x, 0)

        XCTAssertFalse(TakoTerminalNSView.shouldSuppressComposingControlInput("a", composing: false))
        XCTAssertFalse(TakoTerminalNSView.shouldSuppressComposingControlInput(nil, composing: true))
        XCTAssertFalse(TakoTerminalNSView.shouldSuppressComposingControlInput("", composing: true))
        XCTAssertFalse(TakoTerminalNSView.shouldSuppressComposingControlInput("abc", composing: true))
        XCTAssertFalse(TakoTerminalNSView.shouldSuppressComposingControlInput("z", composing: true))
        XCTAssertTrue(TakoTerminalNSView.shouldSuppressComposingControlInput("\u{08}", composing: true))
        XCTAssertTrue(TakoTerminalNSView.shouldSuppressComposingControlInput("\r", composing: true))
    }

    func testFirstRectWithoutAndWithWindow() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let rectWithoutWindow = view.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil)
        XCTAssertGreaterThan(rectWithoutWindow.size.width, 0)

        let (hostedView, _) = makeHostedView()
        let rectWithWindow = hostedView.firstRect(forCharacterRange: NSRange(location: 0, length: 1), actualRange: nil)
        XCTAssertGreaterThan(rectWithWindow.size.width, 0)
    }

    func testValidateUserInterfaceItem() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let copyItem = MockValidatedItem(action: #selector(TakoTerminalNSView.copy(_:)))
        let pasteItem = MockValidatedItem(action: #selector(TakoTerminalNSView.paste(_:)))
        let selectAllItem = MockValidatedItem(action: #selector(TakoTerminalNSView.selectAll(_:)))
        let unknownItem = MockValidatedItem(action: #selector(NSResponder.indent(_:)))

        XCTAssertFalse(view.validateUserInterfaceItem(copyItem))
        view.core.startSelection(row: 0, col: 0, mode: .linear)
        view.core.extendSelection(row: 0, col: 5)
        XCTAssertTrue(view.validateUserInterfaceItem(copyItem))

        // Supply the paste source explicitly: the real pasteboard's contents
        // depend on the machine the suite runs on.
        view.pasteStringProvider = { "clipboard text" }
        XCTAssertTrue(view.validateUserInterfaceItem(pasteItem))
        view.pasteStringProvider = { nil }
        XCTAssertFalse(view.validateUserInterfaceItem(pasteItem))

        XCTAssertTrue(view.validateUserInterfaceItem(selectAllItem))
        XCTAssertFalse(view.validateUserInterfaceItem(unknownItem))
    }

    // MARK: - 16. CPU Draw & Presentation Logic

    func testCPUDrawVariants() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        view.feed(data: Data("Draw test line 1\r\nDraw test line 2\r\n".utf8))

        view.isPresentationPaused = true
        drawForTesting(view)

        view.isPresentationPaused = false
        view.scheduleRedraw()
        drawForTesting(view)

        var semiTransparent = TerminalTheme.takoDefault
        semiTransparent.backgroundOpacity = 0.5
        view.theme = semiTransparent
        view.scheduleRedraw()
        drawForTesting(view)

        view.setMarkedText("MarkedInDraw", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.scheduleRedraw()
        drawForTesting(view)

        view.needsDisplay = false
        XCTAssertFalse(view.needsDisplay)
        view.needsDisplay = true
        XCTAssertTrue(view.redrawPending)
        view.setNeedsDisplay(NSRect(x: 0, y: 0, width: 50, height: 50))
        XCTAssertTrue(view.redrawPending)

        view.displayLinkFired()
    }
}
#endif
