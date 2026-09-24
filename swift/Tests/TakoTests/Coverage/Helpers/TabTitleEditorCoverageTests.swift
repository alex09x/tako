import Testing
import Foundation
import AppKit
@testable import Tako

@MainActor
private final class FakeTabTitleEditorDelegate: TabTitleEditorDelegate {
    var canRename = true
    var titles: [ObjectIdentifier: String] = [:]

    private(set) var committedTitle: String?
    private(set) var committedWindow: NSWindow?
    private(set) var fallbackWindow: NSWindow?
    private(set) var finishedWindows: [NSWindow] = []

    func tabTitleEditor(_ editor: TabTitleEditor, canRenameTabFor targetWindow: NSWindow) -> Bool {
        canRename
    }

    func tabTitleEditor(_ editor: TabTitleEditor, titleFor targetWindow: NSWindow) -> String {
        titles[ObjectIdentifier(targetWindow)] ?? targetWindow.title
    }

    func tabTitleEditor(_ editor: TabTitleEditor, didCommitTitle editedTitle: String, for targetWindow: NSWindow) {
        committedTitle = editedTitle
        committedWindow = targetWindow
    }

    func tabTitleEditor(_ editor: TabTitleEditor, performFallbackRenameFor targetWindow: NSWindow) {
        fallbackWindow = targetWindow
    }

    func tabTitleEditor(_ editor: TabTitleEditor, didFinishEditing targetWindow: NSWindow) {
        finishedWindows.append(targetWindow)
    }
}

@MainActor
private func makeTabTestWindow(title: String, at offset: CGFloat) -> NSWindow {
    let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 900, height: 700)
    let window = NSWindow(
        contentRect: NSRect(x: frame.minX + 20 + offset, y: frame.minY + 20, width: 400, height: 300),
        styleMask: [.titled, .closable, .resizable, .miniaturizable],
        backing: .buffered,
        defer: false)
    window.isReleasedWhenClosed = false
    window.tabbingMode = .preferred
    window.title = title
    return window
}

@MainActor
private func waitTabTitle(timeout: TimeInterval = 4, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
}

/// Waits by suspending rather than spinning the run loop: these tests run as
/// jobs on the main queue, so work the code under test schedules with
/// `DispatchQueue.main.async` only runs once the test yields the thread.
@MainActor
private func waitAsync(timeout: TimeInterval = 4, _ condition: () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
}

/// Locates the NSTextField this specific `TabTitleEditor` instance injected into `tabButton`
/// (as opposed to AppKit's own private title label), by identity of the delegate it assigned.
@MainActor
private func findInjectedEditor(in tabButton: NSView, owner: TabTitleEditor) -> NSTextField? {
    tabButton.descendants(withClassName: "NSTextField")
        .compactMap { $0 as? NSTextField }
        .first { ($0.delegate as AnyObject?) === owner }
}

@MainActor
private struct TabTitleEditorHarness {
    let first: NSWindow
    let second: NSWindow
    let editor: TabTitleEditor
    let delegate: FakeTabTitleEditorDelegate

    static func make() -> TabTitleEditorHarness? {
        let first = makeTabTestWindow(title: "Tab One", at: 0)
        let second = makeTabTestWindow(title: "Tab Two", at: 450)

        first.orderFrontRegardless()
        waitTabTitle { first.windowNumber > 0 }
        first.addTabbedWindow(second, ordered: .above)
        waitTabTitle { first.tabbedWindows?.count == 2 }
        first.tabGroup?.windows.forEach { $0.contentView?.layoutSubtreeIfNeeded() }
        first.contentView?.layoutSubtreeIfNeeded()
        first.displayIfNeeded()
        waitTabTitle(timeout: 4) { first.tabButtonsInVisualOrder().count == 2 }

        guard first.tabButtonsInVisualOrder().count == 2 else { return nil }

        let delegate = FakeTabTitleEditorDelegate()
        let editor = TabTitleEditor(hostWindow: first, delegate: delegate)
        return TabTitleEditorHarness(first: first, second: second, editor: editor, delegate: delegate)
    }

    func tearDown() {
        first.close()
        second.close()
    }

    func tabButton(for window: NSWindow) -> NSView? {
        guard let tabbedWindows = first.tabbedWindows,
              let index = tabbedWindows.firstIndex(of: window) else { return nil }
        return first.tabButtonsInVisualOrder()[safe: index]
    }
}

@MainActor
struct TabTitleEditorTests {
    @Test func beginEditingInsertsEditorSeededWithDelegateTitle() async {
        guard let harness = TabTitleEditorHarness.make() else {
            Issue.record("Could not build a real native tab bar on this machine")
            return
        }
        defer { harness.tearDown() }

        #expect(harness.editor.beginEditing(for: harness.second))

        guard let tabButton = harness.tabButton(for: harness.second) else {
            Issue.record("Expected a tab button for the second window")
            return
        }
        let injected = findInjectedEditor(in: tabButton, owner: harness.editor)
        #expect(injected != nil)
        #expect(injected?.stringValue == "Tab Two")

        await waitAsync { injected?.isHidden == false }
        #expect(injected?.isHidden == false)
    }

