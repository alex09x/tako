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

import Foundation
import XCTest
@testable import TakoCoreUI

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

@MainActor
final class MockTerminalNSViewDelegate: TakoTerminalNSViewDelegate {
    var inputDataReceived = Data()
    var deviceReplyDataReceived = Data()
    var lastResizedCols: Int?
    var lastResizedRows: Int?
    var resizeCount = 0
    var lastTitle: String?
    var onTitleChange: ((String) -> Void)?
    var bellCount = 0
    var commandStartCount = 0
    var commandExitCodes: [Int32?] = []
    var clipboardCopies: [String] = []
    var lastWorkingDirectory: String?
    var scrollPositions: [Double] = []
    var contentChangeCount = 0
    var hoveredLinks: [String?] = []

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

    func terminalView(_ view: TakoTerminalNSView, didChangeTitle title: String) {
        lastTitle = title
        onTitleChange?(title)
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

    var promptMarkCount = 0
    var reportedStatuses: [(status: String, text: String?)] = []
    var clearStatusCount = 0

    func terminalView(_ view: TakoTerminalNSView, didChangeWorkingDirectory url: String) {
        lastWorkingDirectory = url
    }

    func terminalView(_ view: TakoTerminalNSView, didScrollTo position: Double) {
        scrollPositions.append(position)
    }

    func terminalViewDidChangeContent(_ view: TakoTerminalNSView) {
        contentChangeCount += 1
    }

    func terminalView(_ view: TakoTerminalNSView, didHoverLink url: String?) {
        hoveredLinks.append(url)
    }

    func terminalViewPromptMark(_ view: TakoTerminalNSView) {
        promptMarkCount += 1
    }

    func terminalView(_ view: TakoTerminalNSView, didReportStatus status: String, text: String?) {
        reportedStatuses.append((status, text))
    }

    func terminalViewDidClearStatus(_ view: TakoTerminalNSView) {
        clearStatusCount += 1
    }
}
#endif

