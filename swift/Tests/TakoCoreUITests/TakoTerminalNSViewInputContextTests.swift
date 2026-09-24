import Foundation
import XCTest
@testable import TakoCoreUI

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

/// The text input context the surface owns, and when it is active.
///
/// Dictation binds to the *active* context. A view that merely conforms to
/// NSTextInputClient and inherits its window's context never activates one, so
/// a session starts, never reaches listening, and is dropped seconds later
/// having delivered nothing. Ordinary typing and marked text work throughout,
/// which is why this went unnoticed until somebody spoke at it.
@MainActor
final class TakoTerminalNSViewInputContextTests: XCTestCase {
    /// What AppKit currently considers the active input context.
    ///
    /// Asserted against instead of the view's own flag: a bookkeeping boolean
    /// agrees with itself no matter what the input system did, which is the
    /// difference between a test and a tautology.
    private func systemActiveContext() -> NSTextInputContext? {
        NSTextInputContext.current
    }

    /// Puts the surface in a key window and focuses it, or says why it could
    /// not.
    ///
    /// A `swift test` bundle has no activated application, so a window in it
    /// generally never becomes key and the activation rule correctly declines
    /// to hold a context. That is an environment limit, not a defect, and the
    /// honest response is to skip with the reason rather than to weaken the
    /// rule until the test goes green.
    private func focusInKeyWindow(_ view: NSView) throws -> NSWindow {
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.activate(ignoringOtherApps: true)
        let window = makeWindow(with: view)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        try XCTSkipUnless(
            window.isKeyWindow,
            "no key window in this test bundle: nothing activated the application, "
                + "so the activation rule cannot be exercised here. The rule itself is "
                + "pinned by the shouldHoldInputContext tests, and live focus behaviour "
                + "belongs to the acceptance run on a real machine."
        )
        return window
    }

