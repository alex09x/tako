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
    static let leftBracket: CGKeyCode = 33
    static let rightBracket: CGKeyCode = 30
    static let s: CGKeyCode = 1
    static let o: CGKeyCode = 31
    static let r: CGKeyCode = 15
    static let k: CGKeyCode = 40
    static let p: CGKeyCode = 35
    static let one: CGKeyCode = 18
    static let two: CGKeyCode = 19
    static let right: CGKeyCode = 124
    static let down: CGKeyCode = 125
    static let up: CGKeyCode = 126
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
            app.activate(options: [.activateIgnoringOtherApps])
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
        guard let window = activeWindow(),
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
            if ch == "\n" || ch == "\r" {
                key(Key.returnKey)
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

    /// Type a command line and press Return.
    func run(_ command: String) throws {
        try type(command)
        usleep(20_000)
        key(Key.returnKey)
    }

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
        let out = String(data: data, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            throw Failure("command failed (exit \(process.terminationStatus)): \(command)\nOutput: \(out)")
        }
        return out
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

@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ identifier: UnsafeMutablePointer<CGWindowID>) -> AXError

    // MARK: accessibility

    private var axApp: AXUIElement { AXUIElementCreateApplication(pid) }

    func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    func windowID(for element: AXUIElement) -> CGWindowID? {
        var id: CGWindowID = 0
        if _AXUIElementGetWindow(element, &id) == .success {
            return id
        }
        return nil
    }

    func windows() -> [AXUIElement] {
        (attribute(axApp, kAXWindowsAttribute) as [AXUIElement]?) ?? []
    }

    func activeOnScreenWindow() -> AXUIElement? {
        let onScreen = onScreenWindowNumbers()
        guard !onScreen.isEmpty else { return nil }
        if let focused: AXUIElement = attribute(axApp, kAXFocusedWindowAttribute),
           let wid = windowID(for: focused), onScreen.contains(wid) {
            return focused
        }
        if let main: AXUIElement = attribute(axApp, kAXMainWindowAttribute),
           let wid = windowID(for: main), onScreen.contains(wid) {
            return main
        }
        for win in windows().reversed() {
            if let wid = windowID(for: win), onScreen.contains(wid) {
                return win
            }
        }
        for win in windows() {
            if let wid = windowID(for: win), onScreen.contains(wid) {
                return win
            }
        }
        return nil
    }

    func activeWindow() -> AXUIElement? {
        if let onScreen = activeOnScreenWindow() {
            return onScreen
        }
        if let focused: AXUIElement = attribute(axApp, kAXFocusedWindowAttribute) {
            return focused
        }
        if let main: AXUIElement = attribute(axApp, kAXMainWindowAttribute) {
            return main
        }
        for win in windows().reversed() {
            let hidden: Bool? = attribute(win, "AXHidden")
            let minimized: Bool? = attribute(win, "AXMinimized")
            if hidden != true && minimized != true {
                return win
            }
        }
        return windows().first
    }

    func debugFocusState() -> String {
        let focusedWin: AXUIElement? = attribute(axApp, kAXFocusedWindowAttribute)
        let mainWin: AXUIElement? = attribute(axApp, kAXMainWindowAttribute)
        let focusedElem: AXUIElement? = attribute(axApp, kAXFocusedUIElementAttribute)
        let fRole: String = (focusedElem.flatMap { attribute($0, kAXRoleAttribute) }) ?? "nil"
        let fId: String = (focusedElem.flatMap { attribute($0, "AXIdentifier") }) ?? "nil"
        let fTitle: String = (focusedElem.flatMap { attribute($0, kAXTitleAttribute) }) ?? "nil"
        let isAppActive = NSRunningApplication(processIdentifier: pid)?.isActive ?? false
        let pane = (try? focusedPaneId()) ?? "none"
        return "appActive: \(isAppActive), focusedWin: \(focusedWin != nil), mainWin: \(mainWin != nil), focusedElem: role=\(fRole), id=\(fId), title=\(fTitle), focusedPane: \(pane)"
    }

    /// Every element under `root` whose role is `role`.
    func descendants(of root: AXUIElement, role: String, depth: Int = 24) -> [AXUIElement] {
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

    /// A button with this title anywhere in Tako's visible windows or sheets.
    func button(titled title: String, depth: Int = 24) -> AXUIElement? {
        for window in windows() {
            let hidden: Bool? = attribute(window, "AXHidden")
            let minimized: Bool? = attribute(window, "AXMinimized")
            if hidden == true || minimized == true { continue }
            for btn in descendants(of: window, role: kAXButtonRole as String, depth: depth) {
                let axTitle: String? = attribute(btn, kAXTitleAttribute)
                let axDesc: String? = attribute(btn, kAXDescriptionAttribute)
                let axLabel: String? = attribute(btn, "AXLabel")
                let axId: String? = attribute(btn, "AXIdentifier")
                if axTitle == title || axDesc == title || axLabel == title || axId == title ||
                   axTitle?.contains(title) == true || axDesc?.contains(title) == true || axLabel?.contains(title) == true || axId?.contains(title) == true ||
                   elementContainsText(btn, target: title, depth: 3) {
                    return btn
                }
            }
        }
        return nil
    }

    /// A text field with this identifier or description anywhere in Tako's windows.
    func textField(identifier: String, depth: Int = 24) -> AXUIElement? {
        for window in windows() {
            for tf in descendants(of: window, role: kAXTextFieldRole as String, depth: depth) {
                let axId: String? = attribute(tf, "AXIdentifier")
                let axDesc: String? = attribute(tf, kAXDescriptionAttribute)
                let axTitle: String? = attribute(tf, kAXTitleAttribute)
                let axLabel: String? = attribute(tf, "AXLabel")
                if axId == identifier || axDesc == identifier || axTitle == identifier || axLabel == identifier ||
                   axId?.contains(identifier) == true || axDesc?.contains(identifier) == true {
                    return tf
                }
            }
        }
        return nil
    }

    /// Find element with exact or matching identifier under root (or windows).
    func element(withIdentifier identifier: String, root: AXUIElement? = nil, depth: Int = 24) -> AXUIElement? {
        let roots = root.map { [$0] } ?? windows()
        for r in roots {
            if let found = findElementById(r, identifier: identifier, depth: depth) {
                return found
            }
        }
        return nil
    }

    private func findElementById(_ element: AXUIElement, identifier: String, depth: Int) -> AXUIElement? {
        let axId: String? = attribute(element, "AXIdentifier")
        if axId == identifier || axId?.contains(identifier) == true { return element }
        guard depth > 0 else { return nil }
        for child in (attribute(element, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
            if let match = findElementById(child, identifier: identifier, depth: depth - 1) {
                return match
            }
        }
        return nil
    }

    /// Extract all distinct text values within an element's subtree.
    func textValues(under root: AXUIElement, depth: Int = 12) -> [String] {
        var texts: [String] = []
        let val: String? = attribute(root, kAXValueAttribute)
        let title: String? = attribute(root, kAXTitleAttribute)
        let desc: String? = attribute(root, kAXDescriptionAttribute)
        let label: String? = attribute(root, "AXLabel")
        for s in [val, title, desc, label].compactMap({ $0 }) {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !texts.contains(trimmed) {
                texts.append(trimmed)
            }
        }
        guard depth > 0 else { return texts }
        for child in (attribute(root, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
            for t in textValues(under: child, depth: depth - 1) {
                if !texts.contains(t) { texts.append(t) }
            }
        }
        return texts
    }

    /// List all pane IDs discovered in the app tree via takoctl.
    func paneIds() throws -> [String] {
        let ctl = "\(appURL.path)/Contents/MacOS/takoctl --bundle-id \(bundleID)"
        let treeJson = try exec("\(ctl) tree --json")
        if let data = treeJson.data(using: .utf8),
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
            let nsStr = treeJson as NSString
            let matches = regex.matches(in: treeJson, range: NSRange(location: 0, length: nsStr.length))
            return matches.map { nsStr.substring(with: $0.range(at: 1)) }
        }
        return []
    }

    /// Discover currently focused pane ID from tree via takoctl.
    func focusedPaneId() throws -> String? {
        let ctl = "\(appURL.path)/Contents/MacOS/takoctl --bundle-id \(bundleID)"
        let treeJson = try exec("\(ctl) tree --json")
        if let data = treeJson.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let root = (obj["result"] as? [String: Any]) ?? obj
            if let windows = root["windows"] as? [[String: Any]] {
                for w in windows {
                    for t in (w["tabs"] as? [[String: Any]]) ?? [] {
                        for p in (t["panes"] as? [[String: Any]]) ?? [] {
                            if p["focused"] as? Bool == true, let id = p["id"] as? String {
                                return id
                            }
                        }
                    }
                }
            }
        }
        return nil
    }

    /// On-screen window numbers belonging to Tako (layer 0).
    func onScreenWindowNumbers() -> Set<CGWindowID> {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        var result = Set<CGWindowID>()
        for info in list {
            guard let ownerPid = info[kCGWindowOwnerPID as String] as? pid_t, ownerPid == pid else { continue }
            guard (info[kCGWindowLayer as String] as? Int) == 0 else { continue }
            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  (bounds["Width"] ?? 0) > 80, (bounds["Height"] ?? 0) > 80 else { continue }
            if let idNum = info[kCGWindowNumber as String] as? UInt32 {
                result.insert(CGWindowID(idNum))
            }
        }
        return result
    }

    /// List all workspaces discovered via takoctl.
    func workspaceList() throws -> [[String: Any]] {
        let ctl = "\(appURL.path)/Contents/MacOS/takoctl --bundle-id \(bundleID)"
        let out = try exec("\(ctl) workspace list --json")
        guard let data = out.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        let root = (obj["result"] as? [String: Any]) ?? obj
        return (root["workspaces"] as? [[String: Any]]) ?? []
    }

    /// Get current active workspace via takoctl.
    func workspaceCurrent() throws -> [String: Any]? {
        let ctl = "\(appURL.path)/Contents/MacOS/takoctl --bundle-id \(bundleID)"
        let out = try exec("\(ctl) workspace current --json")
        guard let data = out.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return (obj["result"] as? [String: Any]) ?? obj
    }

    /// Get workspace transition history via takoctl.
    func workspaceTransitions() throws -> [[String: Any]] {
        let ctl = "\(appURL.path)/Contents/MacOS/takoctl --bundle-id \(bundleID)"
        let out = try exec("\(ctl) workspace history --json")
        guard let data = out.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        let root = (obj["result"] as? [String: Any]) ?? obj
        return (root["transitions"] as? [[String: Any]]) ?? []
    }

    /// Get tab transition history via takoctl.
    func tabTransitions() throws -> [[String: Any]] {
        let ctl = "\(appURL.path)/Contents/MacOS/takoctl --bundle-id \(bundleID)"
        let out = try exec("\(ctl) workspace history --json")
        guard let data = out.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        let root = (obj["result"] as? [String: Any]) ?? obj
        return (root["tab_transitions"] as? [[String: Any]]) ?? []
    }

    /// Whether any UI element across the app's windows contains this text.
    func hasText(containing target: String) -> Bool {
        for window in windows() {
            if elementContainsText(window, target: target, depth: 22) { return true }
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
    func topmostWindowInfo(at point: CGPoint) -> String {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else { return "none" }
        var parts: [String] = []
        for info in list {
            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let rect = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                              width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            if rect.contains(point) {
                let owner = info[kCGWindowOwnerName as String] as? String ?? "?"
                let ownerPid = info[kCGWindowOwnerPID as String] as? pid_t ?? 0
                let layer = info[kCGWindowLayer as String] as? Int ?? 0
                let num = info[kCGWindowNumber as String] as? Int ?? 0
                let alpha = info[kCGWindowAlpha as String] as? CGFloat ?? 1.0
                parts.append("[\(num):\(owner)(\(ownerPid)) L\(layer) a=\(alpha) \(rect)]")
            }
        }
        return parts.joined(separator: ", ")
    }

    func click(at point: CGPoint, count: Int = 1) throws {
        guard topmostOwner(at: point) == pid else {
            let winInfo = topmostWindowInfo(at: point)
            throw Failure("refusing to click at \(point): the window there is not Tako's (windows: \(winInfo))")
        }
        let home = CGEvent(source: nil)?.location
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(30_000)
        for n in 1...count {
            guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                                     mouseCursorPosition: point, mouseButton: .left)
            else { continue }
            down.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            down.post(tap: .cghidEventTap)
            usleep(100_000)

            guard let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                                   mouseCursorPosition: point, mouseButton: .left)
            else { continue }
            up.setIntegerValueField(.mouseEventClickState, value: Int64(n))
            up.post(tap: .cghidEventTap)
            usleep(100_000)
        }
        if let home {
            CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                    mouseCursorPosition: home, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
    }

    /// Rapid mouse click without helper settling sleeps or cursor restoration.
    @discardableResult
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

    /// Perform a drag from start screen point to end screen point via real CGEvent mouse events.
    func drag(from start: CGPoint, to end: CGPoint, steps: Int = 8) throws {
        guard topmostOwner(at: start) == pid else {
            throw Failure("refusing to drag from \(start): the window there is not Tako's")
        }
        let home = CGEvent(source: nil)?.location
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

    /// The window's frame in screen coordinates.
    func windowFrame(_ window: AXUIElement? = nil) -> CGRect? {
        guard let win = window ?? activeWindow(),
              let position: AXValue = attribute(win, kAXPositionAttribute),
              let size: AXValue = attribute(win, kAXSizeAttribute)
        else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position, .cgPoint, &origin)
        AXValueGetValue(size, .cgSize, &extent)
        return CGRect(origin: origin, size: extent)
    }

    /// Which process owns the frontmost window at a screen point.
    func topmostOwner(at point: CGPoint) -> pid_t? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for info in list {
            guard let ownerPid = info[kCGWindowOwnerPID as String] as? pid_t else { continue }
            let layer = (info[kCGWindowLayer as String] as? Int) ?? 0
            let alpha = info[kCGWindowAlpha as String] as? CGFloat ?? 1.0
            guard alpha > 0.05 else { continue }
            // Ordinary windows are layer 0. Also accept Tako's modal panels/alerts/menus (layers 1..120).
            guard layer == 0 || (ownerPid == pid && layer <= 120) else { continue }
            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let rect = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                              width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            if rect.contains(point) { return ownerPid }
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

    @discardableResult
    func pressMenu(title: String) -> Bool {
        guard let bar: AXUIElement = attribute(axApp, kAXMenuBarAttribute) else { return false }
        for top in (attribute(bar, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
            for menu in (attribute(top, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                for item in (attribute(menu, kAXChildrenAttribute) as [AXUIElement]?) ?? []
                where (attribute(item, kAXTitleAttribute) as String?) == title {
                    return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
                }
            }
        }
        return false
    }

    func onScreenWindows() -> [AXUIElement] {
        let onScreen = onScreenWindowNumbers()
        return windows().filter { win in
            guard let wid = windowID(for: win) else { return false }
            return onScreen.contains(wid)
        }
    }

    func tabElement(index: Int, in window: AXUIElement? = nil) -> AXUIElement? {
        let win = window ?? activeWindow()
        let targetId = "tab-\(index)"
        let roots = win.map { [$0] } ?? onScreenWindows()
        for root in roots {
            for elem in descendants(of: root, role: kAXRadioButtonRole as String) {
                if let id: String = attribute(elem, "AXIdentifier"), id == targetId {
                    return elem
                }
            }
        }
        return nil
    }

    func tabClickPoint(index: Int, in window: AXUIElement? = nil) throws -> CGPoint {
        guard let tab = tabElement(index: index, in: window) else {
            throw Failure("tab-\(index) accessibility element not found")
        }
        guard let tabPos: AXValue = attribute(tab, kAXPositionAttribute),
              let tabSize: AXValue = attribute(tab, kAXSizeAttribute) else {
            throw Failure("cannot get frame for tab-\(index)")
        }
        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(tabPos, .cgPoint, &pos)
        AXValueGetValue(tabSize, .cgSize, &size)
        return CGPoint(x: pos.x + min(25, size.width / 3), y: pos.y + size.height / 2)
    }

    func clickTab(index: Int, in window: AXUIElement? = nil) throws {
        let clickPoint = try tabClickPoint(index: index, in: window)
        try click(at: clickPoint)
        usleep(600_000)
    }

    func clickPlusButton(in window: AXUIElement? = nil) throws {
        let win = window ?? activeWindow()
        let roots = win.map { [$0] } ?? onScreenWindows()
        for root in roots {
            for elem in descendants(of: root, role: kAXButtonRole as String) {
                if let id: String = attribute(elem, "AXIdentifier"), id == "new-tab-button" {
                    if let btnPos: AXValue = attribute(elem, kAXPositionAttribute),
                       let btnSize: AXValue = attribute(elem, kAXSizeAttribute) {
                        var pos = CGPoint.zero
                        var size = CGSize.zero
                        AXValueGetValue(btnPos, .cgPoint, &pos)
                        AXValueGetValue(btnSize, .cgSize, &size)
                        let center = CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
                        try click(at: center)
                        usleep(1_000_000)
                        return
                    }
                }
            }
        }
        throw Failure("new-tab-button not found in window")
    }

    func clickWorkspacePill(in window: AXUIElement? = nil) throws {
        let win = window ?? activeWindow()
        let roots = win.map { [$0] } ?? onScreenWindows()
        for root in roots {
            for elem in descendants(of: root, role: kAXButtonRole as String) {
                if let id: String = attribute(elem, "AXIdentifier"), id == "workspace-pill" {
                    if let btnPos: AXValue = attribute(elem, kAXPositionAttribute),
                       let btnSize: AXValue = attribute(elem, kAXSizeAttribute) {
                        var pos = CGPoint.zero
                        var size = CGSize.zero
                        AXValueGetValue(btnPos, .cgPoint, &pos)
                        AXValueGetValue(btnSize, .cgSize, &size)
                        let center = CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
                        try click(at: center)
                        usleep(600_000)
                        return
                    }
                }
            }
        }
        throw Failure("workspace-pill button not found in window")
    }

    func openMenuItem(titled title: String) -> AXUIElement? {
        let matching = descendants(of: axApp, role: kAXMenuItemRole as String).filter {
            let t: String? = attribute($0, kAXTitleAttribute)
            guard t == title || t?.starts(with: title) == true else { return false }
            if let sizeVal: AXValue = attribute($0, kAXSizeAttribute) {
                var s = CGSize.zero
                AXValueGetValue(sizeVal, .cgSize, &s)
                return s.width > 10 && s.height > 10
            }
            return true
        }
        return matching.first
    }

    func clickOpenMenuItem(titled title: String) throws {
        guard wait(for: { self.openMenuItem(titled: title) != nil }, timeout: 5) else {
            let allItems = descendants(of: axApp, role: kAXMenuItemRole as String).map { (elem: AXUIElement) -> String in
                let t: String = self.attribute(elem, kAXTitleAttribute) ?? "nil"
                var s = CGSize.zero
                if let sizeVal: AXValue = self.attribute(elem, kAXSizeAttribute) {
                    AXValueGetValue(sizeVal, .cgSize, &s)
                }
                return "\(t) (\(s.width)x\(s.height))"
            }
            throw Failure("open menu item '\(title)' not found (found menu items: \(allItems))")
        }
        guard let item = openMenuItem(titled: title) else {
            throw Failure("open menu item '\(title)' not found")
        }
        guard let itemPos: AXValue = attribute(item, kAXPositionAttribute),
              let itemSize: AXValue = attribute(item, kAXSizeAttribute) else {
            throw Failure("cannot get position/size for menu item '\(title)'")
        }
        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(itemPos, .cgPoint, &pos)
        AXValueGetValue(itemSize, .cgSize, &size)
        let center = CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
        try click(at: center)
        usleep(500_000)
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

    /// Rapid system key press via .cghidEventTap so menu shortcuts are recognized.
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

    func clickButton(titled title: String) throws {
        guard let btn = button(titled: title) else {
            throw Failure("button titled '\(title)' not found")
        }
        guard let btnPos: AXValue = attribute(btn, kAXPositionAttribute),
              let btnSize: AXValue = attribute(btn, kAXSizeAttribute) else {
            throw Failure("cannot get frame for button '\(title)'")
        }
        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(btnPos, .cgPoint, &pos)
        AXValueGetValue(btnSize, .cgSize, &size)
        let center = CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
        try click(at: center)
        usleep(400_000)
    }

    func focus() {
        guard let window = activeWindow() else { return }
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if let area = descendants(of: window, role: kAXTextAreaRole as String).first {
            AXUIElementSetAttributeValue(area, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
    }

    func setSize(_ size: CGSize, for window: AXUIElement? = nil) {
        guard let win = window ?? activeWindow() ?? windows().first else { return }
        var value = size
        if let axValue = AXValueCreate(.cgSize, &value) {
            AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, axValue)
        }
        usleep(100_000)
    }


    func setPosition(_ position: CGPoint, for window: AXUIElement? = nil) {
        guard let win = window ?? activeWindow() ?? windows().first else { return }
        var value = position
        if let axValue = AXValueCreate(.cgPoint, &value) {
            AXUIElementSetAttributeValue(win, kAXPositionAttribute as CFString, axValue)
        }
        usleep(100_000)
        focus()
    }
}

func hex(_ s: String) -> String {
    "\"\(s)\" [" + s.utf8.map { String(format: "%02x", $0) }.joined(separator: " ") + "]"
}

