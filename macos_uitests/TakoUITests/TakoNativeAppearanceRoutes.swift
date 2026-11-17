/*
 * tako — Native Settings › Terminal Appearance routes for UI tests
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import XCTest

/// How a person reaches a level's themes now: a sidebar row's context menu ›
/// «Appearance ▸» (DesktopAppearanceMenu) › «All Themes…» or «Customize…», which
/// open native Settings › Terminal Appearance at that row's level, with the draft
/// editor (DesktopThemeDraftEditor) for «Customize…» or «New Theme…».
///
/// While Settings is open its scrim and panel cover nearly the whole window, so a
/// live preview is read from the pane's own renderer (`takoctl screenshot`, drawn
/// from the pane's current theme and font, not from the screen); with Settings
/// closed the pane is read from the screen as before.
extension TakoScopedAppearanceHelpers {
    enum AppearanceEntry: String {
        case allThemes = "All Themes…"
        case customize = "Customize…"
    }

    static func settingsRoot(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["DesktopSettingsRoot"].firstMatch
    }

    /// The default workspace's header row.
    static func workspaceRow(in app: XCUIApplication) -> XCUIElement {
        openSidebar(in: app)
        return app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH[c] 'DEFAULT' OR label BEGINSWITH[c] 'DEFAULT'")).firstMatch
    }

    /// The session row of the tab holding `paneID` (the largest exact match).
    static func sessionRow(_ paneID: String, in app: XCUIApplication) -> XCUIElement {
        openSidebar(in: app)
        let query = app.descendants(matching: .any).matching(identifier: "session-tab-" + paneID.lowercased())
        XCTAssertTrue(query.firstMatch.waitForExistence(timeout: 5), "Missing exact session row for \(paneID)")
        return query.allElementsBoundByIndex.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
            ?? query.firstMatch
    }

    /// The row's «Appearance ▸ entry»; returns Settings' root once it is open.
    @discardableResult
    static func openAppearance(_ entry: AppearanceEntry, from row: XCUIElement, in app: XCUIApplication,
                               expectedPane: String? = nil,
                               file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        XCTAssertTrue(row.waitForExistence(timeout: 5), file: file, line: line)
        let clicked = describe(row)
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        let appearance = app.menuItems["Appearance"].firstMatch
        XCTAssertTrue(appearance.waitForExistence(timeout: 5),
                      "the row's Appearance submenu; " + menuDiagnostics(clicked: clicked, expectedPane: expectedPane, in: app),
                      file: file, line: line)
        appearance.hover()
        let item = app.menuItems[entry.rawValue].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "Appearance ▸ \(entry.rawValue)", file: file, line: line)
        item.click()
        let root = settingsRoot(in: app)
        XCTAssertTrue(root.waitForExistence(timeout: 5), "Settings › Terminal Appearance", file: file, line: line)
        return root
    }

    /// The row's (or terminal's) «Appearance ▸ Inherit · …»: drops that level's own appearance.
    static func inheritAppearance(from row: XCUIElement, in app: XCUIApplication,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(row.waitForExistence(timeout: 5), file: file, line: line)
        let clicked = describe(row)
        row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        let appearance = app.menuItems["Appearance"].firstMatch
        XCTAssertTrue(appearance.waitForExistence(timeout: 5),
                      "the Appearance submenu; " + menuDiagnostics(clicked: clicked, expectedPane: nil, in: app),
                      file: file, line: line)
        appearance.hover()
        let inherit = app.menuItems.matching(identifier: "DesktopAppearanceInherit").firstMatch
        XCTAssertTrue(inherit.waitForExistence(timeout: 5), "Appearance ▸ Inherit", file: file, line: line)
        XCTAssertTrue(inherit.title.hasPrefix("Inherit"), "Appearance ▸ \(inherit.title)", file: file, line: line)
        inherit.click()
    }

    private static func describe(_ element: XCUIElement) -> String {
        "id=\(element.identifier) type=\(element.elementType.rawValue) frame=\(element.frame)"
    }

    /// Diagnostics only, read when a menu did not show «Appearance»: what was clicked,
    /// where the expected pane's card is, and every menu item open at that moment.
    static func menuDiagnostics(clicked: String, expectedPane: String?, in app: XCUIApplication) -> String {
        var parts = ["clicked \(clicked)"]
        if let expectedPane {
            let card = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier CONTAINS[c] %@", "FloatingPane-", expectedPane))
                .firstMatch
            parts.append("expected pane \(expectedPane) card " + (card.exists ? describe(card) : "not found"))
        }
        let items = app.menuItems.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }
            .map { "\($0.title)|\($0.identifier)" }
        parts.append("open menu items [\(items.joined(separator: ", "))]")
        return parts.joined(separator: "; ")
    }

    /// The moved tab's stable identity, read from the live control tree (the tab
    /// whose panes include `paneID`). Needs `recordControlSocket()` first.
    func stableTabID(ofPane paneID: String) throws -> String {
        let socket = try String(contentsOf: testRoot.appendingPathComponent("control-socket"), encoding: .utf8)
        let hosts = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID)
        guard hosts.count == 1, let host = hosts.first?.bundleURL else {
            throw ObservationError.unavailable("Expected exactly one isolated host, found \(hosts.count)")
        }
        let process = Process(), output = Pipe()
        process.executableURL = host.appendingPathComponent("Contents/MacOS/takoctl")
        process.arguments = ["--bundle-id", Self.bundleID, "--socket", socket, "--json", "tree"]
        var environment = ProcessInfo.processInfo.environment
        for key in ["TAKO_SOCKET", "TAKO_SURFACE_ID", "TAKO_CLIENT", "TAKO_CLIENT_ID"] { environment.removeValue(forKey: key) }
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let windows = (response["result"] as? [String: Any])?["windows"] as? [[String: Any]] else {
            throw ObservationError.unavailable("takoctl tree failed: \(String(decoding: data.prefix(300), as: UTF8.self))")
        }
        let tabs = windows.flatMap { $0["tabs"] as? [[String: Any]] ?? [] }
        let owners = tabs.filter { tab in
            (tab["panes"] as? [[String: Any]] ?? []).contains { ($0["id"] as? String)?.lowercased() == paneID.lowercased() }
        }
        guard owners.count == 1, let id = owners[0]["stableTabId"] as? String else {
            throw ObservationError.unavailable("Expected one tab holding pane \(paneID), found \(owners.count)")
        }
        return id
    }

    /// Every session's own appearance, as stored (Appearance.json `sessions`, keyed by
    /// the canonical session key: a UUID-shaped tab identity uppercased).
    func sessionStyles() throws -> [String: [String: String]] {
        let path = support.appendingPathComponent("Appearance.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return [:] }
        guard let document = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any] else {
            throw ObservationError.unavailable("Malformed style document")
        }
        return document["sessions"] as? [String: [String: String]] ?? [:]
    }

    static func sessionKey(_ tabID: String) -> String {
        UUID(uuidString: tabID).map { $0.uuidString.uppercased() } ?? tabID
    }

    /// One of the level's theme cards, filtered into view (the card grid is lazy).
    static func themeCard(_ name: String, in root: XCUIElement) -> XCUIElement {
        let filter = root.textFields["DesktopThemeFilter"].firstMatch
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        replaceText(of: filter, with: name)
        let card = root.buttons["DesktopTheme-\(name)"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 5), "theme card \(name)")
        return card
    }

    /// The level's base terminal size (Settings › Terminal Appearance › Font & Size).
    static func setFontSize(_ size: String, in root: XCUIElement) {
        let field = root.textFields["DesktopFontSize"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        replaceText(of: field, with: size + "\r")
    }

    /// The level's font family, chosen from the installed fonts.
    static func chooseFont(_ family: String, in root: XCUIElement) {
        let picker = root.buttons["DesktopFontPicker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.click()
        let filter = root.textFields["DesktopFontFilter"].firstMatch
        XCTAssertTrue(filter.waitForExistence(timeout: 5))
        replaceText(of: filter, with: family)
        let row = root.buttons["DesktopFont-\(family)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "font \(family)")
        row.click()
    }

    /// The level being edited: its chip reads «<kind> <name>».
    static func currentLevel(in root: XCUIElement) -> String {
        let chip = root.buttons["DesktopScopeCurrent"].firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 5))
        return chip.label
    }

    /// Every workspace's own appearance, as stored (Appearance.json `workspaces`).
    func workspaceStyles() throws -> [String: [String: String]] {
        let path = support.appendingPathComponent("Appearance.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return [:] }
        guard let document = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any] else {
            throw ObservationError.unavailable("Malformed style document")
        }
        return document["workspaces"] as? [String: [String: String]] ?? [:]
    }

    static func closeSettings(_ root: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let close = root.buttons["DesktopSettingsClose"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5), file: file, line: line)
        close.click()
        XCTAssertTrue(root.waitForNonExistence(timeout: 5), "Settings closed", file: file, line: line)
    }

    // MARK: The draft editor

    static func editor(in root: XCUIElement) -> XCUIElement {
        root.textFields["DesktopThemeName"].firstMatch
    }

    /// The exact text the draft will save (the Configuration tab).
    static func configurationField(in root: XCUIElement, file: StaticString = #filePath, line: UInt = #line) -> XCUIElement {
        let tab = root.buttons["DesktopThemeEditorSection-config"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 5), "the editor's Configuration tab", file: file, line: line)
        tab.click()
        let field = root.textViews["DesktopThemeConfiguration"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), file: file, line: line)
        return field
    }

    static func replaceText(of field: XCUIElement, with text: String) {
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
    }

    /// Replaces a long text by pasting it: typed, each key of a whole preset re-applies
    /// the draft's live preview, and 700 keys outlast the runner's stall watchdog. The
    /// pasteboard's earlier contents are put back afterwards, unless someone else wrote
    /// to it meanwhile (see `withPasteboardText`).
    static func pasteText(into field: XCUIElement, _ text: String) {
        withPasteboardText(text, on: .general) {
            field.click()
            field.typeKey("a", modifierFlags: .command)
            field.typeKey("v", modifierFlags: .command)
        }
    }

    enum PasteboardOutcome: Equatable {
        /// The earlier contents are back.
        case restored
        /// Someone else wrote while the earlier contents were being saved: nothing was put
        /// on the pasteboard and `body` did not run.
        case refusedBeforeWriting
        /// Someone else wrote after `text` was put there: their newer contents were kept.
        case keptNewerContents
    }

    /// Puts `text` on `board` for `body`, then gives the board back its earlier contents
    /// only if this text is still what it holds (by `changeCount`). Any other outcome is
    /// recorded as a test failure; a detected concurrent write is left untouched.
    /// The generation checks and writes are not an atomic pasteboard transaction.
    @discardableResult
    static func withPasteboardText(_ text: String, on board: NSPasteboard, _ body: () -> Void) -> PasteboardOutcome {
        let before = board.changeCount
        let saved = board.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        } ?? []
        guard board.changeCount == before else {
            XCTFail("The pasteboard changed while it was being saved; nothing was pasted")
            return .refusedBeforeWriting
        }
        board.clearContents()
        board.setString(text, forType: .string)
        let ours = board.changeCount
        body()
        guard board.changeCount == ours else {
            XCTFail("The pasteboard was written by someone else during the paste; their contents were left in place")
            return .keptNewerContents
        }
        board.clearContents()
        if !saved.isEmpty { board.writeObjects(saved) }
        return .restored
    }

    static func setThemeName(_ name: String, in root: XCUIElement) {
        let field = editor(in: root)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        replaceText(of: field, with: name)
    }

    /// `text` with each `key = value` line of `settings` replaced (or appended) and the
    /// given palette entries replaced, keeping every other line of the source preset.
    static func configuration(_ text: String, setting settings: [(String, String)], palette: [Int: String] = [:]) -> String {
        var lines = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        func key(_ line: String) -> String? {
            guard let eq = line.firstIndex(of: "=") else { return nil }
            return line[..<eq].trimmingCharacters(in: .whitespaces)
        }
        for (k, v) in settings {
            if let i = lines.firstIndex(where: { key($0) == k }) { lines[i] = "\(k) = \(v)" } else { lines.append("\(k) = \(v)") }
        }
        for (index, color) in palette {
            let match: (String) -> Bool = { line in
                guard key(line) == "palette", let eq = line.firstIndex(of: "=") else { return false }
                let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                return value.split(separator: "=").first.map { $0.trimmingCharacters(in: .whitespaces) } == "\(index)"
            }
            if let i = lines.firstIndex(where: match) { lines[i] = "palette = \(index)=\(color)" } else { lines.append("palette = \(index)=\(color)") }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: The pane's own renderer

    /// Records the control socket the isolated host gave its first terminal. Call
    /// while that terminal has the keyboard (before Settings opens).
    func recordControlSocket() throws {
        let terminal = Self.terminalPane(in: try XCTUnwrap(app))
        let file = testRoot.appendingPathComponent("control-socket")
        terminal.typeText("printf '%s' \"$TAKO_SOCKET\" > 'control-socket'\n")
        guard Self.wait({ (try? String(contentsOf: file, encoding: .utf8).isEmpty) == false }) else {
            throw ObservationError.unavailable("The test terminal did not report its control socket")
        }
    }

    /// `takoctl screenshot` of `paneID`: the pane drawn by its own renderer with its
    /// current theme and font, whatever covers it on screen.
    func rendererImage(of paneID: String) throws -> CGImage {
        let socket = try String(contentsOf: testRoot.appendingPathComponent("control-socket"), encoding: .utf8)
        return try Self.rendererImage(of: paneID, socket: socket)
    }

    /// Read-only observation shared by setup: it uses the socket and pane ID
    /// reported by that fixture's shell before any modal panel opens.
    static func rendererImage(of paneID: String, socket: String) throws -> CGImage {
        let hosts = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID)
        guard hosts.count == 1, let host = hosts.first?.bundleURL else {
            throw ObservationError.unavailable("Expected exactly one isolated host, found \(hosts.count)")
        }
        let process = Process(), output = Pipe()
        process.executableURL = host.appendingPathComponent("Contents/MacOS/takoctl")
        process.arguments = ["--bundle-id", Self.bundleID, "--socket", socket, "--json", "screenshot", "--target", paneID.lowercased()]
        var environment = ProcessInfo.processInfo.environment
        for key in ["TAKO_SOCKET", "TAKO_SURFACE_ID", "TAKO_CLIENT", "TAKO_CLIENT_ID"] { environment.removeValue(forKey: key) }
        process.environment = environment
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              response["ok"] as? Bool == true,
              let result = response["result"] as? [String: Any],
              let encoded = result["data"] as? String, let png = Data(base64Encoded: encoded),
              let image = NSBitmapImageRep(data: png)?.cgImage else {
            throw ObservationError.unavailable("takoctl screenshot failed: \(String(decoding: data.prefix(300), as: UTF8.self))")
        }
        return image
    }

    func rendererColor(of paneID: String) -> NSColor? {
        (try? rendererImage(of: paneID)).flatMap(Self.samplePixelColor(from:))
    }

    func rendererGlyphs(of paneID: String) throws -> (bounds: CGRect, pixels: Data) {
        try Self.glyphInk(in: try rendererImage(of: paneID))
    }
}
