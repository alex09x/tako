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

@Suite
@MainActor
struct KeybindConfigFileTests {
    private func makeTemporaryConfigFile(initialContent: String = "") throws -> URL {
        let tempUrl = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("config")
        try initialContent.write(to: tempUrl, atomically: true, encoding: .utf8)
        return tempUrl
    }

    @Test
    func misreadsEqualKeyTriggerIsFixed() throws {
        let tempUrl = try makeTemporaryConfigFile(initialContent: """
        keybind = cmd+opt+==equalize_splits
        keybind = cmd+==increase_font_size:1
        keybind = ctrl+d=new_split:right
        """)
        defer { try? FileManager.default.removeItem(at: tempUrl) }

        let configFile = KeybindConfigFile(configPath: tempUrl.path)
        #expect(configFile.customOverrides["equalize_splits"] == "cmd+opt+=")
        #expect(configFile.customOverrides["increase_font_size:1"] == "cmd+=")
        #expect(configFile.customOverrides["new_split:right"] == "ctrl+d")
    }

    @Test
    func setAndRemoveKeybindWithEqualsTrigger() throws {
        let tempUrl = try makeTemporaryConfigFile(initialContent: "# Initial\n")
        defer { try? FileManager.default.removeItem(at: tempUrl) }

        let configFile = KeybindConfigFile(configPath: tempUrl.path)
        let setSuccess = configFile.setKeybind(action: "equalize_splits", trigger: "cmd+opt+=")
        #expect(setSuccess == true)
        #expect(configFile.customOverrides["equalize_splits"] == "cmd+opt+=")

        let content = try String(contentsOfFile: tempUrl.path, encoding: .utf8)
        #expect(content.contains("keybind = cmd+opt+==equalize_splits"))

        let removeSuccess = configFile.removeKeybind(action: "equalize_splits")
        #expect(removeSuccess == true)
        #expect(configFile.customOverrides["equalize_splits"] == nil)

        let updatedContent = try String(contentsOfFile: tempUrl.path, encoding: .utf8)
        #expect(!updatedContent.contains("equalize_splits"))
    }

    @Test
    func explicitConfigPathDependency() throws {
        let tempUrl = try makeTemporaryConfigFile(initialContent: "keybind = ctrl+t=new_tab\n")
        defer { try? FileManager.default.removeItem(at: tempUrl) }

        let configFile = KeybindConfigFile(configPath: tempUrl.path)
        #expect(configFile.configPath == tempUrl.path)
        #expect(configFile.customOverrides["new_tab"] == "ctrl+t")
    }

    @Test
    func unresolvableConfigPathFailsGracefully() {
        // Without explicit path, AppDelegate, or TAKO_CONFIG_PATH in environment:
        let previousEnv = ProcessInfo.processInfo.environment["TAKO_CONFIG_PATH"]
        if previousEnv != nil {
            unsetenv("TAKO_CONFIG_PATH")
        }
        defer {
            if let previousEnv {
                setenv("TAKO_CONFIG_PATH", previousEnv, 1)
            }
        }

        let configFile = KeybindConfigFile(configPath: "")
        if configFile.configPath == nil {
            #expect(configFile.setKeybind(action: "new_tab", trigger: "cmd+t") == false)
            #expect(configFile.removeKeybind(action: "new_tab") == false)
            #expect(configFile.resetAllKeybinds() == false)
        }
    }
}
