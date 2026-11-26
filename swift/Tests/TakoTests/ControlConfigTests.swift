/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Testing
@testable import Tako

/// `takoctl config`: settings read and written through the file Settings
/// writes, every line the user wrote kept, nothing Settings would refuse.
@MainActor @Suite(.serialized)
struct ControlConfigTests {
    private func sandbox(_ text: String) throws -> (ControlConfig, String, () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tako-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("config").path
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        return (ControlConfig(file: KeybindConfigFile(configPath: path)), path,
                { try? FileManager.default.removeItem(at: dir) })
    }

    private func file(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }

    private func set(_ pairs: [(String, String)], add: Bool = false) -> [String: JSON] {
        ["action": .string(add ? "add" : "set"),
         "settings": .array(pairs.map { .object(["key": .string($0.0), "value": .string($0.1)]) })]
    }

    private func keys(_ action: String, _ keys: [String]) -> [String: JSON] {
        ["action": .string(action), "keys": .array(keys.map(JSON.string))]
    }

    private func entry(_ result: [String: JSON], _ key: String) -> [String: JSON]? {
        result["settings"]?.array?.compactMap(\.object).first { $0["key"]?.string == key }
    }

    @Test func setReplacesInPlaceAndKeepsEveryOtherLine() throws {
        let (config, path, cleanup) = try sandbox("# mine\nfont-size = 12\nkeybind = cmd+k=clear_screen\n")
        defer { cleanup() }
        let result = try config.run(set([("font-size", "13.5"), ("cursor-style", "bar")]))
        #expect(entry(result, "font-size")?["value"]?.string == "13.5", "fractional sizes, as Settings allows")
        #expect(entry(result, "font-size")?["set"]?.bool == true)
        #expect(file(path) == "# mine\nfont-size = 13.5\nkeybind = cmd+k=clear_screen\ncursor-style = bar\n")
    }

    @Test func getAnswersTheFilesValueOrSettingsDefault() throws {
        let (config, _, cleanup) = try sandbox("copy-on-select = clipboard\n")
        defer { cleanup() }
        let result = try config.run(keys("get", ["copy-on-select", "safe-paste", "title"]))
        #expect(entry(result, "copy-on-select")?["value"]?.string == "clipboard")
        let paste = try #require(entry(result, "safe-paste"))
        #expect(paste["value"]?.string == "true" && paste["set"]?.bool == false && paste["type"]?.string == "boolean")
        #expect(entry(result, "title")?["value"] == .null, "a key Settings does not show has no default here")
        let choice = try #require(entry(try config.run(keys("get", ["cursor-style"])), "cursor-style"))
        #expect(choice["options"]?.array?.compactMap(\.string) == ["block", "bar", "underline"])
    }

    @Test func anAliasIsWrittenUnderItsCanonicalName() throws {
        let (config, path, cleanup) = try sandbox("workspace-inherit-window-frame = true\n")
        defer { cleanup() }
        let read = try config.run(keys("get", ["workspace-inherit-window-frame"]))
        #expect(entry(read, "workspace-sync-window-frame")?["value"]?.string == "true")
        _ = try config.run(set([("workspace-sync-window-frame", "false")]))
        #expect(file(path) == "workspace-sync-window-frame = false\n")
    }

