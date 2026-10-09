/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

// Drives a built Tako.app the way a person does and checks what the program
// inside it actually received.
//
// Key presses are real keyboard events posted to the app's process: they go
// through the window server, AppKit's event routing, the menus' key
// equivalents and the text input system, exactly as typing does. Windows,
// tabs and alerts are read and pressed through the accessibility tree. What
// reached the shell is checked by having the shell write it to a file --
// the one witness that cannot be fooled by what the screen looks like.
//
// Events are posted to Tako's pid, never to whatever app is in front, so a
// run cannot type into another app's windows. Tako is launched the ordinary
// way, which makes it the active app -- menu key equivalents act on the key
// window, and an app in the background has none -- and the app that was in
// front is given the focus back when the run ends.
//
//   swiftc -O -o tako-e2e scripts/e2e/tako-e2e.swift
//   ./tako-e2e target/macapp/Tako.app [scenario ...]
//
// Needs Accessibility permission for the process running it, and a US-style
// keyboard layout (key codes are typed, and the layout turns them into
// characters, as it would for a person).

import AppKit
import ApplicationServices
import Foundation

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

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
    static let w: CGKeyCode = 13
    static let n: CGKeyCode = 45
    static let v: CGKeyCode = 9
    static let c: CGKeyCode = 8
    static let u: CGKeyCode = 32
    static let q: CGKeyCode = 12
    static let comma: CGKeyCode = 43
    static let grave: CGKeyCode = 50
    static let rightBracket: CGKeyCode = 30
    static let s: CGKeyCode = 1
    static let o: CGKeyCode = 31
    static let r: CGKeyCode = 15
    static let k: CGKeyCode = 40
}

// MARK: - Driver

final class Driver {
    let appURL: URL
    let work: URL
    private(set) var pid: pid_t = 0
    private let source = CGEventSource(stateID: .hidSystemState)

    init(app: URL) throws {
        appURL = app.standardizedFileURL.absoluteURL
        let resolved = Bundle(url: appURL)?.bundleIdentifier ?? "com.tako-core.terminal"
        guard resolved != "com.tako-core.terminal" else {
            throw Failure("Refusing to drive production bundle identifier com.tako-core.terminal. Build with TAKO_BUNDLE_ID=com.tako-core.terminal.e2e (or another isolated test ID) to protect operator state.")
        }
        work = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("tako-e2e-\(UUID().uuidString.prefix(8).lowercased())")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    var bundleID: String {
        Bundle(url: appURL)?.bundleIdentifier ?? "com.tako-core.terminal"
    }

    // A path the shell can be told to write to. Lowercase and short, so it
    // is quick to type and needs nothing but plain keys.
    func path(_ name: String) -> String { work.appendingPathComponent(name).path }

    /// Scenarios start from a fresh window: none restored from an earlier
    /// run, none saved for the next. The restore scenario turns it back on.
    static let defaultConfig = "window-save-state = never\nauto-update = off\nremote-control = on\n"

    /// Extra environment for the next launch.
    var environment: [String: String] = [:]

    func launch(config: String = Driver.defaultConfig) throws {
        let configURL = work.appendingPathComponent("config")
        try config.write(to: configURL, atomically: true, encoding: .utf8)
        let before = Set(running().map(\.processIdentifier))
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // -n: a new instance, never somebody's running Tako.
        // The isolated persistence profile moves the session namespace.
        var env = environment
        if let home = ProcessInfo.processInfo.environment["TAKO_SESSIONS_HOME"] { env["TAKO_SESSIONS_HOME"] = home }
        env["TAKO_NO_UPDATE"] = "1"
        env["TAKO_NO_LAUNCH_NOTICES"] = "1"
        open.arguments = ["-n", "--env", "TAKO_CONFIG_PATH=\(configURL.path)"]
            + env.flatMap { ["--env", "\($0.key)=\($0.value)"] }
            + [appURL.path, "--args", "--no-update", "--no-launch-notices"]
        try open.run()
        open.waitUntilExit()
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let app = running().first(where: { !before.contains($0.processIdentifier) }) {
                pid = app.processIdentifier
                break
            }
            usleep(100_000)
        }
        guard pid != 0 else { throw Failure("Tako did not start") }
        guard wait(for: { !self.windows().isEmpty }, timeout: 15) else {
            throw Failure("Tako started but opened no window")
        }
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
        }
        if let window = self.windows().first {
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        try run("true")
        usleep(300_000)
    }

    func activate() {
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
        }
        if let window = self.windows().first {
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        usleep(100_000)
    }

    func quit() {
        guard pid != 0 else { return }
        let dying = pid
        kill(dying, SIGKILL)
        _ = wait(for: { NSRunningApplication(processIdentifier: dying) == nil }, timeout: 5)
        pid = 0
    }

    /// Starts a second instance of the app beside the one being driven
    /// (which stays `pid`), and returns its pid.
    func launchAnother(config: String) throws -> pid_t {
        let configURL = work.appendingPathComponent("config-another")
        try config.write(to: configURL, atomically: true, encoding: .utf8)
        let before = Set(running().map(\.processIdentifier))
        var env = environment
        if let home = ProcessInfo.processInfo.environment["TAKO_SESSIONS_HOME"] { env["TAKO_SESSIONS_HOME"] = home }
        env["TAKO_NO_UPDATE"] = "1"
        env["TAKO_NO_LAUNCH_NOTICES"] = "1"
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-n", "-g", "--env", "TAKO_CONFIG_PATH=\(configURL.path)"]
            + env.flatMap { ["--env", "\($0.key)=\($0.value)"] }
            + [appURL.path, "--args", "--no-update", "--no-launch-notices"]
        try open.run()
        open.waitUntilExit()
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let app = running().first(where: { !before.contains($0.processIdentifier) }) {
                return app.processIdentifier
            }
            usleep(100_000)
        }
        throw Failure("the second instance did not start")
    }

    /// Every terminal's text in another instance's windows.
    func screenTexts(ofPid other: pid_t) -> [String] {
        let app = AXUIElementCreateApplication(other)
        let windows = (attribute(app, kAXWindowsAttribute) as [AXUIElement]?) ?? []
        return windows.flatMap { descendants(of: $0, role: kAXTextAreaRole as String) }
            .compactMap { attribute($0, kAXValueAttribute) as String? }
    }

    func pressMenuItem(titledPrefix prefix: String) -> Bool {
        for item in descendants(of: axApp, role: kAXMenuItemRole as String) {
            let title: String? = attribute(item, kAXTitleAttribute)
            if title?.starts(with: prefix) == true {
                return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
            }
        }
        return false
    }

    func pressQuitMenuItem() -> Bool {
        pressMenuItem(titledPrefix: "Quit")
    }

    func closeTab() {
        key(Key.w, .maskCommand)
    }

    func newTab() {
        key(Key.t, .maskCommand)
    }


    func interrupt() {
        key(Key.c, .maskControl)
        try? type("\u{03}")
    }

    /// Cmd+Q, the way a person quits: the app saves its windows and tabs.
    func quitNormally() throws {
        guard pid != 0 else { return }
        let quitting = pid
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-a", appURL.path]
        try? open.run()
        open.waitUntilExit()
        _ = wait(for: { NSWorkspace.shared.frontmostApplication?.processIdentifier == quitting }, timeout: 2)

        key(Key.q, .maskCommand)
        if wait(for: { NSRunningApplication(processIdentifier: quitting) == nil }, timeout: 3) {
            pid = 0
            return
        }
        _ = pressQuitMenuItem()
        guard wait(for: { NSRunningApplication(processIdentifier: quitting) == nil }, timeout: 15) else {
            let texts = staticTexts()
            let screen = screenText()
            throw Failure("Cmd+Q did not quit Tako. StaticTexts: \(texts), Screen: [\(screen.suffix(300))]")
        }
        pid = 0
    }

    /// Every static text in the front window, through accessibility.
    func staticTexts() -> [String] {
        guard let window = windows().first else { return [] }
        return descendants(of: window, role: kAXStaticTextRole as String).compactMap {
            attribute($0, kAXValueAttribute) as String?
        }
    }

    /// The front window's text fields' values.
    func textFields() -> [String] {
        guard let window = windows().first else { return [] }
        return descendants(of: window, role: kAXTextFieldRole as String).compactMap {
            attribute($0, kAXValueAttribute) as String?
        }
    }

    /// The terminal's selected text, through accessibility.
    func selectedText() -> String {
        guard let window = windows().first,
              let area = descendants(of: window, role: kAXTextAreaRole as String).first,
              let text: String = attribute(area, kAXSelectedTextAttribute)
        else { return "" }
        return text
    }

    /// What the terminal shows, as its accessibility value: the screen and
    /// scrollback.
    func screenText() -> String {
        guard let window = windows().first,
              let area = descendants(of: window, role: kAXTextAreaRole as String).first,
              let text: String = attribute(area, kAXValueAttribute)
        else { return "" }
        return text
    }

    private func running() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.executableURL?.path.hasPrefix(appURL.path) == true
        }
    }

    // MARK: typing

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
            guard let (code, shift) = keyCodes[ch] else { throw Failure("no key for \(ch)") }
            key(code, shift ? .maskShift : [])
            count += 1
            if count % 10 == 0 {
                usleep(40_000)
            }
        }
    }

    /// Type a command line and press Return.
    func run(_ command: String) throws {
        try type(command)
        usleep(20_000)
        key(Key.returnKey)
    }

    /// Run a command via host process outside the driven terminal.
    @discardableResult
    func exec(_ command: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: witnesses

    func wait(for condition: () -> Bool, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(100_000)
        }
        return condition()
    }

    /// The file's contents once the shell has written them.
    func file(_ name: String, timeout: TimeInterval = 10) throws -> String {
        let url = work.appendingPathComponent(name)
        var text: String?
        _ = wait(for: {
            text = try? String(contentsOf: url, encoding: .utf8)
            return text != nil
        }, timeout: timeout)
        // Written by a redirect, the file exists a moment before its contents.
        usleep(150_000)
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            throw Failure("the shell never wrote \(name): what was typed did not reach it. Screen: [\(screenText().suffix(500))]")
        }
        _ = text
        return contents
    }

    func expect(_ name: String, _ expected: String, _ what: String) throws {
        let got = try file(name)
        guard got == expected else {
            throw Failure("\(what): expected \(hex(expected)), got \(hex(got))")
        }
    }

    // MARK: accessibility

    private var axApp: AXUIElement { AXUIElementCreateApplication(pid) }

    func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    func windows() -> [AXUIElement] {
        (attribute(axApp, kAXWindowsAttribute) as [AXUIElement]?) ?? []
    }

    /// Every element under `root` whose role is `role`.
    func descendants(of root: AXUIElement, role: String, depth: Int = 12) -> [AXUIElement] {
        guard depth > 0 else { return [] }
        var found: [AXUIElement] = []
        for child in (attribute(root, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
            if (attribute(child, kAXRoleAttribute) as String?) == role { found.append(child) }
            found += descendants(of: child, role: role, depth: depth - 1)
        }
        return found
    }

    /// Tabs in the frontmost Tako window: native window tabs are a tab group
    /// of radio buttons, and a single tab has no tab bar at all.
    func tabCount() -> Int {
        guard let window = windows().first else { return 0 }
        let groups = descendants(of: window, role: kAXTabGroupRole as String)
        let tabs = groups.flatMap { descendants(of: $0, role: kAXRadioButtonRole as String, depth: 2) }
        return max(tabs.count, 1)
    }

    func press(_ element: AXUIElement) {
        AXUIElementPerformAction(element, kAXPressAction as CFString)
    }

    /// A button with this title anywhere in Tako's windows or sheets.
    func button(titled title: String) -> AXUIElement? {
        for window in windows() {
            for btn in descendants(of: window, role: kAXButtonRole as String) {
                let axTitle: String? = attribute(btn, kAXTitleAttribute)
                let axDesc: String? = attribute(btn, kAXDescriptionAttribute)
                let axLabel: String? = attribute(btn, "AXLabel")
                if axTitle == title || axDesc == title || axLabel == title ||
                   axTitle?.contains(title) == true || axDesc?.contains(title) == true || axLabel?.contains(title) == true {
                    return btn
                }
            }
        }
        return nil
    }

    /// Whether any UI element across the app's windows contains this text.
    func hasText(containing target: String) -> Bool {
        for window in windows() {
            if elementContainsText(window, target: target, depth: 14) { return true }
        }
        return false
    }

    private func elementContainsText(_ element: AXUIElement, target: String, depth: Int) -> Bool {
        let val: String? = attribute(element, kAXValueAttribute)
        let title: String? = attribute(element, kAXTitleAttribute)
        let desc: String? = attribute(element, kAXDescriptionAttribute)
        let label: String? = attribute(element, "AXLabel")
        if val?.contains(target) == true || title?.contains(target) == true ||
           desc?.contains(target) == true || label?.contains(target) == true {
            return true
        }
        guard depth > 0 else { return false }
        for child in (attribute(element, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
            if elementContainsText(child, target: target, depth: depth - 1) { return true }
        }
        return false
    }

    var isRunning: Bool {
        pid != 0 && NSRunningApplication(processIdentifier: pid)?.isTerminated == false
    }

    /// The terminal view's frame in screen coordinates (top-left origin,
    /// the space mouse events use).
    func terminalFrame() -> CGRect? {
        guard let window = windows().first,
              let area = descendants(of: window, role: kAXTextAreaRole as String).first,
              let position: AXValue = attribute(area, kAXPositionAttribute),
              let size: AXValue = attribute(area, kAXSizeAttribute)
        else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position, .cgPoint, &origin)
        AXValueGetValue(size, .cgSize, &extent)
        return CGRect(origin: origin, size: extent)
    }

    /// A click (or double-click, with `count` 2) at a screen point.
    ///
    /// AppKit ignores mouse events posted to a process, so these go through
    /// the window server like a real click -- and so only when the topmost
    /// window at that point is Tako's: a click that could land in someone
    /// else's window is refused, not sent. The pointer is put back afterwards.
    func click(at point: CGPoint, count: Int = 1) throws {
        guard topmostOwner(at: point) == pid else {
            throw Failure("refusing to click at \(point): the window there is not Tako's")
        }
        let home = CGEvent(source: nil)?.location
        for n in 1...count {
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                guard let event = CGEvent(mouseEventSource: source, mouseType: type,
                                          mouseCursorPosition: point, mouseButton: .left)
                else { continue }
                event.setIntegerValueField(.mouseEventClickState, value: Int64(n))
                event.post(tap: .cghidEventTap)
                usleep(20_000)
            }
        }
        if let home {
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                    mouseCursorPosition: home, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
    }

    /// Which process owns the frontmost ordinary window at a screen point.
    func topmostOwner(at point: CGPoint) -> pid_t? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        // Front to back; layer 0 is ordinary windows (menus and the Dock sit
        // above and never overlap a terminal's contents).
        for info in list where (info[kCGWindowLayer as String] as? Int) == 0 {
            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let rect = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                              width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            if rect.contains(point) { return info[kCGWindowOwnerPID as String] as? pid_t }
        }
        return nil
    }

    func menuItemEnabled(_ title: String) -> Bool? {
        guard let bar: AXUIElement = attribute(axApp, kAXMenuBarAttribute) else { return nil }
        for top in (attribute(bar, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
            for menu in (attribute(top, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                for item in (attribute(menu, kAXChildrenAttribute) as [AXUIElement]?) ?? []
                where (attribute(item, kAXTitleAttribute) as String?) == title {
                    return attribute(item, kAXEnabledAttribute)
                }
            }
        }
        return nil
    }

    func focus() {
        guard let window = windows().first else { return }
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if let area = descendants(of: window, role: kAXTextAreaRole as String).first {
            AXUIElementSetAttributeValue(area, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
    }

    func setSize(_ size: CGSize) {
        guard let window = windows().first else { return }
        var value = size
        if let axValue = AXValueCreate(.cgSize, &value) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, axValue)
        }
        usleep(100_000)
    }


    func setPosition(_ position: CGPoint) {
        guard let window = windows().first else { return }
        var value = position
        if let axValue = AXValueCreate(.cgPoint, &value) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, axValue)
        }
        usleep(100_000)
        focus()
    }
}

