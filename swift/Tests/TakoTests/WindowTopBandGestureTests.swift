/*
 * tako — A modal menu cannot steal the next content gesture's release
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Testing
@testable import Tako

@Suite(.serialized) @MainActor
struct WindowTopBandGestureTests {
    final class ReceiptView: NSView {
        var received: [NSEvent.EventType] = []
        override func mouseUp(with event: NSEvent) { received.append(event.type) }
        override func rightMouseUp(with event: NSEvent) { received.append(event.type) }
        override func otherMouseUp(with event: NSEvent) { received.append(event.type) }
        override func mouseDragged(with event: NSEvent) { received.append(event.type) }
    }

    private func window() -> TerminalWindow {
        _ = NSApplication.shared
        let window = TerminalWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                    styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        return window
    }

    private func event(_ type: NSEvent.EventType, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: CGPoint(x: 50, y: 50),
                                       modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber,
                                       context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }

    @Test func aNewContentPressDropsOnlyItsStaleBandTarget() throws {
        let pairs: [(NSEvent.EventType, NSEvent.EventType)] = [
            (.leftMouseDown, .leftMouseUp), (.rightMouseDown, .rightMouseUp), (.otherMouseDown, .otherMouseUp)
        ]
        for (downType, upType) in pairs {
            let window = window()
            defer { window.close() }
            #expect(!window.isVisible)
            let oldMenu = ReceiptView()
            let down = try event(downType, in: window)
            let up = try event(upType, in: window)
            #expect(down.buttonNumber == up.buttonNumber)
            // Stand-in for a top-band mouseDown that opened modal menu tracking:
            // the menu consumed that press's up, leaving the retained target.
            window.topBandLeftTarget = oldMenu
            window.topBandRightTarget = oldMenu
            let otherButton = downType == .otherMouseDown ? down.buttonNumber : 2
            window.topBandOtherTargets[otherButton] = .init(view: oldMenu)

            #expect(!window.handleInterceptedWindowEvent(down), "a new content press belongs to AppKit")
            switch downType {
            case .leftMouseDown:
                #expect(window.topBandLeftTarget == nil)
                #expect(window.topBandRightTarget === oldMenu)
            case .rightMouseDown:
                #expect(window.topBandRightTarget == nil)
                #expect(window.topBandLeftTarget === oldMenu)
            default:
                #expect(window.topBandOtherTargets[down.buttonNumber] == nil)
                #expect(window.topBandLeftTarget === oldMenu && window.topBandRightTarget === oldMenu)
            }
            #expect(!window.handleInterceptedWindowEvent(up), "the new row's release must not be routed to the earlier menu")
            #expect(oldMenu.received.isEmpty)
        }
    }

    @Test func aMatchingBandDragAndReleaseStillReachTheirTarget() throws {
        let window = window()
        defer { window.close() }
        let target = ReceiptView()
        window.topBandLeftTarget = target
        #expect(window.handleInterceptedWindowEvent(try event(.leftMouseDragged, in: window)))
        #expect(window.handleInterceptedWindowEvent(try event(.leftMouseUp, in: window)))
        #expect(target.received == [.leftMouseDragged, .leftMouseUp])
        #expect(window.topBandLeftTarget == nil)
    }
}