    @Test func commitViaInsertNewlineNotifiesDelegateAndRemovesEditor() {
        guard let harness = TabTitleEditorHarness.make() else {
            Issue.record("Could not build a real native tab bar on this machine")
            return
        }
        defer { harness.tearDown() }

        #expect(harness.editor.beginEditing(for: harness.second))
        guard let tabButton = harness.tabButton(for: harness.second),
              let injected = findInjectedEditor(in: tabButton, owner: harness.editor) else {
            Issue.record("Expected an injected editor")
            return
        }

        injected.stringValue = "Renamed Tab"
        let handled = harness.editor.control(injected, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))

        #expect(handled)
        #expect(harness.delegate.committedTitle == "Renamed Tab")
        #expect(harness.delegate.committedWindow === harness.second)
        #expect(harness.delegate.finishedWindows.last === harness.second)
        #expect(injected.superview == nil)
    }

    @Test func cancelViaEscapeDiscardsWithoutCommitting() {
        guard let harness = TabTitleEditorHarness.make() else {
            Issue.record("Could not build a real native tab bar on this machine")
            return
        }
        defer { harness.tearDown() }

        #expect(harness.editor.beginEditing(for: harness.first))
        guard let tabButton = harness.tabButton(for: harness.first),
              let injected = findInjectedEditor(in: tabButton, owner: harness.editor) else {
            Issue.record("Expected an injected editor")
            return
        }

        injected.stringValue = "Should Not Commit"
        let handled = harness.editor.control(injected, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))

        #expect(handled)
        #expect(harness.delegate.committedTitle == nil)
        #expect(harness.delegate.finishedWindows.last === harness.first)
    }

    @Test func controlDoCommandByIgnoresUnrelatedControls() {
        guard let harness = TabTitleEditorHarness.make() else {
            Issue.record("Could not build a real native tab bar on this machine")
            return
        }
        defer { harness.tearDown() }

        let unrelated = NSTextField()
        let handled = harness.editor.control(unrelated, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
        #expect(!handled)
    }

    @Test func blurCommitsThroughControlTextDidEndEditing() {
        guard let harness = TabTitleEditorHarness.make() else {
            Issue.record("Could not build a real native tab bar on this machine")
            return
        }
        defer { harness.tearDown() }

        #expect(harness.editor.beginEditing(for: harness.first))
        guard let tabButton = harness.tabButton(for: harness.first),
              let injected = findInjectedEditor(in: tabButton, owner: harness.editor) else {
            Issue.record("Expected an injected editor")
            return
        }
        injected.stringValue = "Blurred Title"

        harness.editor.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: injected))

        #expect(harness.delegate.committedTitle == "Blurred Title")
        #expect(harness.delegate.committedWindow === harness.first)
    }

    @Test func controlTextDidEndEditingIgnoresNotificationsForOtherObjects() {
        guard let harness = TabTitleEditorHarness.make() else {
            Issue.record("Could not build a real native tab bar on this machine")
            return
        }
        defer { harness.tearDown() }

        let unrelated = NSTextField()
        harness.editor.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: unrelated))
        #expect(harness.delegate.committedTitle == nil)
    }

    @Test func beginEditingFailsWhenDelegateDeniesRename() {
        guard let harness = TabTitleEditorHarness.make() else {
            Issue.record("Could not build a real native tab bar on this machine")
            return
        }
        defer { harness.tearDown() }

        harness.delegate.canRename = false
        #expect(!harness.editor.beginEditing(for: harness.second))
    }

    @Test func beginEditingFailsForWindowOutsideTheTabGroup() {
        guard let harness = TabTitleEditorHarness.make() else {
            Issue.record("Could not build a real native tab bar on this machine")
            return
        }
        defer { harness.tearDown() }

        let outsider = makeTabTestWindow(title: "Outsider", at: 900)
        defer { outsider.close() }
        #expect(!harness.editor.beginEditing(for: outsider))
    }

    @Test func handleMouseDownDoubleClickOnTabBeginsInlineEditingAsynchronously() async {
        guard let harness = TabTitleEditorHarness.make() else {
            Issue.record("Could not build a real native tab bar on this machine")
            return
        }
        defer { harness.tearDown() }

        guard let tabButton = harness.tabButton(for: harness.first), let buttonWindow = tabButton.window else {
            Issue.record("Expected a hosted tab button")
            return
        }
        let centerInView = NSPoint(x: tabButton.bounds.midX, y: tabButton.bounds.midY)
        let locationInWindow = tabButton.convert(centerInView, to: nil)

        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: locationInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: buttonWindow.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 2,
            pressure: 1)

        guard let event else {
            Issue.record("Expected to synthesize a mouse event")
            return
        }

        let handled = harness.editor.handleMouseDown(event)
        #expect(handled)

        await waitAsync { findInjectedEditor(in: tabButton, owner: harness.editor) != nil }
        #expect(findInjectedEditor(in: tabButton, owner: harness.editor) != nil)
    }

    @Test func handleMouseDownIgnoresSingleClicks() {
        guard let harness = TabTitleEditorHarness.make() else {
            Issue.record("Could not build a real native tab bar on this machine")
            return
        }
        defer { harness.tearDown() }

        guard let tabButton = harness.tabButton(for: harness.first), let buttonWindow = tabButton.window else {
            Issue.record("Expected a hosted tab button")
            return
        }
        let locationInWindow = tabButton.convert(NSPoint(x: tabButton.bounds.midX, y: tabButton.bounds.midY), to: nil)

        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: locationInWindow,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: buttonWindow.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1)

        guard let event else {
            Issue.record("Expected to synthesize a mouse event")
            return
        }
        #expect(!harness.editor.handleMouseDown(event))
    }

    @Test func handleMouseDownIgnoresNonLeftMouseDownEvents() {
        guard let harness = TabTitleEditorHarness.make() else {
            Issue.record("Could not build a real native tab bar on this machine")
            return
        }
        defer { harness.tearDown() }

        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: harness.first.windowNumber,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
            isARepeat: false,
            keyCode: 0)

        guard let event else {
            Issue.record("Expected to synthesize a key event")
            return
        }
        #expect(!harness.editor.handleMouseDown(event))
    }

    @Test func handleRightMouseDownReturnsFalseWithoutActiveEditor() {
        guard let harness = TabTitleEditorHarness.make() else {
            Issue.record("Could not build a real native tab bar on this machine")
            return
        }
        defer { harness.tearDown() }

        let event = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: harness.first.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1)
        guard let event else {
            Issue.record("Expected to synthesize a mouse event")
            return
        }
        #expect(!harness.editor.handleRightMouseDown(event))
    }

    @Test func handleRightMouseDownIgnoresNonRightMouseDownEvents() {
        guard let harness = TabTitleEditorHarness.make() else {
            Issue.record("Could not build a real native tab bar on this machine")
            return
        }
        defer { harness.tearDown() }

        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: harness.first.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1)
        guard let event else {
            Issue.record("Expected to synthesize a mouse event")
            return
        }
        #expect(!harness.editor.handleRightMouseDown(event))
    }

    @Test func finishEditingWithoutActiveEditorIsANoOp() {
        guard let harness = TabTitleEditorHarness.make() else {
            Issue.record("Could not build a real native tab bar on this machine")
            return
        }
        defer { harness.tearDown() }

        harness.editor.finishEditing(commit: true)
        #expect(harness.delegate.committedTitle == nil)
        #expect(harness.delegate.finishedWindows.isEmpty)
    }
}