    @Test func theCanonicalNameWinsOverAnAliasAsInSettings() throws {
        for text in ["workspace-sync-window-frame = false\nworkspace-inherit-window-frame = true\n",
                     "workspace-inherit-window-frame = true\nworkspace-sync-window-frame = false\n"] {
            let (config, _, cleanup) = try sandbox(text)
            defer { cleanup() }
            let settings = KeybindConfigFile(configPath: try #require(config.file.configPath))
            let shown = settings.getSettingValue(for: try #require(TerminalSettingRegistry.setting(for: "workspace-sync-window-frame")))
            #expect(shown == "false", "what Settings shows")
            for name in ["workspace-sync-window-frame", "workspace-inherit-window-frame"] {
                let read = try config.run(keys("get", [name]))
                #expect(entry(read, "workspace-sync-window-frame")?["value"]?.string == shown, "\(name) in \(text)")
            }
        }
    }

    @Test func boldIsBrightIsWrittenAsTrueOrFalse() throws {
        let (config, path, cleanup) = try sandbox("font-size = 12\n")
        defer { cleanup() }
        _ = try config.run(set([("bold-is-bright", "true")]))
        #expect(file(path) == "font-size = 12\nbold-is-bright = true\n")
        _ = try config.run(set([("bold-is-bright", "false")]))
        #expect(file(path) == "font-size = 12\nbold-is-bright = false\n")
        // Quoted, as the config parser reads it: one layer of either quote.
        for quoted in ["\"true\"", "'true'"] {
            _ = try config.run(set([("bold-is-bright", quoted)]))
            #expect(file(path) == "font-size = 12\nbold-is-bright = \(quoted)\n")
            #expect(TerminalTheme.parse(config: file(path)).boldIsBright, "\(quoted) is read as true")
        }
    }

    @Test func repeatableSettingsAddLinesAndUnsetRemovesThemAll() throws {
        let (config, path, cleanup) = try sandbox("keybind = cmd+k=clear_screen\n")
        defer { cleanup() }
        let added = try config.run(set([("keybind", "cmd+j=jump_to_prompt:-1")], add: true))
        #expect(entry(added, "keybind")?["values"]?.array?.compactMap(\.string)
            == ["cmd+k=clear_screen", "cmd+j=jump_to_prompt:-1"])
        #expect(throws: ControlError.self) { try config.run(set([("font-size", "14")], add: true)) }
        _ = try config.run(keys("unset", ["keybind"]))
        #expect(!file(path).contains("keybind"))
        #expect(entry(try config.run(keys("get", ["keybind"])), "keybind")?["values"]?.array?.isEmpty == true)
    }

    @Test func valuesSettingsWouldRefuseAreRefusedAndTheFileIsUntouched() throws {
        let original = "font-size = 12\n"
        let (config, path, cleanup) = try sandbox(original)
        defer { cleanup() }
        let refused: [(String, String, String)] = [
            ("font-size", "99", "between 6 and 72"),
            ("font-size", "big", "between 6 and 72"),
            ("safe-paste", "yes", "expected true or false"),
            ("bold-is-bright", "yes", "expected true or false"),
            ("bold-is-bright", "\"yes\"", "expected true or false"),
            ("cursor-style", "triangle", "invalid value triangle"),
            ("tab-status-color-done", "green", "#rrggbb"),
            ("no-such-setting", "1", "unknown setting"),
            ("title", "two\nlines", "one line"),
        ]
        for (key, value, message) in refused {
            do {
                // A good setting first: one bad one refuses the whole request.
                _ = try config.run(set([("cursor-style", "bar"), (key, value)]))
                Issue.record("\(key) = \(value) was accepted")
            } catch let error as ControlError {
                #expect(error.message.contains(message), "\(error.message)")
            }
        }
        #expect(file(path) == original)
        #expect(throws: ControlError.self) { try config.run(keys("get", ["fontsize"])) }
        #expect(throws: ControlError.self) { try config.run(["action": .string("wipe")]) }
    }

    private func shortcut(_ op: String, _ name: String? = nil, _ trigger: String? = nil,
                          force: Bool = false) -> [String: JSON] {
        var args: [String: JSON] = ["action": .string("shortcut"), "op": .string(op)]
        if let name { args["name"] = .string(name) }
        if let trigger { args["trigger"] = .string(trigger) }
        if force { args["force"] = .bool(true) }
        return args
    }

    private func chord(_ result: [String: JSON], _ action: String) -> [String: JSON]? {
        result["shortcuts"]?.array?.compactMap(\.object).first { $0["action"]?.string == action }
    }

    @Test func shortcutsAreBoundClearedAndResetAsSettingsDoes() throws {
        let (config, path, cleanup) = try sandbox("font-size = 12\n")
        defer { cleanup() }
        let list = try config.run(shortcut("list"))
        let newTab = try #require(chord(list, "new_tab"))
        #expect(newTab["custom"]?.bool == false && newTab["trigger"] == newTab["default"])

        let bound = try config.run(shortcut("set", "goto_tab:3", "ctrl+opt+3"))
        #expect(chord(bound, "goto_tab:3")?["trigger"]?.string == "ctrl+opt+3")
        #expect(chord(bound, "goto_tab:3")?["custom"]?.bool == true)
        #expect(file(path) == "font-size = 12\nkeybind = ctrl+opt+3=goto_tab:3\n")

        _ = try config.run(shortcut("unset", "goto_tab:3"))
        #expect(file(path) == "font-size = 12\n")
        _ = try config.run(shortcut("set", "new_tab", "ctrl+opt+t"))
        _ = try config.run(shortcut("reset"))
        #expect(file(path) == "font-size = 12\n", "reset drops every chord and nothing else")
    }

    @Test func aChordInUseOrNotAChordIsRefused() throws {
        let original = "font-size = 12\n"
        let (config, path, cleanup) = try sandbox(original)
        defer { cleanup() }
        let taken = try #require(chord(try config.run(shortcut("list")), "new_tab")?["trigger"]?.string)
        do {
            _ = try config.run(shortcut("set", "find_all", taken))
            Issue.record("\(taken) was taken from new_tab without --force")
        } catch let error as ControlError {
            #expect(error.message.contains("already runs New Tab"), "\(error.message)")
        }
        #expect(file(path) == original)
        for (name, trigger) in [("no_such_action", "cmd+9"), ("new_tab", ""), ("new_tab", "cmd+t=quit"), ("new_tab", "cmd+\nq")] {
            #expect(throws: ControlError.self) { try config.run(shortcut("set", name, trigger)) }
        }
        #expect(file(path) == original)
        _ = try config.run(shortcut("set", "find_all", taken, force: true))
        #expect(file(path).contains("keybind = \(taken)=find_all"))
    }

    @Test func listCoversEveryKnownKeyAndFilters() throws {
        let (config, path, cleanup) = try sandbox("")
        defer { cleanup() }
        let all = try config.run(["action": .string("list")])
        let names = Set(all["settings"]?.array?.compactMap { $0.object?["key"]?.string } ?? [])
        #expect(names.isSuperset(of: ["font-size", "session-persistence", "remote-control", "keybind", "status-show"]))
        let fonts = try config.run(["action": .string("list"), "filter": .string("font-")])
        #expect(fonts["settings"]?.array?.allSatisfy { $0.object?["key"]?.string?.contains("font-") == true } == true)
        #expect(try config.run(["action": .string("path")])["path"]?.string == path)
    }
}
