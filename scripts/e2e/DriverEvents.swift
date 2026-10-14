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
import ApplicationServices
import Foundation

// MARK: - Keys

/// US-layout key codes, and whether the character needs Shift.
let keyCodes: [Character: (CGKeyCode, Bool)] = {
    var map: [Character: (CGKeyCode, Bool)] = [:]
    let plain: [(Character, CGKeyCode)] = [
        ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7),
        ("c", 8), ("v", 9), ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15),
        ("y", 16), ("t", 17), ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("6", 22),
        ("5", 23), ("=", 24), ("9", 25), ("7", 26), ("-", 27), ("8", 28), ("0", 29),
        ("]", 30), ("o", 31), ("u", 32), ("[", 33), ("i", 34), ("p", 35), ("l", 37),
        ("j", 38), ("'", 39), ("k", 40), (";", 41), ("\\", 42), (",", 43), ("/", 44),
        ("n", 45), ("m", 46), (".", 47), (" ", 49), ("`", 50),
    ]
    for (ch, code) in plain {
        map[ch] = (code, false)
        if ch.isLetter { map[Character(ch.uppercased())] = (code, true) }
    }
    let shifted: [(Character, Character)] = [
        ("!", "1"), ("@", "2"), ("#", "3"), ("$", "4"), ("%", "5"), ("^", "6"),
        ("&", "7"), ("*", "8"), ("(", "9"), (")", "0"), ("_", "-"), ("+", "="),
        ("{", "["), ("}", "]"), ("|", "\\"), (":", ";"), ("\"", "'"), ("<", ","),
        (">", "."), ("?", "/"), ("~", "`"),
    ]
    for (ch, base) in shifted { map[ch] = (map[base]!.0, true) }
    return map
}()

enum Key {
    static let returnKey: CGKeyCode = 36
    static let delete: CGKeyCode = 51
    static let left: CGKeyCode = 123
    static let space: CGKeyCode = 49
    static let equal: CGKeyCode = 24
    static let minus: CGKeyCode = 27
    static let zero: CGKeyCode = 29
    static let t: CGKeyCode = 17
    static let f: CGKeyCode = 3
    static let escape: CGKeyCode = 53
    static let a: CGKeyCode = 0
    static let d: CGKeyCode = 2
    static let e: CGKeyCode = 14
    static let w: CGKeyCode = 13
    static let n: CGKeyCode = 45
    static let v: CGKeyCode = 9
    static let c: CGKeyCode = 8
    static let u: CGKeyCode = 32
    static let q: CGKeyCode = 12
    static let comma: CGKeyCode = 43
    static let slash: CGKeyCode = 44
    static let grave: CGKeyCode = 50
    static let leftBracket: CGKeyCode = 33
    static let rightBracket: CGKeyCode = 30
    static let s: CGKeyCode = 1
    static let o: CGKeyCode = 31
    static let r: CGKeyCode = 15
    static let k: CGKeyCode = 40
    static let p: CGKeyCode = 35
    static let one: CGKeyCode = 18
    static let two: CGKeyCode = 19
    static let three: CGKeyCode = 20
    static let right: CGKeyCode = 124
    static let down: CGKeyCode = 125
    static let up: CGKeyCode = 126
}

// MARK: - Event Dispatch

