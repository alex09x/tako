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

// MARK: - PTY and Command Execution

func makeDriverWorkDirectory() throws -> URL {
    var template = Array("/private/tmp/tkw.XXXXXX".utf8CString)
    guard mkdtemp(&template) != nil else { throw Failure("no private driver work directory: errno \(errno)") }
    return URL(fileURLWithPath: String(cString: template), isDirectory: true)
}

struct DriverLaunchClock {
    private let started = ProcessInfo.processInfo.systemUptime
    private var previous = ProcessInfo.processInfo.systemUptime

    mutating func mark(_ phase: String) {
        let now = ProcessInfo.processInfo.systemUptime
        print(String(format: "[timing] launch %@=%.3fs total=%.3fs", phase, now - previous, now - started))
        previous = now
    }
}

/// A launch owns a fresh file and a completion suffix; an old or partial
/// write must never stand in for this launch's first shell command.
struct ShellBootstrapWitness {
    let token = UUID().uuidString
    var fileName: String { "bootstrap-env-\(token)" }
    var suffix: String { "|\(token)" }

    func receipt(from contents: String) -> String? {
        guard contents.hasSuffix(suffix) else { return nil }
        return String(contents.dropLast(suffix.count))
    }

    /// Source the same printf in the actual shell, through a short HID
    /// command. A fresh 0600 script avoids typing its long variable list.
    func writeCommand(in work: URL) throws -> URL {
        var template = Array(work.appendingPathComponent("b.XXXXXX").path.utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else { throw Failure("no private bootstrap script: errno \(errno)") }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let command = "printf '%s|%s|%s|%s|%s|%s' \"$HOME\" \"$XDG_DATA_HOME\" \"$HISTFILE\" \"$TAKO_SESSIONS_HOME\" \"$ZDOTDIR\" '\(token)' > '\(work.appendingPathComponent(fileName).path)'\n"
        try file.write(contentsOf: Data(command.utf8))
        try file.close()
        return URL(fileURLWithPath: String(cString: template))
    }
}

extension Driver {
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
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "TAKO_SURFACE_ID")
        environment.removeValue(forKey: "TAKO_SOCKET")
        process.environment = environment
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

    /// The file's contents once the shell has written them.
    func file(_ name: String, timeout: TimeInterval = 10) throws -> String {
        let url = work.appendingPathComponent(name)
        var text: String?
        _ = wait(for: {
            text = try? String(contentsOf: url, encoding: .utf8)
            return text != nil
        }, timeout: timeout)
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

    /// Every static text in the front window, through accessibility.
    func staticTexts() -> [String] {
        guard let window = activeWindow() else { return [] }
        return descendants(of: window, role: kAXStaticTextRole as String).compactMap {
            attribute($0, kAXValueAttribute) as String?
        }
    }

    /// The terminal's selected text, through accessibility.
    func selectedText() -> String {
        guard let window = activeWindow(),
              let area = descendants(of: window, role: kAXTextAreaRole as String).first,
              let text: String = attribute(area, kAXSelectedTextAttribute)
        else { return "" }
        return text
    }

    /// What the terminal shows, as its accessibility value: the screen and scrollback.
    func screenText() -> String {
        guard let window = activeWindow(),
              let area = descendants(of: window, role: kAXTextAreaRole as String).first,
              let text: String = attribute(area, kAXValueAttribute)
        else { return "" }
        return text
    }

    /// Every terminal's text in another instance's windows.
    func screenTexts(ofPid other: pid_t) -> [String] {
        let app = AXUIElementCreateApplication(other)
        let windows = (attribute(app, kAXWindowsAttribute) as [AXUIElement]?) ?? []
        return windows.flatMap { descendants(of: $0, role: kAXTextAreaRole as String) }
            .compactMap { attribute($0, kAXValueAttribute) as String? }
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
        // Quoted: the build folder can have a space in it ("/Volumes/Volume 1/...").
        let ctl = "'\(appURL.path)/Contents/MacOS/takoctl' --bundle-id \(bundleID)"
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
        // Quoted: the build folder can have a space in it ("/Volumes/Volume 1/...").
        let ctl = "'\(appURL.path)/Contents/MacOS/takoctl' --bundle-id \(bundleID)"
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

    /// List all workspaces discovered via takoctl.
    func workspaceList() throws -> [[String: Any]] {
        let ctl = "\(appURL.path)/Contents/MacOS/takoctl --bundle-id \(bundleID)"
        let wsJson = try exec("\(ctl) workspace list --json")
        guard let data = wsJson.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else {
            throw Failure("could not parse workspace list JSON: \(wsJson)")
        }
        if let list = obj as? [[String: Any]] {
            return list
        }
        if let dict = obj as? [String: Any] {
            let res = (dict["result"] as? [String: Any]) ?? dict
            if let list = res["workspaces"] as? [[String: Any]] {
                return list
            }
        }
        throw Failure("could not parse workspace list JSON: \(wsJson)")
    }

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
}
