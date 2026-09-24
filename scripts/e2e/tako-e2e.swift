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
    static let d: CGKeyCode = 2
    static let w: CGKeyCode = 13
    static let n: CGKeyCode = 45
    static let v: CGKeyCode = 9
    static let c: CGKeyCode = 8
    static let u: CGKeyCode = 32
    static let q: CGKeyCode = 12
    static let comma: CGKeyCode = 43
    static let rightBracket: CGKeyCode = 30
}

// MARK: - Driver

final class Driver {
    let appURL: URL
    let work: URL
    private(set) var pid: pid_t = 0
    private let source = CGEventSource(stateID: .hidSystemState)

    init(app: URL) throws {
        appURL = app
        work = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("tako-e2e-\(UUID().uuidString.prefix(8).lowercased())")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    // A path the shell can be told to write to. Lowercase and short, so it
    // is quick to type and needs nothing but plain keys.
    func path(_ name: String) -> String { work.appendingPathComponent(name).path }

    func launch(config: String = "") throws {
        let configURL = work.appendingPathComponent("config")
        try config.write(to: configURL, atomically: true, encoding: .utf8)
        let before = Set(running().map(\.processIdentifier))
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        // -n: a new instance, never somebody's running Tako.
        open.arguments = ["-n", "--env", "TAKO_CONFIG_PATH=\(configURL.path)", appURL.path]
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
        // The shell needs a moment to print its first prompt; typing before it
        // reads its terminal would still work, but the check below makes the
        // difference between "slow" and "broken" visible.
        try run("true")
        usleep(300_000)
    }

    func quit() {
        guard pid != 0 else { return }
        kill(pid, SIGKILL)
        pid = 0
    }

    private func running() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.executableURL?.path.hasPrefix(appURL.path) == true
        }
    }

    // MARK: typing

    func key(_ code: CGKeyCode, _ flags: CGEventFlags = []) {
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            else { continue }
            event.flags = flags
            event.postToPid(pid)
            usleep(4_000)
        }
        usleep(4_000)
    }

    func type(_ text: String) throws {
        for ch in text {
            guard let (code, shift) = keyCodes[ch] else { throw Failure("no key for \(ch)") }
            key(code, shift ? .maskShift : [])
        }
    }

    /// Type a command line and press Return.
    func run(_ command: String) throws {
        try type(command)
        key(Key.returnKey)
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
            throw Failure("the shell never wrote \(name): what was typed did not reach it")
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
            for button in descendants(of: window, role: kAXButtonRole as String)
            where (attribute(button, kAXTitleAttribute) as String?) == title {
                return button
            }
        }
        return nil
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

    func setSize(_ size: CGSize) {
        guard let window = windows().first else { return }
        var value = size
        if let axValue = AXValueCreate(.cgSize, &value) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, axValue)
        }
    }
}

func hex(_ s: String) -> String {
    "\"\(s)\" [" + s.utf8.map { String(format: "%02x", $0) }.joined(separator: " ") + "]"
}

// MARK: - Scenarios

typealias Scenario = (name: String, why: String, body: (Driver) throws -> Void)

let scenarios: [Scenario] = [
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
        try d.launch(config: "font-size = 12\n")
        try d.run("tput cols > \(d.path("small"))")
        let small = Int(try d.file("small").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        d.quit()
        try d.launch(config: "font-size = 24\n")
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
            try d.launch(config: config)
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
let previouslyFront = NSWorkspace.shared.frontmostApplication
var failed = 0
for scenario in scenarios where wanted.isEmpty || wanted.contains(scenario.name) {
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
