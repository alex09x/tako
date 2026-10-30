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
import Testing
@testable import Tako

@MainActor
@Suite(.serialized)
struct ClipboardPasteDialogTests {
    @Test(arguments: ["Cancel", "Paste", "Always Paste"])
    func pasteConfirmationUsesTerminalDialogAndHonorsItsButtons(choice: String) async throws {
        let surface = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        surface.selfTestCapturing = true
        let controller = BaseTerminalController(Tako.App(), surfaceTree: .init(view: surface))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        controller.window = window
        controller.focusedSurface = surface
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        controller.pasteGuardConfigFile = KeybindConfigFile(configPath: dir.appendingPathComponent("config").path)
        defer { surface.close(); window.close(); try? FileManager.default.removeItem(at: dir) }

        surface.core.feed(bytes: Data("\u{1b}]133;P\u{07}".utf8))
        let payload = "brew install helix\necho done\n"
        surface.handlePaste(payload)
        for _ in 0..<1000 where TerminalDialogView.pending(in: window) == nil { await Task.yield() }
        let dialog = try #require(TerminalDialogView.pending(in: window))
        #expect(window.attachedSheet == nil)
        #expect(dialog.buttons.map(\.title) == ["Cancel", "Always Paste", "Paste"])
        #expect(dialog.lines.flatMap(\.runs).map(\.text).joined().contains("brew install helix"))
        #expect(surface.selfTestBytes.isEmpty)
        #expect(dialog.press(choice))
        for _ in 0..<1000 where controller.clipboardConfirmation != nil { await Task.yield() }
        #expect(controller.clipboardConfirmation == nil)
        if choice == "Cancel" {
            #expect(surface.selfTestBytes.isEmpty)
        } else {
            #expect(TerminalTestSupport.waitUntil(timeout: 2) { !surface.selfTestBytes.isEmpty })
            #expect(String(decoding: surface.selfTestBytes, as: UTF8.self).contains("brew install helix"))
        }
        #expect(surface.safePaste == (choice != "Always Paste"))
    }
}
