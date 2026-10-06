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
import Foundation
import SwiftUI
import Testing
@testable import Tako
import TakoKit

// MARK: - Input event translation

@Suite
struct InputCoverageTests {
    @Test func modsFromNSFlagsCoversEveryBit() {
        let flags: NSEvent.ModifierFlags = [.shift, .control, .option, .command, .capsLock]
        let mods = Tako.Input.Mods(nsFlags: flags)
        #expect(mods.contains(.shift))
        #expect(mods.contains(.ctrl))
        #expect(mods.contains(.alt))
        #expect(mods.contains(.super))
        #expect(mods.contains(.capsLock))
        #expect(!mods.contains(.numLock))
    }

    @Test func modsFromEmptyFlagsIsEmpty() {
        let mods = Tako.Input.Mods(nsFlags: [])
        #expect(mods.isEmpty)
    }

    @Test func coreModsMapsEachFlag() {
        let mods: Tako.Input.Mods = [.shift, .alt, .ctrl, .super]
        let core = mods.coreMods
        #expect(core.shift)
        #expect(core.alt)
        #expect(core.ctrl)
        #expect(core.superKey)

        let none = Tako.Input.Mods([]).coreMods
        #expect(!none.shift && !none.alt && !none.ctrl && !none.superKey)
    }

    @Test func actionIsPress() {
        #expect(Tako.Input.Action.press.isPress)
        #expect(Tako.Input.Action.repeatKey.isPress)
        #expect(!Tako.Input.Action.release.isPress)
    }

    @Test func mouseButtonFromNumber() {
        #expect(Tako.Input.MouseButton(nsButtonNumber: 0) == .left)
        #expect(Tako.Input.MouseButton(nsButtonNumber: 1) == .right)
        #expect(Tako.Input.MouseButton(nsButtonNumber: 2) == .middle)
        #expect(Tako.Input.MouseButton(nsButtonNumber: 99) == .unknown)
    }

    @Test(arguments: [
        (UInt16(36), Tako.Input.Key.enter), (48, .tab), (51, .backspace), (53, .escape),
        (49, .space), (126, .up), (125, .down), (123, .left), (124, .right),
        (115, .home), (119, .end), (116, .pageUp), (121, .pageDown),
        (114, .insert), (117, .delete),
        (122, .f1), (120, .f2), (99, .f3), (118, .f4), (96, .f5), (97, .f6),
        (98, .f7), (100, .f8), (101, .f9), (109, .f10), (103, .f11), (111, .f12),
        (9999, .unidentified),
    ])
    func keyFromKeyCode(code: UInt16, expected: Tako.Input.Key) {
        #expect(Tako.Input.Key(keyCode: code) == expected)
    }

    @Test func ffiKeyMapsEveryNamedCase() {
        for key in Tako.Input.Key.allCases {
            let ffi = key.ffiKey
            if key == .unidentified {
                #expect(ffi == .character)
            } else if key == .space {
                // Space is deliberately absent from the table: send(keyEvent:)
                // delivers it as the character " " so modifiers encode as text.
                #expect(Tako.Input.Key.ffiKeys[key] == nil)
            } else {
                #expect(Tako.Input.Key.ffiKeys[key] == ffi)
            }
        }
    }

    @Test func keyEventConvenienceInitDefaultsToPress() {
        let event = Tako.Input.KeyEvent(key: .enter)
        #expect(event.action == .press)
        #expect(event.key == .enter)
        #expect(event.mods.isEmpty)
        #expect(event.text == nil)
    }

    @Test func splitFocusDirectionTranslatesPreviousAndNext() {
        let previousMatches: Bool
        if case .previous = Tako.SplitFocusDirection.previous.toSplitTreeFocusDirection() {
            previousMatches = true
        } else {
            previousMatches = false
        }
        #expect(previousMatches)

        let nextMatches: Bool
        if case .next = Tako.SplitFocusDirection.next.toSplitTreeFocusDirection() {
            nextMatches = true
        } else {
            nextMatches = false
        }
        #expect(nextMatches)
    }

    @Test func splitFocusDirectionTranslatesSpatialDirections() {
        let cases: [(Tako.SplitFocusDirection, SplitTree<Tako.SurfaceView>.Spatial.Direction)] = [
            (.up, .up), (.down, .down), (.left, .left), (.right, .right),
        ]
        for (direction, expected) in cases {
            switch direction.toSplitTreeFocusDirection() {
            case .spatial(let spatial):
                #expect("\(spatial)" == "\(expected)")
            default:
                Issue.record("expected .spatial for \(direction)")
            }
        }
    }

    @Test func clipboardRequestPromptText() {
        #expect(Tako.ClipboardRequest.paste.text().contains("dangerous"))
        #expect(Tako.ClipboardRequest.osc_52_read.text().contains("read"))
        #expect(Tako.ClipboardRequest.osc_52_write(nil).text().contains("write"))
    }

    @Test @MainActor func nsEventTakoKeyEventFromKeyDown() {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.shift],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0
        ) else {
            Issue.record("failed to build synthetic NSEvent")
            return
        }
        let key = event.takoKeyEvent
        #expect(key.action == .press)
        #expect(key.text == "a")
        #expect(key.mods.contains(.shift))

        let released = event.takoKeyEvent(.release)
        #expect(released.action == .release)

        let cKey = event.takoKeyEvent(TAKO_ACTION_PRESS)
        #expect(cKey.action == TAKO_ACTION_PRESS)
    }
}

