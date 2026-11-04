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

    /// Read-only ownership and AX diagnostics; never inspect another app's content.
    func traceClick(at point: CGPoint, expected: AXUIElement?, target: AXUIElement?) {
        guard ProcessInfo.processInfo.environment["TAKO_E2E_TRACE_CLICKS"] == "1" else { return }
        func describe(_ element: AXUIElement?) -> String {
            guard let element else { return "nil" }
            var owner: pid_t = 0
            let ownerStatus = AXUIElementGetPid(element, &owner)
            guard ownerStatus == .success, owner == pid else {
                return "owner=\(owner), status=\(ownerStatus.rawValue)"
            }
            let values = [kAXRoleAttribute, "AXIdentifier", kAXPositionAttribute, kAXSizeAttribute,
                          kAXValueAttribute].map { name -> String in
                var value: CFTypeRef?
                let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
                return "\(name)=\(String(describing: value)) [\(status.rawValue)]"
            }
            return "window=\(String(describing: windowID(for: element))), " + values.joined(separator: ", ")
        }
        var hit: AXUIElement?
        let status = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),
                                                    Float(point.x), Float(point.y), &hit)
        let main: AXUIElement? = attribute(axApp, kAXMainWindowAttribute)
        let focused: AXUIElement? = attribute(axApp, kAXFocusedWindowAttribute)
        print("click diagnostic: point=\(point), cursor=\(String(describing: CGEvent(source: nil)?.location)), expected=\(String(describing: expected.flatMap { windowID(for: $0) })), main=\(String(describing: main.flatMap { windowID(for: $0) })), focused=\(String(describing: focused.flatMap { windowID(for: $0) })), topmost=\(topmostWindowInfo(at: point)), AXstatus=\(status.rawValue), target={\(describe(target))}, hit={\(describe(hit))}")
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

        try requireAXOwnedTarget(at: point)

        let source = CGEventSource(stateID: .combinedSessionState)
        for i in 1...count {
            try requireAXOwnedTarget(at: point)
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

    /// Window-list filtering misses some system overlays. Check the actual
    /// input recipient before a mouse gesture or any subsequent mouse down.
    func requireAXOwnedTarget(at point: CGPoint) throws {
        var hit: AXUIElement?
        let hitStatus = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(),
                                                       Float(point.x), Float(point.y), &hit)
        var hitOwner: pid_t = 0
        guard hitStatus == .success, let hit,
              AXUIElementGetPid(hit, &hitOwner) == .success, hitOwner == pid else {
            throw Failure("mouse target \(point) obstructed (AX status \(hitStatus.rawValue), hit owner \(hitOwner), expected \(pid)); windows: \(topmostWindowInfo(at: point))")
        }
    }

    func doubleClick(at point: CGPoint) throws {
        try click(at: point, count: 2)
    }

    func dragMouse(from start: CGPoint, to end: CGPoint, duration: Double = 0.5,
                   returnHome home: CGPoint? = nil) throws {
        try requireAXOwnedTarget(at: start)
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let moveStart = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                      mouseCursorPosition: start, mouseButton: .left) else { return }
        moveStart.post(tap: .cghidEventTap)
        usleep(50_000)

        try requireAXOwnedTarget(at: start)
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
        try requireAXOwnedTarget(at: start)
        let home = CGEvent(source: nil)?.location
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                mouseCursorPosition: start, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(40_000)
        try requireAXOwnedTarget(at: start)
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

    struct PreparedClick {
        let point: CGPoint
        let move: CGEvent
        let down: CGEvent
        let up: CGEvent
    }

    struct ClickDispatchTrace {
        let ownerStarted: Double
        let ownerChecked: Double
        let movePosted: Double
        let downPosted: Double
        let upPosted: Double
        let returned: Double
    }

    func prepareClick(at point: CGPoint) throws -> PreparedClick {
        guard let move = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                                 mouseCursorPosition: point, mouseButton: .left),
              let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                                 mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                               mouseCursorPosition: point, mouseButton: .left) else {
            throw Failure("failed to prepare mouse CGEvents")
        }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        return PreparedClick(point: point, move: move, down: down, up: up)
    }

    func postPreparedClick(
        _ click: PreparedClick, settleAfterRelease: Bool = true
    ) throws -> ClickDispatchTrace {
        let ownerStarted = ProcessInfo.processInfo.systemUptime
        guard topmostOwner(at: click.point) == pid else {
            let info = topmostWindowInfo(at: click.point)
            throw Failure("refusing to click at \(click.point): the window there is not Tako's (windows: \(info))")
        }
        try requireAXOwnedTarget(at: click.point)
        let ownerChecked = ProcessInfo.processInfo.systemUptime
        // Preparation can precede delivery by a window-server round trip.
        // Keep each event's timestamp at its real posting time.
        click.move.timestamp = DispatchTime.now().uptimeNanoseconds
        click.move.post(tap: .cghidEventTap)
        let movePosted = ProcessInfo.processInfo.systemUptime
        usleep(10_000)
        try requireAXOwnedTarget(at: click.point)
        click.down.timestamp = DispatchTime.now().uptimeNanoseconds
        click.down.post(tap: .cghidEventTap)
        let downPosted = ProcessInfo.processInfo.systemUptime
        usleep(25_000)
        click.up.timestamp = DispatchTime.now().uptimeNanoseconds
        click.up.post(tap: .cghidEventTap)
        let upPosted = ProcessInfo.processInfo.systemUptime
        if settleAfterRelease { usleep(10_000) }
        return ClickDispatchTrace(ownerStarted: ownerStarted, ownerChecked: ownerChecked,
                                  movePosted: movePosted, downPosted: downPosted, upPosted: upPosted,
                                  returned: ProcessInfo.processInfo.systemUptime)
    }

    func postClick(at point: CGPoint) throws -> Double {
        try postPreparedClick(prepareClick(at: point)).downPosted
    }
}
