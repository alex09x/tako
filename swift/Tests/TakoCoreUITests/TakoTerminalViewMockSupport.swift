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
import QuartzCore
import UIKit

/// A long press whose state a test can set. A real recognizer only takes a
/// state inside UIKit's recognition cycle; set from a test, it stays
/// `.possible` and the handler does nothing.
final class MockLongPressGestureRecognizer: UILongPressGestureRecognizer {
    private var mockState: UIGestureRecognizer.State = .possible

    override var state: UIGestureRecognizer.State {
        get { mockState }
        set { mockState = newValue }
    }
}

final class MockPanGestureRecognizer: UIPanGestureRecognizer {
    private var mockState: UIGestureRecognizer.State = .possible
    private var mockTranslation: CGPoint = .zero
    private var mockLocation: CGPoint = .zero
    private var mockVelocity: CGPoint = .zero

    override var state: UIGestureRecognizer.State {
        get { mockState }
        set { mockState = newValue }
    }

    override func translation(in view: UIView?) -> CGPoint {
        mockTranslation
    }

    override func setTranslation(_ translation: CGPoint, in view: UIView?) {
        mockTranslation = translation
    }

    override func location(in view: UIView?) -> CGPoint {
        mockLocation
    }

    func setMockLocation(_ point: CGPoint) {
        mockLocation = point
    }

    override func velocity(in view: UIView?) -> CGPoint {
        mockVelocity
    }

    func setMockVelocity(_ velocity: CGPoint) {
        mockVelocity = velocity
    }
}

@MainActor
final class MockTerminalViewDelegate: TakoTerminalViewDelegate {
    var inputDataReceived = Data()
    var deviceReplyDataReceived = Data()
    var lastResizedCols: Int?
    var lastResizedRows: Int?
    var resizeCount = 0
    var lastTitle: String?
    var onTitleChange: ((String) -> Void)?
    var bellCount = 0

    func terminalView(_ view: TakoTerminalView, sendInputData data: Data) {
        inputDataReceived.append(data)
    }

    func terminalView(_ view: TakoTerminalView, sendDeviceReplyData data: Data) {
        deviceReplyDataReceived.append(data)
    }

    func terminalView(_ view: TakoTerminalView, didResizeCols cols: Int, rows: Int) {
        resizeCount += 1
        lastResizedCols = cols
        lastResizedRows = rows
    }

    func terminalView(_ view: TakoTerminalView, didChangeTitle title: String) {
        lastTitle = title
        onTitleChange?(title)
    }

    func terminalViewDidBell(_ view: TakoTerminalView) {
        bellCount += 1
    }

    var clipboardCopies: [String] = []
    var lastWorkingDirectory: String?
    var scrollPositions: [Double] = []
    var contentChangeCount = 0
    var commandStartCount = 0
    var commandExitCodes: [Int32?] = []

    func terminalView(_ view: TakoTerminalView, didRequestClipboardCopy text: String) {
        clipboardCopies.append(text)
    }

    func terminalView(_ view: TakoTerminalView, didChangeWorkingDirectory url: String) {
        lastWorkingDirectory = url
    }

    func terminalView(_ view: TakoTerminalView, didScrollTo position: Double) {
        scrollPositions.append(position)
    }

    func terminalViewDidChangeContent(_ view: TakoTerminalView) {
        contentChangeCount += 1
    }

    func terminalViewCommandDidStart(_ view: TakoTerminalView) {
        commandStartCount += 1
    }

    func terminalView(_ view: TakoTerminalView, commandDidEnd exitCode: Int32?) {
        commandExitCodes.append(exitCode)
    }
}
#endif

#endif
