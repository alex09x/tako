/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

//
//  TakoThemeTests.swift
//  Tako
//
//  Created by luca on 27.10.2025.
//

import AppKit
import XCTest

final class TakoThemeTests: TakoCustomConfigCase {
    override static var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    let windowTitle = "TakoThemeTests"
    private let lightTheme = "ui-chrome-light-\(UUID().uuidString)"
    private let darkTheme = "ui-chrome-dark-\(UUID().uuidString)"
    private var themeFiles: [URL] = []
    private var recordsQuickTerminalPixels = false

    override func setUp() async throws {
        try await super.setUp()
        let configPath = try XCTUnwrap(try takoApplication().launchEnvironment["TAKO_CONFIG_PATH"])
        let directory = URL(fileURLWithPath: configPath).deletingLastPathComponent().appendingPathComponent("themes")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Two minimal test-owned themes make both sides of the appearance
        // contract independent of installed theme packs and user preferences.
        for (name, colors) in [(lightTheme, "background=f7f7f7\nforeground=202020\n"),
                               (darkTheme, "background=14100e\nforeground=e8e2d9\n")] {
            let file = directory.appendingPathComponent(name)
            themeFiles.append(file)
            try colors.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    override func tearDown() async throws {
        logTestProgress("theme teardown begin")
        defer {
            logTestProgress("theme files cleanup begin")
            for file in themeFiles { try? FileManager.default.removeItem(at: file) }
            logTestProgress("theme files cleanup end")
        }
        try await super.tearDown()
        logTestProgress("theme teardown superclass returned")
    }

    private func assertTitlebarAppearance(
        _ appearance: XCUIDevice.Appearance,
        for app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        // CustomTabGroup orders sibling windows out. Never photograph a
        // cached native title element, or an invisible sibling's AX tree.
        let windows = app.windows.allElementsBoundByIndex.filter {
            $0.textViews.firstMatch.isHittable
        }
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Visible chrome accessibility hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        XCTAssertFalse(windows.isEmpty, "A visible terminal window is required", file: file, line: line)
        for window in windows {
            let strip = window.descendants(matching: .any)["tab-bar"]
            XCTAssertTrue(strip.exists, file: file, line: line)
            XCTAssertEqual(strip.frame.height, 38, accuracy: 1, file: file, line: line)
            let attachment = XCTAttachment(screenshot: window.screenshot())
            attachment.name = "Chrome and terminal, expected \(appearance)"
            attachment.lifetime = .keepAlways
            add(attachment)

            // TabBarView.draw fills Palette.bar (#14100e) regardless of
            // window-theme or titlebar style. The top 2pt are above all pill
            // content and buttons. Sample fixed places, not favorable pixels.
            for x in [CGFloat(0.25), 0.5, 0.75] {
                let color = try backgroundColor(of: strip, x: x, y: 2 / strip.frame.height,
                                                file: file, line: line)
                XCTAssertEqual(color.redComponent, 20 / 255, accuracy: 0.03, file: file, line: line)
                XCTAssertEqual(color.greenComponent, 16 / 255, accuracy: 0.03, file: file, line: line)
                XCTAssertEqual(color.blueComponent, 14 / 255, accuracy: 0.03, file: file, line: line)
            }

            // Theme changes remain observable on the real terminal and on
            // split-pane drag chrome, whose fill is surface.theme.background.
            // The fixed dark strip alone cannot prove a light/dark reload.
            let terminals = window.textViews.allElementsBoundByIndex.filter { $0.isHittable }
            XCTAssertFalse(terminals.isEmpty, "A live terminal is required", file: file, line: line)
            let handles = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'pane-drag-handle-'"))
                .allElementsBoundByIndex.filter { $0.isHittable }
            for element in terminals + handles {
                XCTAssertGreaterThanOrEqual(element.frame.minY, strip.frame.maxY - 1, file: file, line: line)
                // Bottom-right terminal background avoids prompt/cursor ink;
                // the handle's left quarter avoids its centered grip.
                let isHandle = element.identifier.hasPrefix("pane-drag-handle-")
                let color = try backgroundColor(of: element, x: isHandle ? 0.25 : 0.9,
                                                y: isHandle ? 0.25 : 0.9, file: file, line: line)
                if appearance == .dark {
                    XCTAssertLessThanOrEqual(color.luminance, 0.5,
                                             "Expected dark theme on \(element.identifier): \(color)", file: file, line: line)
                } else {
                    XCTAssertGreaterThanOrEqual(color.luminance, 0.5,
                                                "Expected light theme on \(element.identifier): \(color)", file: file, line: line)
                }
            }
        }
    }

    private func backgroundColor(of element: XCUIElement, x: CGFloat, y: CGFloat,
                                 file: StaticString, line: UInt) throws -> NSColor {
        let image = element.screenshot().image
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil), file: file, line: line)
        let pixelX = Int(CGFloat(cg.width - 1) * x)
        let pixelY = Int(CGFloat(cg.height - 1) * y)
        let color = try capturedColor(in: cg, x: pixelX, y: pixelY, file: file, line: line)
        if recordsQuickTerminalPixels {
            let attachment = XCTAttachment(image: image)
            attachment.name = "Sampled \(element.identifier) at \(pixelX),\(pixelY)"
            attachment.lifetime = .keepAlways
            add(attachment)
            logTestProgress("pixel \(element.identifier) frame=\(element.frame) image=\(cg.width)x\(cg.height) profile=\(String(describing: cg.colorSpace)) alpha=\(cg.alphaInfo.rawValue) point=\(x),\(y) pixel=\(pixelX),\(pixelY) normalizedSRGB=\(color)")
            if element.identifier == "tab-bar" {
                for row in 0..<min(10, cg.height) {
                    let sample = try? capturedColor(in: cg, x: pixelX, y: row, file: file, line: line)
                    logTestProgress("fixed strip row \(row): \(String(describing: sample))")
                }
            }
        }
        return color
    }