    private func makeWindow(with view: NSView) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        return window
    }

    func testTheSurfaceOwnsItsContextRatherThanInheritingOne() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        // In a window: a view outside one has no input context, which is both
        // AppKit's own behaviour and what keeps a departing surface from
        // building a session it will never use.
        _ = makeWindow(with: view)
        let context = view.inputContext
        XCTAssertNotNil(context, "the surface has no input context at all")
        XCTAssertTrue(
            context?.client === view,
            "the context is not bound to this surface, so dictation would deliver elsewhere"
        )
        XCTAssertTrue(
            view.inputContext === context,
            "a fresh context per access is not a session anything can stay bound to"
        )
    }

    func testFocusInAKeyWindowActivatesTheContext() throws {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        _ = try focusInKeyWindow(view)

        XCTAssertTrue(view.isInputContextActiveForTesting,
                      "focused in a key window and still not holding an active context")
        XCTAssertTrue(systemActiveContext() === view.inputContext,
                      "the system's active context is not this surface's own")
    }

    func testResigningFocusDeactivatesIt() throws {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let window = try focusInKeyWindow(view)
        XCTAssertTrue(view.isInputContextActiveForTesting)

        window.makeFirstResponder(nil)
        XCTAssertFalse(view.isInputContextActiveForTesting,
                       "an unfocused surface still holds the dictation session")
        XCTAssertFalse(systemActiveContext() === view.inputContext,
                       "the system still has this surface's context active after it resigned")
    }

    /// The case that makes activation safe to do at all.
    func testAnUnfocusedSurfaceNeverTakesTheContext() throws {
        let focused = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let other = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        container.addSubview(focused)
        container.addSubview(other)
        _ = try focusInKeyWindow(container)
        NSApplication.shared.keyWindow?.makeFirstResponder(focused)

        XCTAssertTrue(focused.isInputContextActiveForTesting)
        XCTAssertFalse(other.isInputContextActiveForTesting,
                       "a second surface activated a context it was never focused in")
    }

    func testHidingTheSurfaceReleasesIt() throws {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        _ = try focusInKeyWindow(view)
        XCTAssertTrue(view.isInputContextActiveForTesting)

        view.isHidden = true
        XCTAssertFalse(view.isInputContextActiveForTesting,
                       "a hidden surface keeps a session alive where nobody can see it")
    }

    func testLeavingTheWindowReleasesIt() throws {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        _ = try focusInKeyWindow(view)
        XCTAssertTrue(view.isInputContextActiveForTesting)

        view.removeFromSuperview()
        XCTAssertFalse(view.isInputContextActiveForTesting,
                       "a surface with no window still holds an active context")
        XCTAssertFalse(systemActiveContext() === view.inputContext,
                       "the system still has the context of a surface that left its window")
    }

    /// Committed text must still take the delegate byte path, once.
    ///
    /// Dictation commits through insertText exactly as the keyboard does, so
    /// the fix must not have changed where those bytes go or how many times.
    func testCommittedTextGoesThroughTheDelegateExactlyOnce() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let delegate = MockTerminalNSViewDelegate()
        view.delegate = delegate
        _ = makeWindow(with: view)

        view.insertText("violet", replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertEqual(
            String(data: delegate.inputDataReceived, encoding: .utf8), "violet",
            "committed text did not reach the delegate byte path exactly once"
        )
    }

    func testCommittedTextStartsNoProcess() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let delegate = MockTerminalNSViewDelegate()
        view.delegate = delegate
        _ = makeWindow(with: view)

        let before = descendantProcessCount()
        view.insertText("violet", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(descendantProcessCount(), before,
                       "delivering dictated text started a child process")
    }

    /// Read from the kernel rather than by running a tool, which would create
    /// the very thing being counted.
    private func descendantProcessCount() -> Int {
        var buffer = [pid_t](repeating: 0, count: 128)
        let size = Int32(buffer.count * MemoryLayout<pid_t>.size)
        let bytes = proc_listchildpids(getpid(), &buffer, size)
        guard bytes > 0 else { return 0 }
        return Array(buffer.prefix(Int(bytes) / MemoryLayout<pid_t>.size)).filter { $0 != 0 }.count
    }

    /// Teardown of a surface that was never focused must not bring a context
    /// into existence on the way out.
    ///
    /// Asserted on a creation count rather than by reading `inputContext`:
    /// that read is itself what would create the context, so a test phrased
    /// that way disproves its own claim. The earlier version of this test did
    /// exactly that.
    func testTeardownOfAnUnfocusedSurfaceCreatesNoContext() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let window = makeWindow(with: view)
        window.orderFront(nil)
        let beforeTeardown = view.inputContextCreationCountForTesting

        view.removeFromSuperview()

        XCTAssertEqual(
            view.inputContextCreationCountForTesting, beforeTeardown,
            "teardown built a context on the way out (before=\(beforeTeardown), "
                + "after=\(view.inputContextCreationCountForTesting))"
        )
        XCTAssertFalse(view.isInputContextActiveForTesting)
    }

    /// The ordering the consumer's live run exposed.
    ///
    /// AppKit installs the first responder only after becomeFirstResponder
    /// returns true, so evaluating the rule inside it reads the *previous*
    /// responder and declines. A window that is already key then sends no
    /// notification to retry on, and the context never activates: focused,
    /// context present, recognizer stuck at stage zero.
    func testActivationIsNotDecidedBeforeTheResponderTransitionCompletes() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let window = makeWindow(with: view)

        // Inside the call the window has not installed this view yet, which is
        // precisely why the decision cannot be made here.
        _ = view.becomeFirstResponder()
        XCTAssertFalse(
            window.firstResponder === view,
            "the window installed the responder synchronously; this test no longer "
                + "describes AppKit and the ordering fix needs rechecking"
        )
        XCTAssertFalse(view.isInputContextActiveForTesting,
                       "a decision was reached from the pre-transition state")
    }

    /// Losing focus must release the context even though the window still
    /// reports this view as its first responder while resign runs.
    func testResigningReleasesEvenWhileStillReportedAsFirstResponder() throws {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        let window = try focusInKeyWindow(view)
        XCTAssertTrue(view.isInputContextActiveForTesting)
        XCTAssertTrue(window.firstResponder === view)

        _ = view.resignFirstResponder()

        XCTAssertFalse(view.isInputContextActiveForTesting,
                       "the rule was consulted while this view was still first responder, "
                           + "so the session outlived the focus that justified it")
    }

    // MARK: - The activation rule, without a window server

    func testTheRuleHoldsOnlyWhenFocusedInAVisibleKeyWindow() {
        XCTAssertTrue(TakoTerminalNSView.shouldHoldInputContext(
            hasWindow: true, isKeyWindow: true, isFirstResponder: true, isHidden: false))
    }

    func testTheRuleDeclinesWithoutEachCondition() {
        XCTAssertFalse(TakoTerminalNSView.shouldHoldInputContext(
            hasWindow: false, isKeyWindow: true, isFirstResponder: true, isHidden: false),
            "a surface with no window would hold a context")
        XCTAssertFalse(TakoTerminalNSView.shouldHoldInputContext(
            hasWindow: true, isKeyWindow: false, isFirstResponder: true, isHidden: false),
            "a background window would take the dictation session from the key one")
        XCTAssertFalse(TakoTerminalNSView.shouldHoldInputContext(
            hasWindow: true, isKeyWindow: true, isFirstResponder: false, isHidden: false),
            "an unfocused surface would take the session from the focused one")
        XCTAssertFalse(TakoTerminalNSView.shouldHoldInputContext(
            hasWindow: true, isKeyWindow: true, isFirstResponder: true, isHidden: true),
            "a hidden surface would keep a session alive out of sight")
    }

    // MARK: - The range AppKit asks for before it will drive a session

    /// With nothing selected the range must be a valid insertion point.
    ///
    /// NSNotFound here is not "no selection", it is an invalid location, and
    /// AppKit's input system stops at it: the recognizer initializes, asks for
    /// the selected range, and never begins listening. This is the exact
    /// condition a consumer's causal A/B isolated.
    func testNoSelectionReportsAValidInsertionPoint() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        _ = makeWindow(with: view)

        let range = view.selectedRange()

        XCTAssertNotEqual(range.location, NSNotFound,
                          "an invalid insertion location stops Dictation before listening")
        XCTAssertEqual(range, NSRange(location: 0, length: 0))
    }

    func testASelectionReportsItsLength() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        _ = makeWindow(with: view)
        view.feed(data: Data("violet\r\n".utf8))
        view.core.selectWord(row: 0, col: 2)

        let range = view.selectedRange()

        XCTAssertEqual(range.location, 0)
        XCTAssertEqual(range.length, 6, "expected the selected word's length")
    }

    /// markedRange keeps NSNotFound, and must: there it is the documented way
    /// to say nothing is composing. The two are not the same contract, and
    /// aligning them would break composition.
    func testMarkedRangeStillReportsNSNotFoundWithNothingComposing() {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        _ = makeWindow(with: view)

        XCTAssertEqual(view.markedRange().location, NSNotFound)
        XCTAssertFalse(view.hasMarkedText())
    }
}
#endif
