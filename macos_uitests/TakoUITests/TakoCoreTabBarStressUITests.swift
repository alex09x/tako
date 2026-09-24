import XCTest

/// Regression for `inc-2026-08-16-takocore-macos-tabbar-coretext-crash`.
///
/// The crash needs two tabs (the custom strip is hidden for one) and a title
/// with glyphs missing from SF Mono. Several CLI spinners use braille glyphs,
/// so drive the real shell with the same OSC 0 stream that killed the app.
final class TakoCoreTabBarStressUITests: TakoCustomConfigCase {
    override func setUp() async throws {
        try await super.setUp()
        try updateConfig("macos-titlebar-style = tabs")
    }

    @MainActor
    func testTypingACommandAndReturnExecutesItInTheRealShell() throws {
        let app = try takoApplication()
        app.launch()

        let terminal = app.groups["Terminal pane"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        terminal.click()
        attachScreenshot(named: "01 terminal focused before typing")

        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("takocore-ui-input-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }

        // The marker proves that the command crossed the AppKit key path and
        // reached the real PTY. The OSC title gives the UI process its own
        // independently observable result, so this cannot pass merely because
        // the test process created a file by accident.
        let title = "TAKO_INPUT_RETURN_OK"
        // Hold the title briefly: the shell's next prompt immediately emits
        // its own title, so without the sleep the app can process both OSCs
        // before XCUITest's first accessibility snapshot.
        let command = "printf ok > \(marker.path); printf '\\033]0;\(title)\\007'; sleep 3"
        terminal.typeText(command)
        attachScreenshot(named: "02 command typed before Return")
        // `.enter` is the separate numeric-keypad key (⌤). A real user
        // submits the shell line with the main Return key (↩), whose terminal
        // semantics differ while application-keypad mode is active.
        terminal.typeKey(.return, modifierFlags: [])

        let markerWritten = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: marker.path) },
            object: nil
        )
        let titleChanged = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "title == %@", title),
            object: app.windows.firstMatch
        )
        wait(for: [markerWritten, titleChanged], timeout: 8)

        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "ok")
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(terminal.exists)
        attachScreenshot(named: "03 command executed after Return")
    }

    @MainActor
    func testRapidUnsupportedOscTitlesDoNotTerminateTheApp() throws {
        let app = try takoApplication()
        app.launch()

        let terminal = app.groups["Terminal pane"]
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        terminal.typeKey("t", modifierFlags: .command)

        // ASCII source text keeps the UI keyboard driver out of the
        // equation; Python creates the actual braille scalars in the PTY.
        let command = "python3 -c 'import sys,time; s=[chr(x) for x in (0x280b,0x2819,0x2839,0x2838,0x283c,0x2834,0x2826,0x2827)]; [(sys.stdout.write(chr(27)+\"]0;\"+s[i%8]+\" myfit-\"+str(i)+chr(7)),sys.stdout.flush(),time.sleep(.001)) for i in range(10000)]'"
        terminal.typeText(command + "\r")

        let window = app.windows.firstMatch
        let titleChanged = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "title CONTAINS 'myfit-'"),
            object: window
        )
        wait(for: [titleChanged], timeout: 5)

        // Let all 10,000 updates and the redraws they schedule complete.
        Thread.sleep(forTimeInterval: 12)
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(window.exists)
        XCTAssertTrue(terminal.exists)
    }

    @MainActor
    private func attachScreenshot(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