    private func capturedColor(in image: CGImage, x: Int, y: Int,
                               file: StaticString, line: UInt) throws -> NSColor {
        // colorAt returns a calibrated NSColor even for tagged screenshot
        // bytes. Normalize through Core Graphics once, then read known sRGB.
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB), file: file, line: line)
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
            file: file, line: line)
        defer { withExtendedLifetime(context) {} }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data, file: file, line: line).assumingMemoryBound(to: UInt8.self)
        let offset = y * context.bytesPerRow + x * 4
        let divisor = CGFloat(max(bytes[offset + 3], 1))
        return NSColor(srgbRed: CGFloat(bytes[offset]) / divisor,
                       green: CGFloat(bytes[offset + 1]) / divisor,
                       blue: CGFloat(bytes[offset + 2]) / divisor,
                       alpha: CGFloat(bytes[offset + 3]) / 255)
    }

    func testCapturedPixelsKeepTheirDeclaredColorSpace() throws {
        for (name, red) in [(CGColorSpace.sRGB, UInt8(20)), (CGColorSpace.displayP3, UInt8(19))] {
            let bytes: [UInt8] = [red, 16, 14, 255, 247, 247, 247, 255,
                                  255, 0, 0, 255, 0, 0, 255, 255]
            let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
            let image = try XCTUnwrap(CGImage(width: 2, height: 2, bitsPerComponent: 8,
                bitsPerPixel: 32, bytesPerRow: 8, space: try XCTUnwrap(CGColorSpace(name: name)),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
            let bar = try capturedColor(in: image, x: 0, y: 0, file: #filePath, line: #line)
            XCTAssertEqual(bar.redComponent, 20 / 255, accuracy: 1 / 255)
            XCTAssertEqual(bar.greenComponent, 16 / 255, accuracy: 1 / 255)
            XCTAssertEqual(bar.blueComponent, 14 / 255, accuracy: 1 / 255)
            let blue = try capturedColor(in: image, x: 1, y: 1, file: #filePath, line: #line)
            XCTAssertEqual(blue.redComponent, 0, accuracy: 1 / 255)
            XCTAssertEqual(blue.blueComponent, 1, accuracy: 1 / 255)
        }
    }

    @MainActor
    func testIssue8282() async throws {
        try updateConfig("title=\(windowTitle) \n theme=light:\(lightTheme),dark:\(darkTheme)")
        XCUIDevice.shared.appearance = .dark

        let app = try takoApplication()
        app.launch()
        try assertTitlebarAppearance(.dark, for: app)
        // create a split
        app.groups["Terminal pane"].typeKey("d", modifierFlags: .command)
        // reload config
        app.typeKey(",", modifierFlags: [.command, .shift])
        try await Task.sleep(for: .seconds(0.5))
        // create a new window
        app.typeKey("n", modifierFlags: [.command])
        try assertTitlebarAppearance(.dark, for: app)
    }

    @MainActor
    func testLightTransparentWindowThemeWithDarkTerminal() async throws {
        // window-theme is an unknown key in Tako. Light system chrome with
        // an explicitly dark terminal is the supported equivalent fixture.
        try updateConfig("title=\(windowTitle) \n theme=\(darkTheme)")
        XCUIDevice.shared.appearance = .light
        let app = try takoApplication()
        app.launch()
        try await Task.sleep(for: .seconds(0.5))
        try assertTitlebarAppearance(.dark, for: app)
    }

    @MainActor
    func testLightNativeWindowThemeWithDarkTerminal() async throws {
        try updateConfig("title=\(windowTitle) \n theme=\(darkTheme) \n macos-titlebar-style = native")
        XCUIDevice.shared.appearance = .light
        let app = try takoApplication()
        app.launch()
        // "native" no longer installs an AppKit title field: the own strip
        // stays branded dark and the chosen terminal theme stays dark too.
        try assertTitlebarAppearance(.dark, for: app)
    }

    @MainActor
    func testReloadingLightTransparentWindowTheme() async throws {
        try updateConfig("title=\(windowTitle) \n ")
        let app = try takoApplication()
        app.launch()
        // default dark theme
        try assertTitlebarAppearance(.dark, for: app)
        // Select the actual theme with the supported theme key. The obsolete
        // window-theme override opened an error dialog instead of reloading.
        try updateConfig("title=\(windowTitle) \n theme=\(lightTheme)")
        // reload config
        app.typeKey(",", modifierFlags: [.command, .shift])
        try await Task.sleep(for: .seconds(0.5))
        try assertTitlebarAppearance(.light, for: app)
    }

    @MainActor
    func testSwitchingSystemTheme() async throws {
        try updateConfig("title=\(windowTitle) \n theme=light:\(lightTheme),dark:\(darkTheme)")
        XCUIDevice.shared.appearance = .dark
        let app = try takoApplication()
        app.launch()
        try assertTitlebarAppearance(.dark, for: app)
        XCUIDevice.shared.appearance = .light
        try await Task.sleep(for: .seconds(0.5))
        try assertTitlebarAppearance(.light, for: app)
    }

    @MainActor
    func testReloadFromLightWindowThemeToDefaultTheme() async throws {
        try updateConfig("title=\(windowTitle) \n theme=\(lightTheme)")
        XCUIDevice.shared.appearance = .light
        let app = try takoApplication()
        app.launch()
        try assertTitlebarAppearance(.light, for: app)
        try updateConfig("title=\(windowTitle) \n ")
        // reload config
        app.typeKey(",", modifierFlags: [.command, .shift])
        try await Task.sleep(for: .seconds(0.5))
        try assertTitlebarAppearance(.dark, for: app)
    }

    @MainActor
    func testReloadFromDefaultThemeToDarkWindowTheme() async throws {
        try updateConfig("title=\(windowTitle) \n ")
        XCUIDevice.shared.appearance = .light
        let app = try takoApplication()
        app.launch()
        try assertTitlebarAppearance(.dark, for: app)
        try updateConfig("title=\(windowTitle) \n theme=\(darkTheme)")
        // reload config
        app.typeKey(",", modifierFlags: [.command, .shift])
        try await Task.sleep(for: .seconds(0.5))
        try assertTitlebarAppearance(.dark, for: app)
    }

    @MainActor
    func testReloadingFromDarkThemeToSystemLightTheme() async throws {
        try updateConfig("title=\(windowTitle) \n theme=\(darkTheme)")
        XCUIDevice.shared.appearance = .light
        let app = try takoApplication()
        app.launch()
        try assertTitlebarAppearance(.dark, for: app)
        try updateConfig("title=\(windowTitle) \n theme=light:\(lightTheme),dark:\(darkTheme)")
        // reload config
        app.typeKey(",", modifierFlags: [.command, .shift])
        try await Task.sleep(for: .seconds(0.5))
        try assertTitlebarAppearance(.light, for: app)
    }

    @MainActor
    func testQuickTerminalThemeChange() async throws {
        recordsQuickTerminalPixels = true
        try updateConfig("title=\(windowTitle) \n theme=light:\(lightTheme),dark:\(darkTheme) \n confirm-close-surface=false")
        XCUIDevice.shared.appearance = .light
        let app = try takoApplication()
        app.launch()
        // close default window
        app.typeKey("w", modifierFlags: [.command])
        XCTAssertTrue(app.windows.firstMatch.waitForNonExistence(timeout: 1),
                      "Close the ordinary window before inspecting Quick Terminal")
        // open quick terminal
        app.menuBarItems["View"].firstMatch.click()
        app.menuItems["Quick Terminal"].firstMatch.click()
        logTestProgress("quick light assertion begin")
        try assertTitlebarAppearance(.light, for: app)
        logTestProgress("quick light assertion end; dark appearance begin")
        XCUIDevice.shared.appearance = .dark
        try await Task.sleep(for: .seconds(0.5))
        logTestProgress("quick dark assertion begin")
        try assertTitlebarAppearance(.dark, for: app)
        logTestProgress("quick dark assertion end")
    }
}
