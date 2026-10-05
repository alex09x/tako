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
import XCTest
@testable import TakoCoreUI

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

@MainActor
final class SemanticPathClickTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        TakoTerminalNSView.editorLauncher = nil
        super.tearDown()
    }

    private func makeView() -> TakoTerminalNSView {
        let core = TakoCore(cols: 240, rows: 40)
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 1400, height: 400), core: core)
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func point(forColumn col: Int, row: Int = 0, in view: TakoTerminalNSView) -> NSPoint {
        let origin = view.cellOrigin(row: row, col: col)
        return NSPoint(x: origin.x + max(view.cellWidth, 1) / 2,
                       y: origin.y + max(view.cellHeight, 1) / 2)
    }

    private func mouseEvent(
        _ type: NSEvent.EventType, column: Int, row: Int = 0, in view: TakoTerminalNSView,
        modifiers: NSEvent.ModifierFlags = [], clickCount: Int = 1
    ) -> NSEvent {
        NSEvent.mouseEvent(
            with: type, location: point(forColumn: column, row: row, in: view),
            modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1
        )!
    }

    final class MockDelegate: TakoTerminalNSViewDelegate {
        var clickedPayload: TakoTerminalNSView.SemanticPathPayload?
        func terminalView(_ view: TakoTerminalNSView, sendInputData data: Data) {}
        func terminalView(_ view: TakoTerminalNSView, sendDeviceReplyData data: Data) {}
        func terminalView(_ view: TakoTerminalNSView, didResizeCols cols: Int, rows: Int) {}
        func terminalView(_ view: TakoTerminalNSView, didClickSemanticPath payload: TakoTerminalNSView.SemanticPathPayload) {
            clickedPayload = payload
        }
    }

    // MARK: - Safety Gate Tests (E6)

    func testSafetyGateRejectsControlCharacters() {
        let view = makeView()
        let badPaths = [
            "foo\0bar.swift",
            "foo\rbar.swift",
            "foo\nbar.swift",
            "foo\u{1b}bar.swift",
            "foo\u{7f}bar.swift"
        ]
        for p in badPaths {
            XCTAssertNil(view.validateSemanticPath(rawPath: p), "Control character must be rejected: \(p.debugDescription)")
        }
    }

    func testSafetyGateRejectsShellMetacharacters() {
        let view = makeView()
        let metacharacters = [
            "foo;rm -rf /",
            "foo|bar.swift",
            "foo&bar.swift",
            "foo$HOME.swift",
            "foo`whoami`.swift",
            "foo<input.swift",
            "foo>output.swift",
            "foo!bar.swift",
            "foo\"bar.swift",
            "foo'bar.swift",
            "foo*bar.swift",
            "foo?bar.swift",
            "foo[1].swift",
            "foo{a,b}.swift",
            "foo(1).swift",
            "foo bar.swift",
            "foo\tbar.swift",
            "foo\\bar.swift"
        ]
        for p in metacharacters {
            XCTAssertNil(view.validateSemanticPath(rawPath: p), "Shell metacharacter must be rejected: \(p)")
        }
    }

    func testSafetyGateRejectsLeadingHyphens() {
        let view = makeView()
        let leadingHyphens = [
            "-f",
            "--option",
            "path/-flag",
            "dir/--flag/file.swift"
        ]
        for p in leadingHyphens {
            XCTAssertNil(view.validateSemanticPath(rawPath: p), "Leading hyphen must be rejected: \(p)")
        }
    }

    func testSafetyGateIgnoresNonExistentFilesWithoutSideEffects() {
        let view = makeView()
        let nonExistent = tempDir.appendingPathComponent("non_existent_file_xyz.swift").path
        XCTAssertNil(view.validateSemanticPath(rawPath: nonExistent), "Non-existent file must return nil without side effects")
    }

    func testSafetyGateResolvesExistingFiles() throws {
        let view = makeView()
        let existingFile = tempDir.appendingPathComponent("Hello.swift")
        try "print(1)".write(to: existingFile, atomically: true, encoding: .utf8)

        let validated = view.validateSemanticPath(rawPath: existingFile.path)
        XCTAssertNotNil(validated)
        XCTAssertEqual(validated, existingFile.path)
    }

    func testSafetyGateRejectsDisguisedOSC8Targets() throws {
        let view = makeView()
        let existingFile = tempDir.appendingPathComponent("Target.swift")
        try "// code".write(to: existingFile, atomically: true, encoding: .utf8)

        // Inject OSC 8 hyperlink text pointing to an arbitrary URL disguised as file path
        let osc8Seq = "\u{1b}]8;;https://malicious.example.com\u{1b}\\\(existingFile.path):10:5\u{1b}]8;;\u{1b}\\"
        view.feed(data: Data(osc8Seq.utf8))

        // Semantic path detection must refuse to parse cells that have OSC 8 hyperlinks
        let target = view.semanticPath(at: (row: 0, col: 2))
        XCTAssertNil(target, "Semantic path must reject disguised OSC 8 hyperlink target cells")
    }

    // MARK: - Pattern Parsing and Detection Tests (E6)

    func testSemanticPathDetectionAndCommandClick() throws {
        let view = makeView()
        let delegate = MockDelegate()
        view.delegate = delegate

        let existingFile = tempDir.appendingPathComponent("Main.swift")
        try "func main() {}".write(to: existingFile, atomically: true, encoding: .utf8)

        let lineText = "error: \(existingFile.path):42:15: syntax error"
        view.feed(data: Data(lineText.utf8))

        // Mouse over the path (e.g. column 15)
        let hitCell = (row: 0, col: 15)
        let target = view.semanticPath(at: hitCell)
        XCTAssertNotNil(target)
        XCTAssertEqual(target?.rawPath, existingFile.path)
        XCTAssertEqual(target?.line, 42)
        XCTAssertEqual(target?.col, 15)
        XCTAssertEqual(target?.resolvedPath, existingFile.path)

        // Intercept editor launch
        var launchedCommand: String?
        var launchedArgs: [String]?
        TakoTerminalNSView.editorLauncher = { cmd, args, cwd in
            launchedCommand = cmd
            launchedArgs = args
            return true
        }

        view.configuredEditorCommand = "code"

        var callbackCalled = false
        view.onSemanticPathClick = { payload in
            callbackCalled = true
            XCTAssertEqual(payload.path, existingFile.path)
            XCTAssertEqual(payload.line, 42)
            XCTAssertEqual(payload.col, 15)
        }

        // Simulate Command-Click
        view.mouseMoved(with: mouseEvent(.mouseMoved, column: 15, in: view, modifiers: [.command]))
        XCTAssertNotNil(view.hoveredSemanticPath)

        view.mouseDown(with: mouseEvent(.leftMouseDown, column: 15, in: view, modifiers: [.command]))

        XCTAssertTrue(callbackCalled)
        XCTAssertEqual(delegate.clickedPayload?.path, existingFile.path)
        XCTAssertEqual(launchedCommand, "code")
        XCTAssertEqual(launchedArgs, ["-g", "\(existingFile.path):42:15"])
    }

    func testConfiguredEditorArgvFlavors() throws {
        let view = makeView()
        let existingFile = tempDir.appendingPathComponent("Source.rs")
        try "fn foo() {}".write(to: existingFile, atomically: true, encoding: .utf8)

        let target = TakoTerminalNSView.SemanticPathTarget(
            rawPath: existingFile.path,
            line: 120,
            col: 8,
            resolvedPath: existingFile.path,
            row: 0,
            colStart: 0,
            colEnd: 10
        )

        var launchedCommand: String?
        var launchedArgs: [String]?
        TakoTerminalNSView.editorLauncher = { cmd, args, cwd in
            launchedCommand = cmd
            launchedArgs = args
            return true
        }

        // 1. VS Code / Cursor flavor
        view.configuredEditorCommand = "cursor"
        view.openSemanticPath(target)
        XCTAssertEqual(launchedCommand, "cursor")
        XCTAssertEqual(launchedArgs, ["-g", "\(existingFile.path):120:8"])

        // 2. Vim flavor
        view.configuredEditorCommand = "vim"
        view.openSemanticPath(target)
        XCTAssertEqual(launchedCommand, "vim")
        XCTAssertEqual(launchedArgs, ["+120", existingFile.path])

        // 3. Nano flavor
        view.configuredEditorCommand = "nano"
        view.openSemanticPath(target)
        XCTAssertEqual(launchedCommand, "nano")
        XCTAssertEqual(launchedArgs, ["+120,8", existingFile.path])

        // 4. Subl flavor
        view.configuredEditorCommand = "subl"
        view.openSemanticPath(target)
        XCTAssertEqual(launchedCommand, "subl")
        XCTAssertEqual(launchedArgs, ["\(existingFile.path):120:8"])

        // 5. Malicious editor command with metacharacters is rejected
        launchedCommand = nil
        launchedArgs = nil
        view.configuredEditorCommand = "code; rm -rf /"
        view.openSemanticPath(target)
        XCTAssertNil(launchedCommand, "Malicious editor command must be rejected without launching")
    }

    func testSemanticPathContextMenu() throws {
        let view = makeView()
        let existingFile = tempDir.appendingPathComponent("File.swift")
        try "let a = 1".write(to: existingFile, atomically: true, encoding: .utf8)

        view.configuredEditorCommand = "code"
        let target = TakoTerminalNSView.SemanticPathTarget(
            rawPath: existingFile.path,
            line: 5,
            col: 1,
            resolvedPath: existingFile.path,
            row: 0,
            colStart: 0,
            colEnd: 10
        )

        let menu = view.semanticPathContextMenu(for: target)
        XCTAssertTrue(menu.items.contains { $0.title.contains("Open \(existingFile.path) in code") })
        XCTAssertTrue(menu.items.contains { $0.title == "Copy Path" })
    }
}
#endif