extension Driver {
    func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            else { continue }
            event.flags = down ? flags : []
            event.postToPid(pid)
            usleep(12_000)
        }
        usleep(12_000)
    }

    func type(_ text: String) throws {
        var count = 0
        for ch in text {
            if ch == "\n" || ch == "\r" {
                usleep(30_000)
                key(Key.returnKey)
                usleep(30_000)
            } else if ch == "\t" {
                key(48)
            } else if ch == "\u{1b}" {
                key(Key.escape)
            } else {
                guard let (code, shift) = keyCodes[ch] else { throw Failure("no key for \(ch)") }
                key(code, shift ? .maskShift : [])
            }
            count += 1
            if count % 10 == 0 {
                usleep(40_000)
            }
        }
    }

    func systemKey(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            else { continue }
            event.flags = down ? flags : []
            event.post(tap: .cghidEventTap)
            usleep(25_000)
        }
        usleep(25_000)
    }

    @discardableResult
    func postKey(_ code: CGKeyCode, _ flags: CGEventFlags = []) -> Double {
        var dispatchTime: Double = 0
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            else { continue }
            event.flags = down ? flags : []
            event.post(tap: .cghidEventTap)
            if down {
                dispatchTime = ProcessInfo.processInfo.systemUptime
            }
            usleep(8_000)
        }
        return dispatchTime
    }

    func click(at point: CGPoint, count: Int = 1) throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let owner = topmostOwner(at: point), owner == pid { break }
            usleep(50_000)
        }
        guard let owner = topmostOwner(at: point), owner == pid else {
            throw Failure("click at \(point) target not owned by Tako (owner \(String(describing: topmostOwner(at: point))), pid \(pid))")
        }

        let source = CGEventSource(stateID: .combinedSessionState)
        for i in 1...count {
            guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                                     mouseCursorPosition: point, mouseButton: .left),
                  let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                                   mouseCursorPosition: point, mouseButton: .left)
            else { throw Failure("could not create mouse events") }
            down.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(i))
            down.post(tap: .cghidEventTap)
            usleep(20_000)
            up.post(tap: .cghidEventTap)
            usleep(20_000)
        }
    }

    func doubleClick(at point: CGPoint) throws {
        try click(at: point, count: 2)
    }

    func dragMouse(from start: CGPoint, to end: CGPoint, duration: Double = 0.5,
                   returnHome home: CGPoint? = nil) {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let moveStart = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                      mouseCursorPosition: start, mouseButton: .left) else { return }
        moveStart.post(tap: .cghidEventTap)
        usleep(50_000)

        guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                                 mouseCursorPosition: start, mouseButton: .left) else { return }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        down.post(tap: .cghidEventTap)
        usleep(100_000)

        let steps = max(10, Int(duration / 0.04))
        for step in 1...steps {
            let progress = CGFloat(step) / CGFloat(steps)
            let current = CGPoint(x: start.x + (end.x - start.x) * progress,
                                  y: start.y + (end.y - start.y) * progress)
            guard let move = CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged,
                                     mouseCursorPosition: current, mouseButton: .left) else { continue }
            move.post(tap: .cghidEventTap)
            usleep(35_000)
        }

        guard let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                               mouseCursorPosition: end, mouseButton: .left) else { return }
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        up.post(tap: .cghidEventTap)
        usleep(100_000)

        if let home {
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                    mouseCursorPosition: home, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
    }

    /// Perform a drag from start screen point to end screen point via real CGEvent mouse events.
    func drag(from start: CGPoint, to end: CGPoint, steps: Int = 8) throws {
        guard topmostOwner(at: start) == pid else {
            throw Failure("refusing to drag from \(start): the window there is not Tako's")
        }
        let home = CGEvent(source: nil)?.location
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                mouseCursorPosition: start, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(40_000)
        guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                                 mouseCursorPosition: start, mouseButton: .left) else { return }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        down.post(tap: .cghidEventTap)
        usleep(100_000)

        for i in 1...steps {
            let progress = CGFloat(i) / CGFloat(steps)
            let current = CGPoint(x: start.x + (end.x - start.x) * progress,
                                  y: start.y + (end.y - start.y) * progress)
            guard let move = CGEvent(mouseEventSource: source, mouseType: .leftMouseDragged,
                                     mouseCursorPosition: current, mouseButton: .left) else { continue }
            move.post(tap: .cghidEventTap)
            usleep(35_000)
        }

        guard let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                               mouseCursorPosition: end, mouseButton: .left) else { return }
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        up.post(tap: .cghidEventTap)
        usleep(100_000)

        if let home {
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                    mouseCursorPosition: home, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
    }

    func postClick(at point: CGPoint) throws -> Double {
        guard topmostOwner(at: point) == pid else {
            let winInfo = topmostWindowInfo(at: point)
            throw Failure("refusing to click at \(point): the window there is not Tako's (windows: \(winInfo))")
        }
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(10_000)
        guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                                 mouseCursorPosition: point, mouseButton: .left) else {
            throw Failure("failed to create leftMouseDown CGEvent")
        }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        down.post(tap: .cghidEventTap)
        let dispatchTime = ProcessInfo.processInfo.systemUptime

        usleep(25_000)

        guard let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                               mouseCursorPosition: point, mouseButton: .left) else {
            throw Failure("failed to create leftMouseUp CGEvent")
        }
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        up.post(tap: .cghidEventTap)
        usleep(10_000)
        return dispatchTime
    }
}