func hex(_ s: String) -> String {
    "\"\(s)\" [" + s.utf8.map { String(format: "%02x", $0) }.joined(separator: " ") + "]"
}

// MARK: - Scenarios

typealias Scenario = (name: String, why: String, body: (Driver) throws -> Void)

let scenarios: [Scenario] = [
    ("restore", "a relaunch shows the tab's old screen and starts its shell where it was", { d in
        d.quit()
        // Every scenario ends with a kill, which the layout journal rightly
        // treats as a crash: start from nothing an earlier scenario left.
        forgetLayout(d)
        try d.launch(config: "")
        // A marker and a directory of this run only, so a screen restored
        // from an earlier run cannot pass for this one. The output, not the
        // command line, holds the marker; any shell's printf makes it.
        let id = d.work.lastPathComponent
        let marker = "restore-\(id)"
        let dir = d.path("cwd")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // Right after launch the shell can still be starting and drop what is
        // typed; the command is harmless to repeat, so repeat it until it shows.
        var shown = false
        for _ in 0..<3 where !shown {
            try d.run("cd \(dir); printf 'restore-%s\\n' \(id)")
            shown = d.wait(for: { d.screenText().contains(marker) }, timeout: 5)
        }
        guard shown else {
            throw Failure("the marker never showed: [\(d.screenText().suffix(300))]")
        }
        try d.quitNormally()
        try d.launch(config: "")
        let screen = d.screenText()
        guard screen.contains(marker), !screen.contains("restored from")
        else { throw Failure("this run's screen was not restored as it was: [\(screen)]") }
        try d.run("pwd -P > \(d.path("pwd"))")
        // pwd -P resolves /tmp to /private/tmp; Foundation's resolving keeps
        // /tmp, so ask the C library.
        guard let real = realpath(dir, nil) else { throw Failure("no real path for \(dir)") }
        let resolved = String(cString: real)
        free(real)
        try d.expect("pwd", resolved + "\n", "the restored shell's directory")
    }),
    ("typing", "what is typed reaches the shell, two spaces as two spaces", { d in
        try d.run("printf '%s' 'a  b' > \(d.path("typed"))")
        try d.expect("typed", "a  b", "typed text")
    }),
    ("option-space", "Option+Space types a plain space, not a no-break space", { d in
        try d.type("printf '%s' 'x")
        d.key(Key.space, .maskAlternate)
        try d.run("y' > \(d.path("optspace"))")
        try d.expect("optspace", "x y", "Option+Space")
    }),
    ("editing", "arrow keys and backspace edit the line the shell holds", { d in
        try d.type("echo ac > \(d.path("arrows"))")
        // Back over " > <path>" and the "c", then insert.
        for _ in 0..<(" > \(d.path("arrows"))".count + 1) { d.key(Key.left) }
        try d.type("b")
        d.key(Key.returnKey)
        try d.expect("arrows", "abc\n", "left arrow then typing")

        try d.type("echo abx")
        d.key(Key.delete)
        try d.run("c > \(d.path("backspace"))")
        try d.expect("backspace", "abc\n", "backspace")
    }),
    ("control-keys", "ctrl+u clears the line and ctrl+c stops a running command", { d in
        try d.type("echo wrong")
        d.key(Key.u, .maskControl)
        try d.run("echo right > \(d.path("ctrlu"))")
        try d.expect("ctrlu", "right\n", "ctrl+u")

        try d.run("sleep 30; echo late > \(d.path("late"))")
        usleep(800_000)
        d.key(Key.c, .maskControl)
        try d.run("echo after > \(d.path("after"))")
        _ = try d.file("after", timeout: 5)
        guard !FileManager.default.fileExists(atPath: d.path("late")) else {
            throw Failure("ctrl+c did not stop the command")
        }
    }),
    ("find-all", "cmd+shift+f finds output in another tab and shows it there, selected", { d in
        let id = d.work.lastPathComponent
        try d.run("tty > \(d.path("tty1")); printf 'found-%s\\n' \(id)")
        let first = try d.file("tty1")
        d.key(Key.t, .maskCommand)
        usleep(1_200_000)
        try d.run("tty > \(d.path("tty2")); printf 'other output\\n'")
        guard try d.file("tty2") != first else { throw Failure("cmd+t did not open a second terminal") }

        d.key(Key.f, [.maskCommand, .maskShift])
        usleep(600_000)
        try d.type("found-\(id)")
        usleep(800_000)
        d.key(Key.returnKey)
        usleep(1_000_000)

        guard d.wait(for: { d.selectedText() == "found-\(id)" }, timeout: 5) else {
            throw Failure("selection after Return is [\(d.selectedText())]")
        }
        try d.run("tty > \(d.path("tty3"))")
        guard try d.file("tty3") == first else {
            throw Failure("Return did not bring the keyboard to the tab with the match")
        }
    }),
    ("find-commands", "find in all tabs groups matches under the shell command that printed them", { d in
        // The bundled zsh integration, whatever the login shell is: it marks
        // the prompt, the command line, the output and the exit status.
        let id = d.work.lastPathComponent
        let marker = "grp-\(id)"
        try d.run("exec env ZDOTDIR=$TAKO_RESOURCES_DIR/shell-integration/zsh zsh -i")
        usleep(2_000_000)
        try d.run("cd \(d.work.path)")
        // The id is passed apart from the format, so no command line holds
        // the marker: only output does.
        try d.run("printf 'grp-%s ok\\n' \(id)")
        try d.run("printf 'grp-%s one\\ngrp-%s two\\n' \(id) \(id); false")
        guard d.wait(for: { d.screenText().contains("\(marker) two") }, timeout: 5) else {
            throw Failure("the commands did not run: [\(d.screenText().suffix(300))]")
        }

        d.key(Key.f, [.maskCommand, .maskShift])
        usleep(600_000)
        d.key(Key.a, .maskCommand)
        try d.type(marker)
        guard d.wait(for: { d.staticTexts().filter { $0.contains(marker) }.count == 3 }, timeout: 5) else {
            throw Failure("expected three matches: \(d.staticTexts())")
        }
        let texts = d.staticTexts()
        let failing = "$ printf 'grp-%s one\\ngrp-%s two\\n' \(id) \(id); false"
        let passing = "$ printf 'grp-%s ok\\n' \(id)"
        // One heading per command, however many of its lines matched.
        guard texts.filter({ $0 == failing }).count == 1, texts.filter({ $0 == passing }).count == 1 else {
            throw Failure("headings: \(texts)")
        }
        let details = texts.filter { $0.contains("exit") }
        let dir = d.work.resolvingSymlinksInPath().path
        guard details.count == 2,
              details.contains(where: { $0.hasPrefix("✗ exit 1") }),
              details.contains(where: { $0.hasPrefix("✓ exit 0") }),
              details.allSatisfy({ $0.contains(dir) || $0.contains(d.work.path) }),
              details.allSatisfy({ $0.contains("started ") }) else {
            throw Failure("details: \(details)")
        }
        // Newest first: the failing command's lines come before the other's.
        guard let fi = texts.firstIndex(of: failing), let pi = texts.firstIndex(of: passing), fi < pi else {
            throw Failure("order: \(texts)")
        }

        d.key(Key.returnKey)
        guard d.wait(for: { d.selectedText() == marker }, timeout: 5) else {
            throw Failure("selection after Return is [\(d.selectedText())]")
        }
        try d.run("exit")
    }),
    ("ctl-tree", "takoctl inside a pane sees that pane, and refuses what it must", { d in
        d.quit()
        try d.launch(config: "window-save-state = never\nauto-update = off\nremote-control = local\n")
        // On PATH through the shell integration's `path` feature.
        try d.run("takoctl tree --json > \(d.path("tree")); echo $TAKO_SURFACE_ID > \(d.path("self")); cd \(d.work.path)")
        let tree = try d.file("tree")
        let me = try d.file("self").trimmingCharacters(in: .whitespacesAndNewlines)
        guard me.count == 36, tree.contains("\"id\":\"\(me)\""), tree.contains("\"ok\":true") else {
            throw Failure("tree does not list this pane \(me): \(tree.prefix(400))")
        }
        // Without the pane context, the default setting refuses.
        try d.run("sh -c 'env -u TAKO_SURFACE_ID takoctl version 2> \(d.path("err")); echo $? > \(d.path("rc"))'")
        guard try d.file("rc").trimmingCharacters(in: .whitespacesAndNewlines) == "1",
              try d.file("err").contains("disabled") else {
            throw Failure("a request from outside a pane was not refused: \(try d.file("err"))")
        }
        try d.run("takoctl version > \(d.path("ver"))")
        guard try d.file("ver").contains("protocol 1") else { throw Failure("version: \(try d.file("ver"))") }
    }),
    ("ctl-quick", "takoctl works from the Quick Terminal, which tree lists", { d in
        d.key(Key.grave, [.maskCommand, .maskShift])
        usleep(1_500_000)
        try d.run("takoctl tree --json > \(d.path("qtree")); echo $TAKO_SURFACE_ID > \(d.path("qself"))")
        let tree = try d.file("qtree")
        let me = try d.file("qself").trimmingCharacters(in: .whitespacesAndNewlines)
        d.key(Key.grave, [.maskCommand, .maskShift])
        guard tree.contains("\"ok\":true"), tree.contains("quick-terminal"), tree.contains("\"id\":\"\(me)\"") else {
            throw Failure("from the Quick Terminal \(me): \(tree.prefix(500))")
        }
    }),
    ("ctl-layout", "takoctl splits, types, reads, retitles, opens a tab behind and closes with the user's answer", { d in
        let id = d.work.lastPathComponent
        let out = d.work.path
        // Each phase is a small sh script run in the pane, so fish and zsh
        // alike run it; results go to files the driver reads.
        func script(_ name: String, _ body: String) throws {
            try body.write(toFile: d.path(name), atomically: true, encoding: .utf8)
        }
        try script("setup.sh", """
        me=$TAKO_SURFACE_ID
        b=$(takoctl split right) || exit 1
        echo "$b" > \(out)/b
        takoctl type "echo split-\(id)" --target "$b"
        sleep 0.5
        takoctl text --target "$b" --lines 3 > \(out)/typed
        takoctl key enter --target "$b"
        sleep 1
        takoctl text --target "$b" --lines 5 > \(out)/ran
        takoctl title "ctl-\(id)" --target "$b" && echo ok > \(out)/titled
        takoctl tree --json > \(out)/before
        takoctl tab-new --no-select --target "$me" > \(out)/f
        sleep 1
        takoctl tree --json > \(out)/after
        takoctl send "sleep 300" --target "$b"
        takoctl focus --target "$me"
        sleep 0.5
        takoctl tree --json > \(out)/refocused
        echo "$me" > \(out)/me
        echo done > \(out)/setup
        """)
        try d.run("sh \(d.path("setup.sh"))")
        _ = try d.file("setup", timeout: 20)
        let b = try d.file("b").trimmingCharacters(in: .whitespacesAndNewlines)
        guard b.count == 36 else { throw Failure("split gave no pane id: \(b)") }
        // type: the text is on the line, not yet run; key enter: it ran.
        let typed = try d.file("typed"), ran = try d.file("ran")
        guard typed.contains("echo split-\(id)"), !typed.contains("\nsplit-\(id)"),
              ran.contains("\nsplit-\(id)") else {
            throw Failure("type/key/text: typed=\(typed) ran=\(ran)")
        }
        guard try d.file("titled").contains("ok") else { throw Failure("title failed") }
        // tab-new --no-select: a new pane, and the focused pane did not change.
        let before = try d.file("before"), after = try d.file("after")
        let f = try d.file("f").trimmingCharacters(in: .whitespacesAndNewlines)
        guard f.count == 36, after.contains(f), !before.contains(f) else {
            throw Failure("tab-new: \(f) not in tree")
        }
        // The pane object whose "focused" is true: parsed, not pattern-matched.
        func focusedID(_ json: String) -> String? {
            guard let data = json.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let windows = (root["result"] as? [String: Any])?["windows"] as? [[String: Any]] else { return nil }
            for window in windows {
                for tab in window["tabs"] as? [[String: Any]] ?? [] {
                    for pane in tab["panes"] as? [[String: Any]] ?? [] where pane["focused"] as? Bool == true {
                        return pane["id"] as? String
                    }
                }
            }
            return nil
        }
        guard let fb = focusedID(before), focusedID(after) == fb else {
            throw Failure("--no-select moved the focus: \(focusedID(before) ?? "-") -> \(focusedID(after) ?? "-")")
        }
        // focus: the keyboard is back in this pane.
        let me = try d.file("me").trimmingCharacters(in: .whitespacesAndNewlines)
        guard focusedID(try d.file("refocused")) == me else {
            throw Failure("focus did not return to \(me); focused \(focusedID(try d.file("refocused")) ?? "-"), b \(b), f \(f): \(try d.file("refocused"))")
        }
        // close a pane with a running process: the question; Escape = cancelled.
        try script("close1.sh", "takoctl close --target \(b) > \(out)/close1; echo $? > \(out)/close1.rc")
        try d.run("sh \(d.path("close1.sh")) &")
        usleep(1_500_000)
        d.key(Key.escape)
        _ = try d.file("close1.rc", timeout: 10)   // written after the answer
        guard try d.file("close1").contains("cancelled") else {
            throw Failure("Cancel was not reported: \(try d.file("close1"))")
        }
        // Again, and Return = closed.
        try script("close2.sh", "takoctl close --target \(b) > \(out)/close2; echo $? > \(out)/close2.rc")
        try d.run("sh \(d.path("close2.sh")) &")
        usleep(1_500_000)
        d.key(Key.returnKey)
        _ = try d.file("close2.rc", timeout: 10)   // written after the answer
        guard try d.file("close2").contains("closed") else {
            throw Failure("closing was not reported: \(try d.file("close2"))")
        }
        // The pane is gone: notFound, exit 1, nothing else closed.
        try d.run("sh -c 'takoctl close --target \(b) 2> \(out)/close3; echo $? > \(out)/close3.rc'")
        guard try d.file("close3.rc").trimmingCharacters(in: .whitespacesAndNewlines) == "1",
              try d.file("close3").contains("notFound") else {
            throw Failure("closing a gone pane: \(try d.file("close3"))")
        }
    }),
    ("ctl-close-wait", "a close nobody answers is withdrawn and reported cancelled; a late Return closes nothing", { d in
        d.quit()
        d.environment = ["TAKO_CLOSE_WAIT": "3"]
        defer { d.environment = [:] }
        try d.launch()
        let out = d.work.path
        try """
        b=$(takoctl split right) || exit 1
        echo "$b" > \(out)/b
        takoctl send "sleep 300" --target "$b"
        sleep 1
        takoctl close --target "$b" > \(out)/c
        takoctl focus --target "$TAKO_SURFACE_ID"
        echo $? > \(out)/c.rc
        """.write(toFile: d.path("cw.sh"), atomically: true, encoding: .utf8)
        try d.run("sh \(d.path("cw.sh"))")
        _ = try d.file("c.rc", timeout: 15)
        guard try d.file("c").contains("cancelled") else { throw Failure("answer: \(try d.file("c"))") }
        // The question is gone: Return now must not close the pane.
        d.key(Key.returnKey)
        usleep(1_000_000)
        let b = try d.file("b").trimmingCharacters(in: .whitespacesAndNewlines)
        try d.run("takoctl tree --json > \(d.path("tree"))")
        guard try d.file("tree").contains(b) else { throw Failure("a late Return closed \(b)") }
    }),
    ("crash-layout", "tabs and splits made shortly before a crash come back after it", { d in
        // What this saves must not reach the scenarios after it.
        defer { d.quit(); forgetLayout(d) }
        d.quit()
        forgetLayout(d)
        let config = "window-save-state = always\n"
        try d.launch(config: config)
        let out = d.work.path
        try """
        b=$(takoctl split right) || exit 1
        f=$(takoctl tab-new --no-select) || exit 1
        takoctl tree --json > \(out)/before
        echo done > \(out)/made
        """.write(toFile: d.path("make.sh"), atomically: true, encoding: .utf8)
        try d.run("sh \(d.path("make.sh"))")
        _ = try d.file("made", timeout: 15)
        func count(_ json: String) -> (tabs: Int, panes: Int) {
            guard let data = json.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let windows = (root["result"] as? [String: Any])?["windows"] as? [[String: Any]] else { return (0, 0) }
            let tabs = windows.flatMap { $0["tabs"] as? [[String: Any]] ?? [] }
            return (tabs.count, tabs.reduce(0) { $0 + (($1["panes"] as? [Any])?.count ?? 0) })
        }
        let before = count(try d.file("before"))
        guard before.tabs >= 2, before.panes >= 3 else { throw Failure("layout not made: \(before)") }
        usleep(UInt32(ProcessInfo.processInfo.environment["TAKO_E2E_CRASH_WAIT"].flatMap(Double.init).map { $0 * 1_000_000 } ?? 3_000_000))
        d.quit()                          // SIGKILL: a crash, nothing saved on the way out
        usleep(1_000_000)
        try d.launch(config: config)
        usleep(1_500_000)
        try d.run("takoctl tree --json > \(d.path("after"))")
        let after = count(try d.file("after"))
        guard after.tabs >= before.tabs, after.panes >= before.panes else {
            throw Failure("after the crash: \(after.tabs) tabs, \(after.panes) panes; before: \(before.tabs), \(before.panes)")
        }
    }),
    ("crash-again", "a crash while restoring after a crash still restores the layout", { d in
        // What this saves must not reach the scenarios after it.
        defer { d.quit(); forgetLayout(d) }
        try crashLayoutSetup(d)
        d.quit()
        try d.launch(config: "window-save-state = always\n")
        d.quit()                          // a second crash, straight after the restore began
        usleep(500_000)
        try d.launch(config: "window-save-state = always\n")
        usleep(1_500_000)
        let after = try crashLayoutCount(d, "after")
        guard after.tabs >= 2, after.panes >= 3 else { throw Failure("after two crashes: \(after)") }
    }),
    ("crash-corrupt", "a damaged journal restores nothing from itself and duplicates nothing", { d in
        // What this saves must not reach the scenarios after it.
        defer { d.quit(); forgetLayout(d) }
        try crashLayoutSetup(d)
        d.quit()
        let bundle = Bundle(url: d.appURL)?.bundleIdentifier ?? "com.tako-core.terminal"
        let layout = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundle).appendingPathComponent("layout")
        // Every journal generation damaged: whichever launch.json names.
        for name in try FileManager.default.contentsOfDirectory(atPath: layout.path) where name.hasPrefix("journal-") {
            try Data("{\"version\":1,\"generation\":9,\"windows\":[{\"tabs\":".utf8)
                .write(to: layout.appendingPathComponent(name))
        }
        try d.launch(config: "window-save-state = always\n")
        usleep(1_500_000)
        let after = try crashLayoutCount(d, "after")
        // One fresh window: none of the journal's, and no second copy from AppKit.
        guard after.windows == 1, after.tabs == 1, after.panes == 1 else { throw Failure("after a damaged journal: \(after)") }
    }),
    ("quit-layout", "a normal quit restores the layout once, without duplicates", { d in
        // What this saves must not reach the scenarios after it.
        defer { d.quit(); forgetLayout(d) }
        try crashLayoutSetup(d)
        try d.quitNormally()
        try d.launch(config: "window-save-state = always\n")
        usleep(1_500_000)
        let after = try crashLayoutCount(d, "after")
        guard after.tabs == 2, after.panes == 3 else { throw Failure("after a normal quit: \(after)") }
    }),
    ("upgrade-crash", "a layout AppKit saved survives a crash right after the first launch that keeps a journal", { d in
        defer { d.quit(); forgetLayout(d) }
        try crashLayoutSetup(d)
        try d.quitNormally()
        // As before the journal existed: only AppKit's saved state.
        let bundle = Bundle(url: d.appURL)?.bundleIdentifier ?? "com.tako-core.terminal"
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(at: library.appendingPathComponent("Application Support/\(bundle)/layout"))
        try d.launch(config: "window-save-state = always\n")
        d.quit()                          // straight after AppKit restored, before any timer
        usleep(500_000)
        try d.launch(config: "window-save-state = always\n")
        usleep(1_500_000)
        let after = try crashLayoutCount(d, "after")
        guard after.tabs == 2, after.panes == 3 else { throw Failure("after the upgrade crash: \(after)") }
    }),
    ("persist-live", "with session-persistence a relaunch reattaches to the same shell", { d in
        // Needs an app built with its session runtime (TAKO_WITH_ZMX=1).
        d.quit()
        let config = "session-persistence = true\n"
        try d.launch(config: config)
        try d.run("sh -c 'echo $PPID' > \(d.path("pid1")); env | grep -c ZMX_SESSION > \(d.path("zs"))")
        let first = try d.file("pid1")
        guard try d.file("zs").trimmingCharacters(in: .whitespacesAndNewlines) == "1" else {
            throw Failure("the shell is not inside a session")
        }
        try d.quitNormally()
        try d.launch(config: config)
        try d.run("sh -c 'echo $PPID' > \(d.path("pid2"))")
        let second = try d.file("pid2")
        // End the session so nothing is left running.
        try d.run("exit")
        guard first == second else { throw Failure("a new shell after relaunch: \(first) then \(second)") }
    }),
    ("persist-gone", "a session that ended while Tako was closed comes back as its saved screen and a new shell", { d in
        d.quit()
        let config = "session-persistence = true\n"
        try d.launch(config: config)
        let id = d.work.lastPathComponent
        try d.run("sh -c 'echo $PPID' > \(d.path("pid1")); printf 'gone-%s\\n' \(id)")
        guard let first = try? d.file("pid1") else { throw Failure("no shell: [\(d.screenText().suffix(400))]") }
        guard d.wait(for: { d.screenText().contains("gone-\(id)") }, timeout: 5) else { throw Failure("no marker") }
        // A real save before quitting, so the snapshot holds the marker.
        try d.quitNormally()
        // End the shell behind Tako's back, the way a reboot would.
        let shell = Int32(first.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        guard shell > 0, kill(shell, SIGKILL) == 0 else { throw Failure("could not end the shell \(first)") }
        usleep(1_000_000)
        try d.launch(config: config)
        guard d.wait(for: { d.screenText().contains("gone-\(id)") }, timeout: 10) else {
            throw Failure("the saved screen did not come back: [\(d.screenText().suffix(300))]")
        }
        try d.run("sh -c 'echo $PPID' > \(d.path("pid2"))")
        let second = try d.file("pid2")
        try d.run("exit")
        guard first != second else { throw Failure("the same shell after it was killed?") }
        guard !d.screenText().contains("[Tako]") else { throw Failure("an error was shown: \(d.screenText().suffix(300))") }
    }),
    ("persist-close", "closing a persistent tab ends its session once undo has expired", { d in
        d.quit()
        let config = "session-persistence = true\nconfirm-close-surface = false\n"
        try d.launch(config: config)
        try d.run("sh -c 'echo $PPID' > \(d.path("pid1"))")
        guard let kept = Int32(try d.file("pid1").trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw Failure("no shell pid")
        }
        d.newTab()
        usleep(1_200_000)
        try d.run("sh -c 'echo $PPID' > \(d.path("pid2"))")
        guard let shell = Int32(try d.file("pid2").trimmingCharacters(in: .whitespacesAndNewlines)),
              shell != kept else {
            throw Failure("no second shell")
        }
        d.closeTab()
        // Undo keeps a closed tab for 5 s; then it is released and its
        // session ends with it.
        guard d.wait(for: { kill(shell, 0) != 0 }, timeout: 15) else {
            throw Failure("the shell \(shell) of the closed tab is still running")
        }
        guard kill(kept, 0) == 0 else { throw Failure("the open tab's session was killed") }
    }),
    ("persist-close-asks", "closing a persistent tab asks first, and Cancel keeps its session", { d in
        d.quit()
        try d.launch(config: "session-persistence = true\n")
        try d.run("sh -c 'echo $PPID' > \(d.path("pid1"))")
        guard let kept = Int32(try d.file("pid1").trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw Failure("no shell pid")
        }
        d.newTab()
        usleep(1_200_000)
        try d.run("sh -c 'echo $PPID' > \(d.path("pid2"))")
        guard let shell = Int32(try d.file("pid2").trimmingCharacters(in: .whitespacesAndNewlines)),
              shell != kept else {
            throw Failure("no second shell")
        }
        d.closeTab()
        var cancel: AXUIElement?
        guard d.wait(for: { cancel = d.button(titled: "Cancel"); return cancel != nil }, timeout: 5),
              let cancel else {
            throw Failure("cmd+w on persistent tab did not show confirmation dialog with Cancel button")
        }
        d.press(cancel)
        guard d.wait(for: { d.button(titled: "Cancel") == nil }, timeout: 5) else {
            throw Failure("confirmation dialog remained open after Cancel")
        }
        usleep(7_000_000)          // past the undo window
        guard kill(shell, 0) == 0 else { throw Failure("closing ended the session without asking") }
        try d.run("echo still > \(d.path("still"))")
        _ = try d.file("still")
        try d.run("exit")
    }),
    ("persist-close-quit", "a tab closed just before quitting still has its session ended", { d in
        d.quit()
        let config = "session-persistence = true\nconfirm-close-surface = false\n"
        try d.launch(config: config)
        try d.run("sh -c 'echo $PPID' > \(d.path("pid1"))")
        guard let kept = Int32(try d.file("pid1").trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw Failure("no shell pid")
        }
        // A second tab, closed (it has the keyboard), then quit at once --
        // well inside its undo window.
        d.newTab()
        usleep(1_200_000)
        try d.run("sh -c 'echo $PPID' > \(d.path("pid2"))")
        guard let closed = Int32(try d.file("pid2").trimmingCharacters(in: .whitespacesAndNewlines)),
              closed != kept else {
            throw Failure("no second shell")
        }
        d.closeTab()
        usleep(500_000)
        try d.quitNormally()
        guard d.wait(for: { kill(closed, 0) != 0 }, timeout: 8) else {
            throw Failure("the closed tab's shell outlived the quit")
        }
        guard kill(kept, 0) == 0 else { throw Failure("the open tab's session did not survive the quit") }
    }),
    ("persist-second-owner", "a second copy of Tako restoring the same session is refused and starts nothing", { d in
        d.quit()
        let config = "session-persistence = true\n"
        try d.launch(config: config)
        try d.run("sh -c 'echo $PPID' > \(d.path("pid"))")
        guard let shell = Int32(try d.file("pid").trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw Failure("no shell pid")
        }
        // Saved with its session, then reattached: this copy owns it.
        try d.quitNormally()
        try d.launch(config: config)
        try d.run("sh -c 'echo $PPID' > \(d.path("pid2"))")
        guard try d.file("pid2").trimmingCharacters(in: .whitespacesAndNewlines) == String(shell) else {
            throw Failure("the first copy did not reattach")
        }
        // A second copy restores the same window, so the same session.
        let other = try d.launchAnother(config: config)
        defer { kill(other, SIGKILL) }
        guard d.wait(for: { d.screenTexts(ofPid: other).contains { $0.contains("open in another copy of Tako") } },
                     timeout: 15) else {
            throw Failure("the second copy said nothing about the session: \(d.screenTexts(ofPid: other).map { $0.suffix(200) })")
        }
        // It started nothing: the session still has its one shell, and the
        // first copy still drives it.
        try d.run("sh -c 'echo $PPID' > \(d.path("pid3"))")
        guard try d.file("pid3").trimmingCharacters(in: .whitespacesAndNewlines) == String(shell) else {
            throw Failure("the first copy lost its session")
        }
        try d.run("exit")
    }),
    ("persist-cancel", "a cancelled quit leaves the persistent terminal working and its session alive", { d in
        d.quit()
        // With persistence a running command does not make quitting ask (it
        // keeps running), so the confirmation is forced to have one to cancel.
        let config = "session-persistence = true\nconfirm-close-surface = always\n"
        try d.launch(config: config)
        try d.run("sh -c 'echo $PPID' > \(d.path("pid"))")
        guard let shell = Int32(try d.file("pid").trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw Failure("no shell pid")
        }
        try d.run("sleep 300")
        usleep(800_000)
        d.key(Key.q, .maskCommand)
        var cancel: AXUIElement?
        guard d.wait(for: { cancel = d.button(titled: "Cancel"); return cancel != nil }, timeout: 5),
              let cancel else {
            throw Failure("cmd+q did not show confirmation dialog with Cancel button")
        }
        d.press(cancel)
        guard d.wait(for: { d.button(titled: "Cancel") == nil }, timeout: 5) else {
            throw Failure("quit confirmation dialog remained open after Cancel")
        }
        guard d.pid != 0, NSRunningApplication(processIdentifier: d.pid) != nil else {
            throw Failure("Tako quit although the quit was cancelled")
        }
        d.interrupt()
        try d.run("echo after > \(d.path("after"))")
        _ = try d.file("after")
        guard kill(shell, 0) == 0 else { throw Failure("the session's shell ended") }
        try d.run("exit")
    }),
    ("persist-reflow", "a restored persistent session reflows and updates columns when widened", { d in
        d.quit()
        let config = "session-persistence = true\n"
        try d.launch(config: config)
        d.setPosition(CGPoint(x: 20, y: 50))
        d.setSize(CGSize(width: 650, height: 500))
        d.focus()
        usleep(1_000_000)
        try d.run("tput cols > \(d.path("cols_narrow"))")
        let narrow = Int(try d.file("cols_narrow").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        guard narrow > 0 && narrow < 95 else { throw Failure("narrow cols precondition failed: \(narrow)") }

        // Construct unique marker at runtime from distinct components and deliver via base64 decoding in Python
        // so no substring of the marker is ever typed into the shell command or command echo buffer.
        let p1 = "REFLOW_MARKER_PARTA_"
        let p2 = String(repeating: "J", count: 42)
        let p3 = "_SPLIT_MID_"
        let p4 = String(repeating: "K", count: 42)
        let expectedMarker = p1 + p2 + p3 + p4 // 115 chars
        let markerB64 = Data(expectedMarker.utf8).base64EncodedString()
        try d.run("python3 -c \"import base64, sys; sys.stdout.write(base64.b64decode('\(markerB64)').decode('utf-8') + '\\n')\"")
        usleep(1_000_000)

        let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
        // Precondition: In narrow terminal, the 115-char marker wraps and does NOT appear on any single line.
        // Also verify takoctl exit code succeeded via separate status witness.
        // Using --styled reads physical viewport rows rather than unstyled logical scrollback.
        try d.run("\(ctl) text --styled --lines 12 > \(d.path("narrow_text")) && echo OK > \(d.path("narrow_ok"))")
        guard try d.file("narrow_ok").trimmingCharacters(in: .whitespacesAndNewlines) == "OK" else {
            throw Failure("takoctl text failed at narrow width")
        }
        let narrowRows = (try? d.file("narrow_text"))?.components(separatedBy: "\n").map {
            $0.replacingOccurrences(of: "\u{1b}\\[[0-9;]*[a-zA-Z]", with: "", options: .regularExpression).trimmingCharacters(in: .newlines)
        } ?? []
        guard !narrowRows.isEmpty && !narrowRows.allSatisfy({ $0.isEmpty }) else {
            throw Failure("precondition failed: narrowRows was empty!")
        }
        guard !narrowRows.contains(where: { $0.contains(expectedMarker) }) else {
            throw Failure("precondition failed: marker was not wrapped across physical rows in narrow \(narrow) columns. Rows were: \(narrowRows)")
        }
        // Verify physical row boundaries: prefix row must contain p1 and subsequent row must contain p4.suffix(20),
        // and together they reconstruct the full wrapped marker.
        guard let prefixIdx = narrowRows.firstIndex(where: { $0.contains(p1) }),
              prefixIdx + 1 < narrowRows.count,
              narrowRows[prefixIdx + 1].contains(p4.suffix(20)),
              (narrowRows[prefixIdx] + narrowRows[prefixIdx + 1]).contains(expectedMarker) else {
            throw Failure("precondition failed: could not identify physical wrapped row boundaries in narrow text: \(narrowRows)")
        }

        try d.quitNormally()

        try d.launch(config: config)
        d.setPosition(CGPoint(x: 20, y: 50))
        d.setSize(CGSize(width: 1250, height: 700))
        d.focus()
        usleep(1_500_000)

        try d.run("tput cols > \(d.path("cols_wide"))")
        let wide = Int(try d.file("cols_wide").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        guard wide > 120 && wide > narrow + 30 else {
            throw Failure("columns did not widen: was \(narrow), now \(wide)")
        }

        // Postcondition: Widening unwrapped the wrapped physical rows so the full 115-character marker
        // now fits onto a single physical terminal row.
        try d.run("\(ctl) text --styled --lines 50 > \(d.path("wide_text")) && echo OK > \(d.path("wide_ok"))")
        guard try d.file("wide_ok").trimmingCharacters(in: .whitespacesAndNewlines) == "OK" else {
            throw Failure("takoctl text failed at wide width")
        }
        let wideRows = (try? d.file("wide_text"))?.components(separatedBy: "\n").map {
            $0.replacingOccurrences(of: "\u{1b}\\[[0-9;]*[a-zA-Z]", with: "", options: .regularExpression).trimmingCharacters(in: .newlines)
        } ?? []
        guard wideRows.contains(where: { $0.contains(expectedMarker) }) else {
            throw Failure("physical reflow failed: marker was not unwrapped into a single line in wide \(wide) columns. Rows were: \(wideRows)")
        }

        try d.run("exit")
    }),
    ("find-stale", "a match that changes, or a tab that closes, while it is being shown is reported where the user is", { d in
        // A long settle leaves time to change the target's output after it
        // has been brought forward and before the match is checked.
        d.quit()
        d.environment = ["TAKO_FIND_ALL_SETTLE": "6"]
        defer { d.environment = [:] }
        try d.launch()
        let id = d.work.lastPathComponent
        let marker = "stale-\(id)"
        for (index, (ending, notice)) in [("clear", "changed since the search"), ("exit", "has been closed")].enumerated() {
            // Tab A prints the match, then waits for the witness file before
            // wiping it (clear) or going away (exit): the test creates the
            // file only once it has seen tab A brought forward.
            let witness = d.path("go\(index)")
            try d.run("printf 'stale-%s\\n' \(id); sh -c 'while [ ! -e \(witness) ]; do sleep 0.2; done'; \(ending)")
            d.key(Key.t, .maskCommand)
            usleep(1_200_000)
            d.key(Key.f, [.maskCommand, .maskShift])
            usleep(600_000)
            // The panel keeps the last query; replace it.
            d.key(Key.a, .maskCommand)
            try d.type(marker)
            guard d.wait(for: { d.staticTexts().contains { $0.contains(marker) } }, timeout: 5) else {
                throw Failure("the match was never listed: \(d.staticTexts())")
            }
            d.key(Key.returnKey)
            // Tab A in front: its screen holds the marker.
            guard d.wait(for: { d.screenText().contains(marker) }, timeout: 5) else {
                throw Failure("Return did not bring the tab with the match forward")
            }
            FileManager.default.createFile(atPath: witness, contents: Data())

            guard d.wait(for: { d.staticTexts().contains { $0.contains(notice) } }, timeout: 15) else {
                throw Failure("after '\(ending)' no notice; texts: \(d.staticTexts())")
            }
            guard d.textFields().contains(marker) else {
                throw Failure("the search field is not shown with the query: \(d.textFields())")
            }
            // The list was searched again: the row for the gone match is gone.
            guard d.wait(for: { !d.staticTexts().contains { $0.contains(marker) } }, timeout: 5) else {
                throw Failure("the stale result is still listed: \(d.staticTexts())")
            }
            // Escape gives the keyboard back to a terminal.
            d.key(Key.escape)
            usleep(500_000)
            try d.run("tty > \(d.path("back\(index)"))")
            guard (try? d.file("back\(index)")) != nil else {
                throw Failure("after Escape the keyboard did not reach a terminal")
            }
            try d.run("clear")
        }
    }),
    ("new-tab", "cmd+t opens a tab that takes the keyboard; exit closes it and gives it back", { d in
        // Native window tabs share one accessibility window, so a new tab is
        // a new terminal (its own tty) in the same number of windows.
        try d.run("tty > \(d.path("tty1"))")
        let first = try d.file("tty1")
        let windows = d.windows().count
        d.key(Key.t, .maskCommand)
        usleep(1_200_000)
        try d.run("tty > \(d.path("tty2"))")
        let second = try d.file("tty2")
        guard first != second else { throw Failure("typing after cmd+t still went to the first terminal (\(first))") }
        guard d.windows().count == windows else {
            throw Failure("cmd+t opened a window, not a tab (\(windows) windows before, \(d.windows().count) after)")
        }
        try d.run("exit")
        usleep(1_200_000)
        try d.run("tty > \(d.path("tty3"))")
        guard try d.file("tty3") == first else {
            throw Failure("after the tab's shell exited the keyboard did not go back to the first terminal")
        }
    }),
    ("split", "cmd+d splits, and the new pane has its own terminal and the keyboard", { d in
        try d.run("tty > \(d.path("pane1"))")
        let first = try d.file("pane1")
        d.key(Key.d, .maskCommand)
        usleep(1_500_000)
        try d.run("tty > \(d.path("pane2"))")
        let second = try d.file("pane2")
        guard first != second else { throw Failure("typing after cmd+d still went to the first pane") }
    }),
    ("zoom", "cmd+= makes the font bigger, which the program sees as fewer columns", { d in
        try d.run("tput cols > \(d.path("cols1"))")
        let before = Int(try d.file("cols1").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        d.key(Key.equal, .maskCommand)
        d.key(Key.equal, .maskCommand)
        usleep(800_000)
        try d.run("tput cols > \(d.path("cols2"))")
        let bigger = Int(try d.file("cols2").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        guard bigger < before else { throw Failure("zoomed in: \(before) columns before, \(bigger) after") }
        d.key(Key.zero, .maskCommand)
        usleep(800_000)
        try d.run("tput cols > \(d.path("cols3"))")
        let reset = Int(try d.file("cols3").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        guard reset == before else { throw Failure("cmd+0: \(before) columns at first, \(reset) after reset") }
    }),
    ("resize", "a smaller window is a smaller terminal for the program", { d in
        // A new window may open at the size the last one closed with, which
        // can be this scenario's own small one; start from a known large one.
        d.setSize(CGSize(width: 900, height: 600))
        usleep(1_000_000)
        try d.run("tput cols > \(d.path("wide"))")
        let wide = Int(try d.file("wide").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        d.setSize(CGSize(width: 420, height: 320))
        usleep(1_000_000)
        try d.run("tput cols > \(d.path("narrow"))")
        let narrow = Int(try d.file("narrow").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        guard narrow > 0, narrow < wide else { throw Failure("resized: \(wide) columns before, \(narrow) after") }
    }),
    ("paste", "cmd+v pastes the clipboard into the shell as typed text", { d in
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let saved { pasteboard.setString(saved, forType: .string) }
        }
        pasteboard.clearContents()
        pasteboard.setString("pasted  text", forType: .string)
        try d.type("printf '%s' '")
        d.key(Key.v, .maskCommand)
        usleep(500_000)
        try d.run("' > \(d.path("pasted"))")
        try d.expect("pasted", "pasted  text", "paste")
    }),
    ("paste-utf8", "cmd+v pastes utf8 text correctly", { d in
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let saved { pasteboard.setString(saved, forType: .string) }
        }
        pasteboard.clearContents()
        pasteboard.setString("кириллица 👋 123", forType: .string)
        try d.type("printf '%s' '")
        d.key(Key.v, .maskCommand)
        usleep(500_000)
        try d.run("' > \(d.path("pasted-utf8"))")
        try d.expect("pasted-utf8", "кириллица 👋 123", "paste-utf8")
    }),
    ("close-busy", "closing a terminal that is running something asks first", { d in
        try d.run("sleep 30")
        usleep(800_000)
        let windows = d.windows().count
        d.key(Key.w, .maskCommand)
        var cancel: AXUIElement?
        guard d.wait(for: { cancel = d.button(titled: "Cancel"); return cancel != nil }, timeout: 5),
              let cancel else {
            throw Failure("cmd+w closed a terminal running sleep without asking (\(d.windows().count) of \(windows) windows left)")
        }
        d.press(cancel)
        usleep(500_000)
        guard d.windows().count == windows else { throw Failure("Cancel still closed the window") }
        d.key(Key.c, .maskControl)
        try d.run("echo alive > \(d.path("alive"))")
        try d.expect("alive", "alive\n", "the terminal after Cancel")
    }),
    ("copy", "a double-click selects a word and cmd+c copies it", { d in
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let saved { pasteboard.setString(saved, forType: .string) }
        }
        pasteboard.clearContents()
        try d.run("tput lines > \(d.path("lines")); tput cols > \(d.path("cols"))")
        let rows = Int(try d.file("lines").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let cols = Int(try d.file("cols").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        // A screenful of the word, so the click lands on it whatever the
        // prompt looks like.
        try d.run("clear; yes copyme | head -n \(rows * 2)")
        usleep(800_000)
        guard rows > 0, cols > 0, let frame = d.terminalFrame() else { throw Failure("no terminal geometry") }
        let cell = CGSize(width: frame.width / CGFloat(cols), height: frame.height / CGFloat(rows))
        let point = CGPoint(x: frame.minX + cell.width * 2.5, y: frame.minY + cell.height * 2.5)
        try d.click(at: point, count: 2)
        usleep(300_000)
        guard d.menuItemEnabled("Copy") == true else {
            throw Failure("a double-click on a word selected nothing (Edit > Copy is disabled)")
        }
        d.key(Key.c, .maskCommand)
        guard d.wait(for: { pasteboard.string(forType: .string) == "copyme" }, timeout: 3) else {
            throw Failure("the clipboard holds \(pasteboard.string(forType: .string).map(hex) ?? "nothing"), not the double-clicked word")
        }
    }),
    ("quit-busy", "cmd+q while a command runs asks first, and Cancel keeps everything", { d in
        try d.run("sleep 30")
        usleep(800_000)
        d.key(Key.q, .maskCommand)
        var cancel: AXUIElement?
        guard d.wait(for: { cancel = d.button(titled: "Cancel"); return cancel != nil }, timeout: 5),
              let cancel else {
            throw Failure(d.isRunning ? "cmd+q asked nothing" : "cmd+q quit with a command running, without asking")
        }
        d.press(cancel)
        usleep(500_000)
        guard d.isRunning else { throw Failure("Cancel still quit") }
        d.key(Key.c, .maskControl)
        try d.run("echo alive > \(d.path("alive"))")
        try d.expect("alive", "alive\n", "the terminal after Cancel")
    }),
    ("config", "the config file is read, and Reload Configuration applies a change to the open terminal", { d in
        d.quit()
        try d.launch(config: Driver.defaultConfig + "font-size = 12\n")
        try d.run("tput cols > \(d.path("small"))")
        let small = Int(try d.file("small").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        d.quit()
        try d.launch(config: Driver.defaultConfig + "font-size = 24\n")
        try d.run("tput cols > \(d.path("large"))")
        let large = Int(try d.file("large").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        guard large > 0, large < small else { throw Failure("font-size 12 gave \(small) columns, 24 gave \(large)") }

        try "font-size = 12\n".write(toFile: d.path("config"), atomically: true, encoding: .utf8)
        d.key(Key.comma, [.maskCommand, .maskShift])
        usleep(1_200_000)
        try d.run("tput cols > \(d.path("reloaded"))")
        let reloaded = Int(try d.file("reloaded").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        guard reloaded > large else {
            throw Failure("after reloading font-size 12 the terminal still has \(reloaded) columns (24pt had \(large))")
        }
    }),
    ("padding", "window-padding-x takes columns away from the program", { d in
        func cols(_ config: String, _ name: String) throws -> Int {
            d.quit()
            try d.launch(config: Driver.defaultConfig + config)
            try d.run("tput cols > \(d.path(name))")
            return Int(try d.file(name).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }
        let none = try cols("window-padding-x = 0\n", "pad0")
        let wide = try cols("window-padding-x = 100\n", "pad100")
        guard wide > 0, wide < none else { throw Failure("padding 0 gave \(none) columns, padding 100 gave \(wide)") }
    }),
    ("split-focus", "cmd+] moves the keyboard to the next split and back round", { d in
        try d.run("tty > \(d.path("sf1"))")
        let first = try d.file("sf1")
        d.key(Key.d, .maskCommand)
        usleep(1_500_000)
        try d.run("tty > \(d.path("sf2"))")
        let second = try d.file("sf2")
        guard second != first else { throw Failure("cmd+d did not give the new split the keyboard") }
        d.key(Key.rightBracket, .maskCommand)
        usleep(800_000)
        try d.run("tty > \(d.path("sf3"))")
        guard try d.file("sf3") == first else { throw Failure("cmd+] did not move the keyboard to the other split") }
    }),
    ("quit-idle", "cmd+q with nothing running quits without asking", { d in
        d.key(Key.q, .maskCommand)
        guard d.wait(for: { !d.isRunning }, timeout: 8) else {
            let asked = d.button(titled: "Cancel") != nil
            throw Failure(asked ? "cmd+q asked although nothing was running" : "cmd+q did not quit")
        }
    }),
    ("new-window", "cmd+n opens a second window with its own terminal and the keyboard", { d in
        try d.run("tty > \(d.path("win1"))")
        let first = try d.file("win1")
        let windows = d.windows().count
        d.key(Key.n, .maskCommand)
        guard d.wait(for: { d.windows().count == windows + 1 }, timeout: 5) else {
            throw Failure("cmd+n: \(windows) windows before, \(d.windows().count) after")
        }
        usleep(1_000_000)
        try d.run("tty > \(d.path("win2"))")
        guard try d.file("win2") != first else { throw Failure("typing after cmd+n went to the old window") }
    }),
    ("settings", "cmd+, opens the in-terminal settings dialog, and Esc dismisses it", { d in
        d.key(Key.comma, .maskCommand)
        var closeBtn: AXUIElement?
        guard d.wait(for: { closeBtn = d.button(titled: "Close"); return closeBtn != nil }, timeout: 5) else {
            throw Failure("cmd+, did not present the settings dialog (Close button not found)")
        }
        d.key(Key.escape)
        guard d.wait(for: { d.button(titled: "Close") == nil }, timeout: 5) else {
            throw Failure("Escape did not dismiss the settings dialog")
        }
    }),
    ("settings-record", "settings shortcut recorder activates, cancels on Esc, records custom shortcut, and resets to default", { d in
        d.key(Key.comma, .maskCommand)
        var recordBtn: AXUIElement?
        guard d.wait(for: { recordBtn = d.button(titled: "Record"); return recordBtn != nil }, timeout: 5),
              let recordBtn else {
            throw Failure("settings dialog Record button not found")
        }
        guard d.button(titled: "Close") != nil else {
            throw Failure("settings dialog Close button not found")
        }
        // Test recording mode activation via Record button
        d.press(recordBtn)
        guard d.wait(for: { d.hasText(containing: "recording") || d.hasText(containing: "RECORDING") || d.hasText(containing: "cancel") }, timeout: 5) else {
            throw Failure("settings dialog did not enter recording state after pressing Record")
        }
        // In recording mode, first Esc cancels recording without modifying keybindings or closing settings
        d.key(Key.escape)
        guard d.wait(for: { d.button(titled: "Close") != nil && (d.hasText(containing: "cancelled") || !d.hasText(containing: "recording")) }, timeout: 5) else {
            throw Failure("first Escape did not cancel recording while leaving Settings dialog open")
        }
        // Activate recording again via key 'r'
        d.key(Key.r)
        guard d.wait(for: { d.hasText(containing: "recording") || d.hasText(containing: "RECORDING") }, timeout: 5) else {
            throw Failure("settings dialog did not enter recording state after pressing 'r'")
        }
        // Record custom shortcut: Cmd+Opt+Ctrl+K
        d.key(Key.k, [.maskCommand, .maskAlternate, .maskControl])
        guard d.wait(for: { d.hasText(containing: "custom") || d.hasText(containing: "Updated") }, timeout: 5) else {
            throw Failure("custom shortcut was not saved and applied in settings dialog")
        }
        // Reset selected keybinding back to default via key 'd'
        d.key(Key.d)
        guard d.wait(for: { d.hasText(containing: "Reset") || d.hasText(containing: "default") }, timeout: 5) else {
            throw Failure("Reset action failed to restore default keybinding")
        }
        // Esc closes settings dialog
        d.key(Key.escape)
        guard d.wait(for: { d.button(titled: "Record") == nil && d.button(titled: "Close") == nil }, timeout: 5) else {
            throw Failure("second Escape did not dismiss settings dialog")
        }
        // Unassisted keyboard delivery to terminal pane afterwards
        try d.run("echo 'settings_ok' > \(d.path("settings_witness"))")
        try d.expect("settings_witness", "settings_ok\n", "terminal keyboard input after settings dismissal")
    }),
    ("settings-conflict", "settings detects shortcut conflict, supports cancel (Esc) and confirm overwrite (Return)", { d in
        d.key(Key.comma, .maskCommand)
        guard d.wait(for: { d.button(titled: "Close") != nil }, timeout: 5) else {
            throw Failure("settings dialog did not open")
        }
        // Start recording
        d.key(Key.r)
        guard d.wait(for: { d.hasText(containing: "recording") || d.hasText(containing: "RECORDING") }, timeout: 5) else {
            throw Failure("did not enter recording mode")
        }
        // Enter a shortcut known to conflict with another default action: Cmd+D (Split Right)
        d.key(Key.d, .maskCommand)
        guard d.wait(for: { d.hasText(containing: "Conflict:") && d.hasText(containing: "Overwrite? (Return=Yes, Esc=No)") }, timeout: 5) else {
            throw Failure("conflict warning banner was not displayed for conflicting shortcut Cmd+D")
        }
        // Step 1: Cancel conflict reassignment via Escape
        d.key(Key.escape)
        guard d.wait(for: { d.hasText(containing: "Reassignment cancelled.") || d.hasText(containing: "cancelled") }, timeout: 5) else {
            throw Failure("Escape did not cancel conflict reassignment")
        }
        // Step 2: Record again and confirm reassignment via Return
        d.key(Key.r)
        guard d.wait(for: { d.hasText(containing: "recording") || d.hasText(containing: "RECORDING") }, timeout: 5) else {
            throw Failure("did not enter recording mode for second pass")
        }
        d.key(Key.d, .maskCommand)
        guard d.wait(for: { d.hasText(containing: "Conflict:") }, timeout: 5) else {
            throw Failure("conflict warning banner was not displayed on second pass")
        }
        d.key(Key.returnKey)
        guard d.wait(for: { d.hasText(containing: "Reassigned") || d.hasText(containing: "custom") || d.hasText(containing: "Updated") }, timeout: 5) else {
            throw Failure("Return did not confirm and apply reassignment")
        }
        // Restore default via 'd' (Reset)
        d.key(Key.d)
        usleep(200_000)
        // Dismiss settings
        d.key(Key.escape)
        guard d.wait(for: { d.button(titled: "Close") == nil }, timeout: 5) else {
            throw Failure("Escape did not dismiss settings dialog")
        }
        // Unassisted keyboard delivery to terminal pane afterwards
        try d.run("echo 'conflict_ok' > \(d.path("conflict_witness"))")
        try d.expect("conflict_witness", "conflict_ok\n", "terminal keyboard input after conflict dialog flow")
    }),
    ("modal-containment", "modal settings dialog blocks keystrokes and shortcuts from leaking to underlying terminal PTY", { d in
        let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
        d.key(Key.comma, .maskCommand)
        guard d.wait(for: { d.button(titled: "Close") != nil }, timeout: 5) else {
            throw Failure("settings dialog did not open for modal containment test")
        }
        // Attempt typing command into terminal while modal is active
        let leakFile = d.path("containment_leak.txt")
        try d.run("echo 'leaked_to_pty' > \(leakFile)")
        // Attempt split shortcut (Cmd+D) while modal is active: must be blocked by performKeyEquivalent
        d.key(Key.d, .maskCommand)
        usleep(400_000)

        // Verify no split pane was created
        let tree = try d.exec("\(ctl) tree --json")
        guard !tree.contains("\"split\"") else {
            throw Failure("Cmd+D leaked through modal dialog and created a split pane: \(tree)")
        }
        // Verify terminal PTY received no leaked keystrokes
        guard !FileManager.default.fileExists(atPath: leakFile) else {
            throw Failure("keystrokes leaked through modal dialog to terminal PTY")
        }

        // Dismiss settings dialog
        d.key(Key.escape)
        guard d.wait(for: { d.button(titled: "Close") == nil }, timeout: 5) else {
            throw Failure("Escape did not dismiss settings dialog")
        }
        // Verify terminal PTY input recovers cleanly
        let recoveredFile = d.path("containment_recovered.txt")
        try d.run("echo 'containment_ok' > \(recoveredFile)")
        try d.expect("containment_recovered.txt", "containment_ok\n", "terminal keyboard input recovery after modal dismissal")
    }),
    ("sidebar", "cmd+opt+s toggles the session sidebar open and closed", { d in
        d.key(Key.s, [.maskCommand, .maskAlternate])
        guard d.wait(for: { d.hasText(containing: "Sessions") }, timeout: 5) else {
            throw Failure("session sidebar 'Sessions' header was not visible after Cmd+Opt+S")
        }
        // Toggle again to return to normal
        d.key(Key.s, [.maskCommand, .maskAlternate])
        guard d.wait(for: { !d.hasText(containing: "Sessions") }, timeout: 5) else {
            throw Failure("session sidebar was still visible after second Cmd+Opt+S")
        }
        // Unassisted keyboard delivery to terminal pane afterwards
        try d.run("echo 'sidebar_ok' > \(d.path("sidebar_witness"))")
        try d.expect("sidebar_witness", "sidebar_ok\n", "terminal keyboard input after sidebar toggle")
    }),
    ("overview", "cmd+shift+o toggles pane overview on, and Esc dismisses it", { d in
        d.key(Key.o, [.maskCommand, .maskShift])
        guard d.wait(for: { d.hasText(containing: "Pane Overview") }, timeout: 5) else {
            throw Failure("pane overview header was not visible after Cmd+Shift+O")
        }
        d.key(Key.escape)
        guard d.wait(for: { !d.hasText(containing: "Pane Overview") }, timeout: 5) else {
            throw Failure("pane overview was still visible after Escape")
        }
        // Unassisted keyboard delivery to terminal pane afterwards
        try d.run("echo 'overview_ok' > \(d.path("overview_witness"))")
        try d.expect("overview_witness", "overview_ok\n", "terminal keyboard input after overview dismissal")
    }),
    ("workspace-switch", "takoctl workspace commands create, list, and switch project workspaces", { d in
        let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
        _ = try d.exec("\(ctl) workspace create E2EWS")
        let list = try d.exec("\(ctl) workspace list")
        guard list.contains("E2EWS") else {
            throw Failure("workspace list did not contain newly created workspace: \(list)")
        }
        _ = try d.exec("\(ctl) workspace switch E2EWS")
        let currE2E = try d.exec("\(ctl) workspace current")
        guard currE2E.contains("E2EWS") else {
            throw Failure("workspace current was not E2EWS after switch: \(currE2E)")
        }
        _ = try d.exec("\(ctl) workspace switch Default")
        let currDef = try d.exec("\(ctl) workspace current")
        guard currDef.contains("Default") else {
            throw Failure("workspace current was not Default after switch back: \(currDef)")
        }
        _ = try d.exec("\(ctl) workspace delete E2EWS")
    }),
    ("broadcast", "takoctl broadcast starts and stops synchronized typing across panes with verified non-target execution barrier", { d in
        let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
        // Record leader pane TTY and ID before splitting
        let leaderTtyPath = d.path("leader_tty.txt")
        d.activate()
        try d.run("tty > \(leaderTtyPath)")
        guard d.wait(for: { (try? d.file("leader_tty.txt").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) == false }, timeout: 5) else {
            throw Failure("failed to read initial leader pane TTY")
        }
        let leaderTty = try d.file("leader_tty.txt").trimmingCharacters(in: .whitespacesAndNewlines)

        func extractPanes(from json: String) -> [String] {
            if let data = json.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let root = (obj["result"] as? [String: Any]) ?? obj
                if let windows = root["windows"] as? [[String: Any]] {
                    var ids: [String] = []
                    for w in windows {
                        for t in (w["tabs"] as? [[String: Any]]) ?? [] {
                            for p in (t["panes"] as? [[String: Any]]) ?? [] {
                                if let id = p["id"] as? String { ids.append(id) }
                            }
                        }
                    }
                    if !ids.isEmpty { return ids }
                }
            }
            if let regex = try? NSRegularExpression(pattern: "\"id\"\\s*:\\s*\"([a-f0-9\\-]+)\"") {
                let nsStr = json as NSString
                let matches = regex.matches(in: json, range: NSRange(location: 0, length: nsStr.length))
                return matches.map { nsStr.substring(with: $0.range(at: 1)) }
            }
            return []
        }
        let treeBefore = try d.exec("\(ctl) tree --json")
        let initialIds = extractPanes(from: treeBefore)
        guard let leaderId = initialIds.first else {
            throw Failure("could not identify initial leader pane ID from tree: \(treeBefore)")
        }

        let splitOutput = try d.exec("\(ctl) split right")
        let nonTargetId = splitOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        usleep(600_000)

        // Refocus the leader pane so post-stop keyboard delivery is deterministically directed to leader
        _ = try d.exec("\(ctl) focus --target \(leaderId)")
        usleep(400_000)

        let witnessPath = d.path("bcast_witness.txt")
        _ = try d.exec("\(ctl) broadcast start")
        let status = try d.exec("\(ctl) broadcast status --json")
        guard status.contains("\"active\":true") || status.contains("\"active\": true") else {
            throw Failure("broadcast status was not active after start: \(status)")
        }
        // Send typing payload via keyboard while broadcast is active: record per-pane TTY identity
        d.activate()
        try d.run("tty >> \(witnessPath)")
        _ = try d.file("bcast_witness.txt")
        // Both panes must have received the keystrokes and written their distinct TTY path
        guard d.wait(for: {
            guard let content = try? String(contentsOfFile: witnessPath, encoding: .utf8) else { return false }
            let lines = content.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let uniqueTtys = Set(lines)
            return lines.count == 2 && uniqueTtys.count == 2
        }, timeout: 5) else {
            let content = (try? String(contentsOfFile: witnessPath, encoding: .utf8)) ?? ""
            throw Failure("broadcast typing was not delivered to both distinct panes: \(content)")
        }
        // Stop broadcast
        _ = try d.exec("\(ctl) broadcast stop")
        let stopped = try d.exec("\(ctl) broadcast status --json")
        guard stopped.contains("\"active\":false") || stopped.contains("\"active\": false") else {
            throw Failure("broadcast was still active after stop: \(stopped)")
        }
        // Post-stop isolation: typing reaches focused leader pane
        let soloWitness = d.path("solo_witness.txt")
        d.activate()
        try d.run("tty >> \(soloWitness)")
        guard d.wait(for: {
            guard let content = try? String(contentsOfFile: soloWitness, encoding: .utf8) else { return false }
            let lines = content.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return lines.count == 1
        }, timeout: 5) else {
            let content = (try? String(contentsOfFile: soloWitness, encoding: .utf8)) ?? ""
            throw Failure("post-stop isolation failed: solo_witness occurrences != 1: \(content)")
        }

        // Ordered execution completion barrier through non-target pane's PTY queue with controlled delayed recipient
        let barrierFile = d.path("non_target_barrier.txt")
        _ = try d.exec("\(ctl) send \"sh -c 'sleep 0.2; echo non_target_barrier_done > \(barrierFile)'\" --target \(nonTargetId)")
        guard d.wait(for: {
            guard let text = try? String(contentsOfFile: barrierFile, encoding: .utf8) else { return false }
            return text.contains("non_target_barrier_done")
        }, timeout: 10) else {
            throw Failure("non-target execution barrier did not complete via PTY queue")
        }

        // Verify all witnesses: exactly one target TTY and zero non-target deliveries
        let finalContent = (try? String(contentsOfFile: soloWitness, encoding: .utf8)) ?? ""
        let finalLines = finalContent.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard finalLines.count == 1 && finalLines.first == leaderTty else {
            throw Failure("post-stop barrier check failed: expected exactly 1 leader delivery (\(leaderTty)), got: \(finalContent)")
        }
    }),
    ("input-ownership", "takoctl input lock and unlock control input ownership without error", { d in
        let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
        let leakFile = d.path("input_leak.txt")
        let autoFile = d.path("input_auto.txt")
        let recoveredFile = d.path("input_recovered.txt")

        _ = try d.exec("\(ctl) input lock --owner e2e-agent")
        let status = try d.exec("\(ctl) input status --json")
        guard (status.contains("\"locked\":true") || status.contains("\"locked\": true")) && status.contains("e2e-agent") else {
            throw Failure("input status was not locked to agent: \(status)")
        }

        // While locked, attempt physical human keyboard input: must be blocked by surface input gate
        d.activate()
        try d.run("echo 'leak_witness' > \(leakFile)")
        usleep(400_000)
        guard !FileManager.default.fileExists(atPath: leakFile) else {
            throw Failure("input lock failed: physical keyboard input leaked through while pane was locked")
        }

        // Verify approved automation command executes without error
        let autoStatus = try d.exec("\(ctl) input allow-automation")
        guard autoStatus.contains("allowed") || autoStatus.contains("true") else {
            throw Failure("allow-automation failed: \(autoStatus)")
        }

        // Send an authorized automated command and require its unique PTY witness during lock
        _ = try d.exec("\(ctl) send \"echo auto_witness > \(autoFile)\"")
        try d.expect("input_auto.txt", "auto_witness\n", "authorized automated input delivered while pane locked")

        // Unlock
        _ = try d.exec("\(ctl) input unlock")
        let unlocked = try d.exec("\(ctl) input status --json")
        guard unlocked.contains("\"locked\":false") || unlocked.contains("\"locked\": false") else {
            throw Failure("input status was still locked after unlock: \(unlocked)")
        }

        // Verify physical keyboard input recovery after unlock
        d.activate()
        try d.run("echo 'recovered_witness' > \(recoveredFile)")
        try d.expect("input_recovered.txt", "recovered_witness\n", "keyboard input recovery after unlock")
    }),
    ("diff-review", "takoctl review open, comment add/list/clear, and close manage worktree diff review state cleanly", { d in
        let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
        // Initialize git repo in a dedicated clean subdirectory of d.work with an uncommitted change to review
        let repoPath = d.path("diff_repo")
        try FileManager.default.createDirectory(atPath: repoPath, withIntermediateDirectories: true)
        let initScript = """
        cd '\(repoPath)' && git init -b main && git config user.name 'Alex' && git config user.email 'alex@prod.codes' && \
        echo 'line 1' > review_test.txt && git add review_test.txt && git commit -m 'initial' && \
        echo 'line 2 added' >> review_test.txt
        """
        _ = try d.exec("sh -c \"\(initScript)\"")

        // Set pane cwd into repoPath
        d.activate()
        try d.run("cd '\(repoPath)'")
        usleep(400_000)

        // Open diff review session
        _ = try d.exec("\(ctl) review open \"\(repoPath)\"")
        let status = try d.exec("\(ctl) review status --json")
        guard (status.contains("\"open\":true") || status.contains("\"open\": true")) &&
              (status.contains("\"files_count\":1") || status.contains("\"files_count\": 1") || (status.contains("\"files_count\":") && !status.contains("\"files_count\":0"))) else {
            throw Failure("review status did not reflect active session with changed file: \(status)")
        }

        // List changed files
        let filesList = try d.exec("\(ctl) review files --json")
        guard filesList.contains("review_test.txt") else {
            throw Failure("review files did not list review_test.txt: \(filesList)")
        }

        // Add a line comment
        let addRes = try d.exec("\(ctl) review comment add --file review_test.txt --line 2 --text 'Check added line'")
        guard addRes.contains("comment") || addRes.contains("Added") || addRes.contains("review_test.txt") else {
            throw Failure("review comment add failed: \(addRes)")
        }

        // List comments and assert content
        let comments = try d.exec("\(ctl) review comment list --json")
        guard comments.contains("Check added line") && (comments.contains("\"line\":2") || comments.contains("\"line\": 2")) else {
            throw Failure("review comment list did not contain added comment: \(comments)")
        }

        // Clear comments
        _ = try d.exec("\(ctl) review comment clear")
        let clearedComments = try d.exec("\(ctl) review comment list --json")
        guard !clearedComments.contains("Check added line") else {
            throw Failure("review comment clear failed: \(clearedComments)")
        }

        // Close review session
        _ = try d.exec("\(ctl) review close")
        let closedStatus = try d.exec("\(ctl) review status --json")
        guard closedStatus.contains("\"open\":false") || closedStatus.contains("\"open\": false") else {
            throw Failure("review was still open after close: \(closedStatus)")
        }

        // Verify unassisted keyboard delivery to terminal pane afterwards
        try d.run("echo 'review_ok' > \(d.path("review_witness"))")
        try d.expect("review_witness", "review_ok\n", "terminal keyboard input after review session closed")
    }),
    ("overlay", "takoctl overlay opens markdown document with verified on-screen metadata and closes cleanly", { d in
        let ctl = "\(d.appURL.path)/Contents/MacOS/takoctl --bundle-id \(d.bundleID)"
        // Create document inside d.work (run-owned temporary workspace)
        let docPath = d.path("tako_overlay_test.md")
        try "# Test Note\nHello Sandboxed Overlay Content\n".write(toFile: docPath, atomically: true, encoding: .utf8)

        // Move the pane cwd into d.work and verify cwd updated
        d.activate()
        try d.run("cd '\(d.work.path)' && pwd > \(d.path("overlay_cwd.txt"))")
        guard d.wait(for: {
            let current = (try? d.file("overlay_cwd.txt").trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
            return current == d.work.path
        }, timeout: 5) else {
            throw Failure("failed to change pane cwd to owned temporary directory \(d.work.path)")
        }

        let openRes = try d.exec("\(ctl) overlay open \"\(docPath)\"")
        let status = try d.exec("\(ctl) overlay status --json")
        guard (status.contains("\"open\":true") || status.contains("\"open\": true")) &&
              status.contains("tako_overlay_test.md") &&
              status.contains("markdown") else {
            throw Failure("overlay status did not return open markdown document (open result: \(openRes)): \(status)")
        }

        // Verify on-screen overlay presentation and sandboxed indicator
        guard d.wait(for: { d.hasText(containing: "MARKDOWN") && d.hasText(containing: "sandboxed:") }, timeout: 5) else {
            throw Failure("overlay visual header bar or sandboxed indicator not found on screen")
        }

        // Close overlay
        _ = try d.exec("\(ctl) overlay close")
        let closed = try d.exec("\(ctl) overlay status --json")
        guard closed.contains("\"open\":false") || closed.contains("\"open\": false") else {
            throw Failure("overlay was still open after close: \(closed)")
        }

        // Verify unassisted keyboard delivery to terminal pane afterwards
        try d.run("echo 'overlay_ok' > \(d.path("overlay_witness"))")
        try d.expect("overlay_witness", "overlay_ok\n", "terminal keyboard input after overlay closed")
    }),
]

// MARK: - Main

let args = Array(CommandLine.arguments.dropFirst())
guard let appPath = args.first else {
    print("usage: tako-e2e <Tako.app> [scenario ...]")
    for s in scenarios { print("  \(s.name.padding(toLength: 14, withPad: " ", startingAt: 0)) \(s.why)") }
    exit(2)
}
guard AXIsProcessTrusted() else {
    print("FAIL: this process has no Accessibility permission, so it can neither post keys nor read windows")
    exit(1)
}
let wanted = Set(args.dropFirst())
// Scenarios that need a build with the session runtime run only when named,
// from scripts/e2e-persist.sh: never as part of the default set.
let explicitOnly: Set<String> = ["persist-live", "persist-gone", "persist-close", "persist-cancel", "persist-close-asks", "persist-close-quit", "persist-second-owner", "persist-reflow"]
// A misspelt name must not pass as a run of nothing.
let unknown = wanted.subtracting(scenarios.map(\.name))
if !unknown.isEmpty {
    print("FAIL: no scenario named \(unknown.sorted().joined(separator: ", "))")
    exit(2)
}
let previouslyFront = NSWorkspace.shared.frontmostApplication
var failed = 0
if !wanted.isDisjoint(with: explicitOnly) {
    let helper = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Helpers/zmx").path
    guard FileManager.default.isExecutableFile(atPath: helper),
          ProcessInfo.processInfo.environment["TAKO_SESSIONS_HOME"] != nil else {
        print("FAIL: persistence scenarios need scripts/e2e-persist.sh (an app with its session runtime and an isolated session home)")
        exit(2)
    }
}
for scenario in scenarios where (wanted.isEmpty && !explicitOnly.contains(scenario.name)) || wanted.contains(scenario.name) {
    // A fresh app per scenario: one that failed half way must not leave a
    // split, a zoom or a hung command behind for the next.
    do {
        let driver = try Driver(app: URL(fileURLWithPath: appPath))
        defer { driver.quit() }
        do {
            try driver.launch()
            try scenario.body(driver)
            print("ok    \(scenario.name.padding(toLength: 14, withPad: " ", startingAt: 0)) \(scenario.why)")
            // A failed scenario keeps its files, which are the evidence.
            try? FileManager.default.removeItem(at: driver.work)
        } catch {
            failed += 1
            print("FAIL  \(scenario.name.padding(toLength: 14, withPad: " ", startingAt: 0)) \(error)")
        }
    } catch {
        failed += 1
        print("FAIL  \(scenario.name): \(error)")
    }
}
print(failed == 0 ? "tako e2e: ok" : "tako e2e: \(failed) FAILED")
if let previouslyFront, !previouslyFront.isTerminated, let bundle = previouslyFront.bundleURL {
    // activate() from a process that is not itself in front is only a
    // request; open is how the focus reliably goes back.
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = ["-g", "-a", bundle.path]
    try? open.run()
    open.waitUntilExit()
    previouslyFront.activate()
}
exit(failed == 0 ? 0 : 1)

/// Two tabs, three panes, made through takoctl, then left long enough to be
/// recorded.
func crashLayoutSetup(_ d: Driver) throws {
    d.quit()
    forgetLayout(d)
    try d.launch(config: "window-save-state = always\n")
    usleep(500_000)
    // Start from one window, whatever an earlier run left.
    // Right after launch fish can still be starting and drop what is typed:
    // ask again until it answers, so the scenario starts from a shell that
    // is listening.
    var listening = false
    for _ in 0..<5 where !listening {
        try d.run("takoctl tree --json > \(d.path("start"))")
        listening = (try? d.file("start", timeout: 5)) != nil
        if !listening { usleep(300_000) }
    }
    guard listening else { throw Failure("the shell never took input: [\(d.screenText().suffix(400))]") }
    usleep(500_000)
    let out = d.work.path
    try """
    takoctl split right > /dev/null || exit 1
    takoctl tab-new --no-select > /dev/null || exit 1
    echo done > \(out)/made
    """.write(toFile: d.path("make.sh"), atomically: true, encoding: .utf8)
    try d.run("sh \(d.path("make.sh"))")
    guard (try? d.file("made", timeout: 15)) != nil else {
        throw Failure("the layout was not made; screen: [\(d.screenText().suffix(600))]")
    }
    usleep(2_000_000)
}

func crashLayoutCount(_ d: Driver, _ name: String) throws -> (windows: Int, tabs: Int, panes: Int) {
    try d.run("takoctl tree --json > \(d.path(name))")
    let json = try d.file(name)
    guard let data = json.data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let windows = (root["result"] as? [String: Any])?["windows"] as? [[String: Any]] else { return (0, 0, 0) }
    let tabs = windows.flatMap { $0["tabs"] as? [[String: Any]] ?? [] }
    return (windows.count, tabs.count, tabs.reduce(0) { $0 + (($1["panes"] as? [Any])?.count ?? 0) })
}

/// Nothing saved from an earlier run: neither AppKit's state nor the journal.
func forgetLayout(_ d: Driver) {
    let bundle = Bundle(url: d.appURL)?.bundleIdentifier ?? "com.tako-core.terminal"
    guard bundle != "com.tako-core.terminal" else {
        fputs("Safety error: forgetLayout refused to delete state for production bundle 'com.tako-core.terminal'\n", stderr)
        return
    }
    let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    // Newer macOS keeps saved windows where only the script finds them.
    let forget = Process()
    forget.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    forget.arguments = ["python3", "scripts/e2e/forget-saved-state.py", bundle]
    try? forget.run()
    forget.waitUntilExit()
    try? FileManager.default.removeItem(at: library.appendingPathComponent("Application Support/\(bundle)/layout"))
}