/// Which of a tab button's private labels the inline editor copies its
/// style and frame from. AppKit's tab buttons hold several labels, some
/// hidden, so the choice is a ranked fallback.
@MainActor
struct TabTitleLabelChoiceTests {
    private func label(
        _ text: String,
        width: CGFloat = 50,
        hidden: Bool = false,
        alpha: CGFloat = 1,
        centered: Bool = false
    ) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.frame = NSRect(x: 0, y: 0, width: width, height: 16)
        field.isHidden = hidden
        field.alphaValue = alpha
        field.alignment = centered ? .center : .natural
        return field
    }

    @Test func aVisibleExactMatchWinsOverEverythingElse() {
        let wide = label("other", width: 200, centered: true)
        let hiddenMatch = label("zsh", hidden: true)
        let match = label("  zsh ")
        let chosen = TabTitleEditor.sourceTabTitleLabel(from: [wide, hiddenMatch, match], matching: "zsh")
        #expect(chosen === match)
    }

    @Test func aHiddenExactMatchBeatsTheHeuristic() {
        let wide = label("other", width: 200, centered: true)
        let faded = label("zsh", alpha: 0)
        let chosen = TabTitleEditor.sourceTabTitleLabel(from: [wide, faded], matching: "zsh")
        #expect(chosen === faded)
    }

    @Test func withoutAMatchTheWidestVisibleCenteredLabelWins() {
        let wideLeft = label("left", width: 300)
        let narrowCentered = label("a", width: 40, centered: true)
        let wideCentered = label("b", width: 120, centered: true)
        let hiddenCentered = label("c", width: 500, hidden: true, centered: true)
        let chosen = TabTitleEditor.sourceTabTitleLabel(
            from: [wideLeft, narrowCentered, wideCentered, hiddenCentered], matching: "renamed")
        #expect(chosen === wideCentered)
    }

    @Test func withoutACenteredLabelTheWidestVisibleOneWins() {
        let narrow = label("a", width: 40)
        let wide = label("b", width: 120)
        let empty = label("   ", width: 400)
        let chosen = TabTitleEditor.sourceTabTitleLabel(from: [narrow, wide, empty], matching: "")
        #expect(chosen === wide)
    }

    @Test func withNothingVisibleTheWidestLabelOfAllIsUsed() {
        let hidden = label("a", width: 90, hidden: true)
        let empty = label("", width: 150)
        let chosen = TabTitleEditor.sourceTabTitleLabel(from: [hidden, empty], matching: "x")
        #expect(chosen === empty)
    }

    @Test func noLabelsMeansNoSource() {
        #expect(TabTitleEditor.sourceTabTitleLabel(from: [], matching: "x") == nil)
    }
}
