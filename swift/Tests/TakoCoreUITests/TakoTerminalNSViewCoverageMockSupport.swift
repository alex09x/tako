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
import Carbon
import XCTest
@testable import TakoCoreUI

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

class SubclassedTerminalView: TakoTerminalNSView {
    var titleChangedNotifications = 0
    override func titleDidChange() {
        super.titleDidChange()
        titleChangedNotifications += 1
    }
}
#endif
