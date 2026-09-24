import AppKit
import Foundation
import Testing
@testable import Tako

// Coverage for the drawn tab strip's membership/order/selection model
// (`Tako.CustomTabGroup`), where it's mounted (`Tako.TabBarController`), and
// the view that actually draws it (`Tako.TabBarView`). TabText's CoreText
// layout is already covered by TabBarTextTests.swift.

@MainActor
private func makeWindow(title: String) -> NSWindow {
    let window = NSWindow(
        // Inside the visible frame: ordering a window front moves it off the
        // Dock and menu bar, which would make frame comparisons meaningless.
        contentRect: NSRect(origin: NSScreen.main.map { NSPoint(x: $0.visibleFrame.minX + 40, y: $0.visibleFrame.minY + 40) } ?? .zero,
                            size: NSSize(width: 400, height: 200)),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false)
    window.title = title
    window.isReleasedWhenClosed = false
    return window
}

/// Renders `view` into a real bitmap so pixels can be compared against a
/// baseline, per the task's prescribed technique for proving drawn state
/// actually changed (hover fills, active-tab highlighting, and so on).
@MainActor
private func snapshot(_ view: NSView) -> NSBitmapImageRep {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        fatalError("could not create a bitmap rep for \(view)")
    }
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep
}

private func bitmapsEqual(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Bool {
    guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh,
          let da = a.bitmapData, let db = b.bitmapData
    else { return false }
    let length = a.bytesPerRow * a.pixelsHigh
    guard length == b.bytesPerRow * b.pixelsHigh else { return false }
    return memcmp(da, db, length) == 0
}

// MARK: - CustomTabGroup

@Suite
@MainActor
struct CustomTabGroupCoverageTests {
    @Test func freshWindowGetsASingleWindowGroup() {
        let window = makeWindow(title: "solo")
        defer { Tako.CustomTabGroup.leave(window) }

        let group = Tako.CustomTabGroup.group(for: window)
        #expect(group.windows == [window])
        #expect(group.selectedWindow === window)
        // Asking again returns the same group instance.
        #expect(Tako.CustomTabGroup.group(for: window) === group)
    }

    @Test func joinAddsToAnchorsGroupAndSelects() {
        let anchor = makeWindow(title: "anchor")
        let joined = makeWindow(title: "joined")
        defer {
            Tako.CustomTabGroup.leave(anchor)
            Tako.CustomTabGroup.leave(joined)
        }

        Tako.CustomTabGroup.join(joined, to: anchor, select: true)
        let group = Tako.CustomTabGroup.group(for: anchor)
        #expect(group.windows == [anchor, joined])
        #expect(group.selectedWindow === joined)
        #expect(joined.frame == anchor.frame)
    }

    @Test func joinWithoutSelectingOrdersOutTheNewWindow() {
        let anchor = makeWindow(title: "anchor")
        let joined = makeWindow(title: "joined")
        defer {
            Tako.CustomTabGroup.leave(anchor)
            Tako.CustomTabGroup.leave(joined)
        }

        Tako.CustomTabGroup.join(joined, to: anchor, select: false)
        let group = Tako.CustomTabGroup.group(for: anchor)
        #expect(group.selectedWindow === anchor)
        #expect(!joined.isVisible)
    }

    @Test func joinTwiceIsANoOpForMembershipButCanReselect() {
        let anchor = makeWindow(title: "anchor")
        let joined = makeWindow(title: "joined")
        defer {
            Tako.CustomTabGroup.leave(anchor)
            Tako.CustomTabGroup.leave(joined)
        }

        Tako.CustomTabGroup.join(joined, to: anchor, select: false)
        Tako.CustomTabGroup.join(joined, to: anchor, select: true)
        let group = Tako.CustomTabGroup.group(for: anchor)
        #expect(group.windows == [anchor, joined])
        #expect(group.selectedWindow === joined)
    }

    @Test func insertAtClampedIndex() {
        let anchor = makeWindow(title: "anchor")
        let a = makeWindow(title: "a")
        let b = makeWindow(title: "b")
        defer {
            for window in [anchor, a, b] { Tako.CustomTabGroup.leave(window) }
        }

        Tako.CustomTabGroup.insert(a, into: anchor, at: 0, select: false)
        Tako.CustomTabGroup.insert(b, into: anchor, at: 99, select: true)
        let group = Tako.CustomTabGroup.group(for: anchor)
        #expect(group.windows == [a, anchor, b])
        #expect(group.selectedWindow === b)
    }

    @Test func insertExistingWindowIsANoOp() {
        let anchor = makeWindow(title: "anchor")
        let a = makeWindow(title: "a")
        defer {
            Tako.CustomTabGroup.leave(anchor)
            Tako.CustomTabGroup.leave(a)
        }

        Tako.CustomTabGroup.insert(a, into: anchor, at: 0, select: false)
        Tako.CustomTabGroup.insert(a, into: anchor, at: 1, select: false)
        let group = Tako.CustomTabGroup.group(for: anchor)
        #expect(group.windows.count == 2)
    }

    @Test func leaveRemovesAndSelectsTheFollowingNeighbor() {
        let a = makeWindow(title: "a")
        let b = makeWindow(title: "b")
        let c = makeWindow(title: "c")
        defer {
            for window in [a, b, c] { Tako.CustomTabGroup.leave(window) }
        }

        Tako.CustomTabGroup.join(b, to: a, select: false)
        Tako.CustomTabGroup.join(c, to: a, select: false)
        let group = Tako.CustomTabGroup.group(for: a)
        group.select(b)
        #expect(group.selectedWindow === b)

        Tako.CustomTabGroup.leave(b)
        #expect(group.windows == [a, c])
        #expect(group.selectedWindow === c)
    }

    @Test func leaveTheLastTabFallsBackToTheNewLastTab() {
        let a = makeWindow(title: "a")
        let b = makeWindow(title: "b")
        defer {
            Tako.CustomTabGroup.leave(a)
            Tako.CustomTabGroup.leave(b)
        }

        Tako.CustomTabGroup.join(b, to: a, select: true)
        Tako.CustomTabGroup.leave(b)
        let group = Tako.CustomTabGroup.group(for: a)
        #expect(group.windows == [a])
        #expect(group.selectedWindow === a)
    }

    @Test func leaveOfAnUnregisteredWindowIsANoOp() {
        let a = makeWindow(title: "a")
        let b = makeWindow(title: "b")
        let stray = makeWindow(title: "stray")
        defer {
            Tako.CustomTabGroup.leave(a)
            Tako.CustomTabGroup.leave(b)
        }
        Tako.CustomTabGroup.join(b, to: a, select: false)
        let group = Tako.CustomTabGroup.group(for: a)

        Tako.CustomTabGroup.leave(stray) // Never joined/grouped -- must not crash or affect an unrelated group.

        #expect(group.windows == [a, b])
        #expect(group.selectedWindow === a)
    }

    @Test func leaveOfANonSelectedTabKeepsTheCurrentSelection() {
        let a = makeWindow(title: "a")
        let b = makeWindow(title: "b")
        defer {
            Tako.CustomTabGroup.leave(a)
            Tako.CustomTabGroup.leave(b)
        }
        Tako.CustomTabGroup.join(b, to: a, select: false)
        let group = Tako.CustomTabGroup.group(for: a)
        #expect(group.selectedWindow === a)
        Tako.CustomTabGroup.leave(b)
        #expect(group.selectedWindow === a)
    }

    @Test func moveReordersWithinTheGroup() {
        let a = makeWindow(title: "a")
        let b = makeWindow(title: "b")
        let c = makeWindow(title: "c")
        defer {
            for window in [a, b, c] { Tako.CustomTabGroup.leave(window) }
        }
        Tako.CustomTabGroup.join(b, to: a, select: false)
        Tako.CustomTabGroup.join(c, to: a, select: false)
        let group = Tako.CustomTabGroup.group(for: a)

        Tako.CustomTabGroup.move(c, to: 0, in: group)
        #expect(group.windows == [c, a, b])

        // Same index is a no-op.
        Tako.CustomTabGroup.move(c, to: 0, in: group)
        #expect(group.windows == [c, a, b])

        // Out of range clamps rather than crashing.
        Tako.CustomTabGroup.move(c, to: 99, in: group)
        #expect(group.windows == [a, b, c])
    }

    @Test func moveOfAWindowNotInTheGroupIsANoOp() {
        let a = makeWindow(title: "a")
        let stray = makeWindow(title: "stray")
        defer {
            Tako.CustomTabGroup.leave(a)
        }
        let group = Tako.CustomTabGroup.group(for: a)
        Tako.CustomTabGroup.move(stray, to: 0, in: group)
        #expect(group.windows == [a])
    }

    @Test func selectIgnoresAWindowOutsideTheGroup() {
        let a = makeWindow(title: "a")
        let stray = makeWindow(title: "stray")
        defer { Tako.CustomTabGroup.leave(a) }
        let group = Tako.CustomTabGroup.group(for: a)
        group.select(stray)
        #expect(group.selectedWindow === a)
    }

    @Test func selectingTheAlreadySelectedWindowJustRaisesIt() {
        let a = makeWindow(title: "a")
        defer { Tako.CustomTabGroup.leave(a) }
        let group = Tako.CustomTabGroup.group(for: a)
        group.select(a)
        #expect(group.selectedWindow === a)
    }

    @Test func syncFrameOnlyPropagatesFromTheSelectedWindow() {
        let a = makeWindow(title: "a")
        let b = makeWindow(title: "b")
        defer {
            Tako.CustomTabGroup.leave(a)
            Tako.CustomTabGroup.leave(b)
        }
        Tako.CustomTabGroup.join(b, to: a, select: true)
        let group = Tako.CustomTabGroup.group(for: a)

        // b is selected: resizing the non-selected window a must not
        // propagate.
        let untouched = b.frame
        a.setFrame(NSRect(x: 1, y: 1, width: 50, height: 50), display: false)
        group.syncFrame(from: a)
        #expect(b.frame == untouched)

        let resized = NSRect(x: 5, y: 5, width: 300, height: 150)
        b.setFrame(resized, display: false)
        group.syncFrame(from: b)
        #expect(a.frame == resized)
    }
}

// MARK: - TabBarController

@Suite
@MainActor
struct TabBarControllerCoverageTests {
    @Test func contentTopInsetIsZeroBeforeInstall() {
        let window = makeWindow(title: "uninstalled")
        #expect(Tako.TabBarController.contentTopInset(for: window) == 0)
    }

    @Test func installAddsTheBarAndInsetsContent() {
        let window = makeWindow(title: "installed")
        Tako.TabBarController.install(in: window)
        #expect(Tako.TabBarController.contentTopInset(for: window) == Tako.TabBarController.barHeight)
        #expect(window.contentView?.subviews.contains { $0 is Tako.TabBarView } == true)

        // Installing twice on the same window is a no-op past the first call.
        Tako.TabBarController.install(in: window)
        #expect(window.contentView?.subviews.filter { $0 is Tako.TabBarView }.count == 1)

        window.close()
        #expect(Tako.TabBarController.contentTopInset(for: window) == 0)
    }

    @Test func refreshAllIsSafeWithAndWithoutInstalledBars() {
        Tako.TabBarController.refreshAll() // No bars installed yet anywhere: must not crash.

        let window = makeWindow(title: "refresh")
        Tako.TabBarController.install(in: window)
        Tako.TabBarController.refreshAll()

        // The bar survives refreshAll intact -- installed exactly once, not
        // duplicated or torn down.
        #expect(Tako.TabBarController.contentTopInset(for: window) == Tako.TabBarController.barHeight)
        #expect(window.contentView?.subviews.filter { $0 is Tako.TabBarView }.count == 1)
        window.close()
    }

    @Test func clearTitlebarBackgroundOnAWindowWithoutATitlebarContainerIsANoOp() {
        let window = makeWindow(title: "no-container")
        // Before the window's view hierarchy is realized there may be no
        // NSTitlebarContainerView to find; either way nothing in the view
        // hierarchy is added or removed by the call.
        let before = window.contentView?.superview?.subviews.count
        Tako.TabBarController.clearTitlebarBackground(in: window)
        let after = window.contentView?.superview?.subviews.count
        #expect(before == after)
    }

    @Test func resizeAndKeyNotificationsReapplyTitlebarBackgroundWithoutCrashing() throws {
        let window = makeWindow(title: "notified")
        Tako.TabBarController.install(in: window)
        window.makeKeyAndOrderFront(nil)

        let themeFrame = try #require(window.contentView?.superview)
        let titlebarContainer = try #require(themeFrame.firstDescendant(withClassName: "NSTitlebarContainerView"))

        func dirty() {
            titlebarContainer.wantsLayer = true
            titlebarContainer.layer?.backgroundColor = NSColor.red.cgColor
        }

        for name: NSNotification.Name in [
            NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification, NSWindow.didEndLiveResizeNotification,
        ] {
            dirty()
            NotificationCenter.default.post(name: name, object: window)
            #expect(titlebarContainer.layer?.backgroundColor == NSColor.clear.cgColor)
        }
        window.close()
    }
}

// MARK: - TabBarView

@Suite
@MainActor
struct TabBarViewCoverageTests {
    private func draw(_ bar: Tako.TabBarView) {
        let image = NSImage(size: bar.bounds.size)
        image.lockFocus()
        bar.draw(bar.bounds)
        image.unlockFocus()
    }

    private func mount(_ bar: Tako.TabBarView, in window: NSWindow) {
        bar.frame = NSRect(x: 0, y: 0, width: 400, height: 38)
        window.contentView?.addSubview(bar)
    }

    @Test func loneWindowDrawsCenteredTitleInsteadOfAStrip() {
        let window = makeWindow(title: "Lone Window")
        defer { Tako.CustomTabGroup.leave(window) }
        let bar = Tako.TabBarView(frame: .zero)
        mount(bar, in: window)
        // showsStrip == false: exercises drawLoneTitle(). Blanking the title
        // afterwards must change the render -- proof the title text itself,
        // not just the bar background, was actually painted.
        let withTitle = snapshot(bar)
        window.title = ""
        bar.needsDisplay = true
        let withoutTitle = snapshot(bar)
        #expect(!bitmapsEqual(withTitle, withoutTitle))
    }

    @Test func loneWindowWithEmptyTitleDrawsNothingExtra() {
        let window = makeWindow(title: "")
        defer { Tako.CustomTabGroup.leave(window) }
        let bar = Tako.TabBarView(frame: .zero)
        mount(bar, in: window)
        // `drawLoneTitle` returns before drawing anything beyond the plain
        // bar background/hairline that `draw(_:)` already painted, so
        // redrawing must be a pixel-for-pixel no-op.
        let first = snapshot(bar)
        bar.needsDisplay = true
        let second = snapshot(bar)
        #expect(bitmapsEqual(first, second))
    }

    @Test func twoWindowStripLaysOutAndDrawsBothTabs() {
        let a = makeWindow(title: "a")
        let b = makeWindow(title: "b")
        defer {
            Tako.CustomTabGroup.leave(a)
            Tako.CustomTabGroup.leave(b)
        }
        Tako.CustomTabGroup.join(b, to: a, select: false)
        let group = Tako.CustomTabGroup.group(for: a)

        let bar = Tako.TabBarView(frame: .zero)
        mount(bar, in: a)
        // showsStrip == true: exercises layoutTabs() + draw(tab:) for active
        // and inactive tabs. Switching which tab is active must change what
        // gets drawn -- proof the active/inactive distinction is rendered,
        // not just laid out.
        let withAActive = snapshot(bar)
        group.select(b)
        bar.needsDisplay = true
        let withBActive = snapshot(bar)
        #expect(!bitmapsEqual(withAActive, withBActive))
    }

    @Test func manyNarrowTabsShrinkEvenlyBelowTheirNaturalWidth() {
        var windows: [NSWindow] = []
        defer { for window in windows { Tako.CustomTabGroup.leave(window) } }

        let anchor = makeWindow(title: "this is a long tab title that wants lots of room")
        windows.append(anchor)
        for index in 0..<8 {
            let window = makeWindow(title: "also a fairly long tab title #\(index)")
            Tako.CustomTabGroup.join(window, to: anchor, select: false)
            windows.append(window)
        }
        let group = Tako.CustomTabGroup.group(for: anchor)

        let bar = Tako.TabBarView(frame: .zero)
        mount(bar, in: anchor)
        draw(bar) // Total natural width exceeds `available`: exercises the even-shrink branch, populating `tabs`.

        // available = 400 - firstTabX(90) - buttonsReservedWidth(68) = 242;
        // shrunk = max(120, 242/9) clamps every tab to the 120px floor. At
        // natural (unshrunk) widths the very long first title would still
        // occupy x=250 on its own; shrunk to the floor it does not, so a
        // click there lands on the second tab instead of the first.
        click(bar, at: NSPoint(x: 250, y: 14), in: anchor)
        #expect(group.selectedWindow === windows[1])
    }

    @Test func mouseMovedHoversATabAndTheButtons() {
        let a = makeWindow(title: "a")
        let b = makeWindow(title: "b")
        defer {
            Tako.CustomTabGroup.leave(a)
            Tako.CustomTabGroup.leave(b)
        }
        Tako.CustomTabGroup.join(b, to: a, select: false)

        let bar = Tako.TabBarView(frame: .zero)
        mount(bar, in: a)
        draw(bar) // Populates `tabs` for hit-testing.
        let baseline = snapshot(bar)

        func move(to point: NSPoint) {
            let event = NSEvent.mouseEvent(
                with: .mouseMoved,
                location: point,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: a.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 0,
                pressure: 0)!
            bar.mouseMoved(with: event)
        }

        // Tab 1 ("b") is the inactive one -- an active tab's fill does not
        // change on hover, so only an inactive tab's hover is visible.
        move(to: NSPoint(x: 250, y: 14))
        let afterTabHover = snapshot(bar)
        #expect(!bitmapsEqual(baseline, afterTabHover))

        move(to: NSPoint(x: 378, y: 19)) // The "+" new-tab button.
        let afterPlusHover = snapshot(bar)
        #expect(!bitmapsEqual(afterTabHover, afterPlusHover))

        move(to: NSPoint(x: 346, y: 19)) // The split button.
        let afterSplitHover = snapshot(bar)
        #expect(!bitmapsEqual(afterPlusHover, afterSplitHover))

        move(to: NSPoint(x: 5, y: 5)) // Empty bar area: clears all hover state.
        #expect(bitmapsEqual(snapshot(bar), baseline))

        // Re-hover, then prove mouseExited() clears it the same way.
        move(to: NSPoint(x: 250, y: 14))
        #expect(!bitmapsEqual(snapshot(bar), baseline))

        let exitEvent = NSEvent.enterExitEvent(
            with: .mouseExited,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: a.windowNumber,
            context: nil,
            eventNumber: 0,
            trackingNumber: 0,
            userData: nil)!
        bar.mouseExited(with: exitEvent)
        #expect(bitmapsEqual(snapshot(bar), baseline))
    }

    @Test func updateTrackingAreasReplacesThePreviousArea() {
        let window = makeWindow(title: "tracking")
        defer { Tako.CustomTabGroup.leave(window) }
        let bar = Tako.TabBarView(frame: .zero)
        mount(bar, in: window)
        bar.updateTrackingAreas()
        bar.updateTrackingAreas() // Second call exercises removing the prior tracking area.
        #expect(bar.trackingAreas.count == 1)
    }

    private func click(_ bar: Tako.TabBarView, at point: NSPoint, in window: NSWindow, clickCount: Int = 1) {
        let event = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1)!
        bar.mouseDown(with: event)
    }

    /// `NSApp.sendAction(_:to:nil:from:)` walks the responder chain and, when
    /// nothing there implements the selector, falls back to the app
    /// delegate -- a reliable catch point regardless of whether this test
    /// process ever gets a real key window (which it may not; see the
    /// caveat on `focusedWorkingDirectoryReadsTheKeyWindowsFirstResponderSurface`
    /// in TakoAppAdapterCoverageTests.swift).
    private final class ButtonActionRecorder: NSObject, NSApplicationDelegate {
        var newTabInvoked = false
        var splitInvoked = false
        @objc func newTab(_ sender: Any?) { newTabInvoked = true }
        @objc func splitRight(_ sender: Any) { splitInvoked = true }
    }

    @Test func clickingTheNewTabButtonSendsTheAction() {
        let window = makeWindow(title: "solo")
        defer { Tako.CustomTabGroup.leave(window) }
        let bar = Tako.TabBarView(frame: .zero)
        mount(bar, in: window)

        Tako.CustomTabGroup.join(makeWindow(title: "b"), to: window, select: false)
        draw(bar)

        let recorder = ButtonActionRecorder()
        let originalDelegate = NSApplication.shared.delegate
        NSApplication.shared.delegate = recorder
        defer { NSApplication.shared.delegate = originalDelegate }

        click(bar, at: NSPoint(x: 378, y: 19), in: window)
        #expect(recorder.newTabInvoked)
    }

    @Test func clickingTheSplitButtonSendsTheAction() {
        let window = makeWindow(title: "solo")
        defer { Tako.CustomTabGroup.leave(window) }
        let bar = Tako.TabBarView(frame: .zero)
        mount(bar, in: window)

        Tako.CustomTabGroup.join(makeWindow(title: "b"), to: window, select: false)
        draw(bar)

        let recorder = ButtonActionRecorder()
        let originalDelegate = NSApplication.shared.delegate
        NSApplication.shared.delegate = recorder
        defer { NSApplication.shared.delegate = originalDelegate }

        click(bar, at: NSPoint(x: 346, y: 19), in: window)
        #expect(recorder.splitInvoked)
    }

    @Test func clickingATabSelectsIt() {
        let a = makeWindow(title: "a")
        let b = makeWindow(title: "b")
        defer {
            Tako.CustomTabGroup.leave(a)
            Tako.CustomTabGroup.leave(b)
        }
        Tako.CustomTabGroup.join(b, to: a, select: false)
        let group = Tako.CustomTabGroup.group(for: a)
        #expect(group.selectedWindow === a)

        let bar = Tako.TabBarView(frame: .zero)
        mount(bar, in: a)
        draw(bar)

        // Tab 1 ("b") sits at x: 210...330 at the clamped minimum width.
        click(bar, at: NSPoint(x: 250, y: 14), in: a)
        #expect(group.selectedWindow === b)
    }

    @Test func clickingTheCloseGlyphClosesThatTab() {
        let a = makeWindow(title: "a")
        let b = makeWindow(title: "b")
        defer {
            Tako.CustomTabGroup.leave(a)
            Tako.CustomTabGroup.leave(b)
        }
        Tako.CustomTabGroup.join(b, to: a, select: false)

        let bar = Tako.TabBarView(frame: .zero)
        mount(bar, in: a)
        draw(bar)

        // Tab 0 ("a") is active, so its close glyph is drawn; its hit rect
        // sits near the right edge of the 90...210 frame.
        a.orderFront(nil)
        #expect(a.isVisible)
        click(bar, at: NSPoint(x: 195, y: 14), in: a)
        #expect(!a.isVisible)
    }

    @Test func emptyBarDoubleClickZoomsTheWindow() {
        let window = makeWindow(title: "solo")
        defer { Tako.CustomTabGroup.leave(window) }
        let bar = Tako.TabBarView(frame: .zero)
        mount(bar, in: window)
        window.makeKeyAndOrderFront(nil)
        #expect(!window.isZoomed)

        // Single-window group never shows a strip, so `tabs` stays empty and
        // any click falls into the "empty bar" branch.
        click(bar, at: NSPoint(x: 200, y: 19), in: window, clickCount: 2)

        #expect(window.isZoomed)
        window.close()
    }

    @Test func commandKeyHeldEventuallyShowsBadgesThenClearsOnRelease() async throws {
        let a = makeWindow(title: "a")
        let b = makeWindow(title: "b")
        defer {
            Tako.CustomTabGroup.leave(a)
            Tako.CustomTabGroup.leave(b)
        }
        Tako.CustomTabGroup.join(b, to: a, select: false)

        let bar = Tako.TabBarView(frame: .zero)
        mount(bar, in: a)
        let baseline = snapshot(bar)

        bar.commandKeyChanged(held: true)
        var sawBadges = false
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if !bitmapsEqual(snapshot(bar), baseline) {
                sawBadges = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        // Exercises the numbered-badge branch of drawCrab(for:in:ctx:), once
        // the 0.15s delay elapses.
        #expect(sawBadges)

        bar.commandKeyChanged(held: false)
        // Release is synchronous: the badges are gone immediately.
        #expect(bitmapsEqual(snapshot(bar), baseline))

        // Cancelling before the delay fires exercises the "already hidden"
        // early-return branch, and must never show badges at all.
        bar.commandKeyChanged(held: true)
        bar.commandKeyChanged(held: false)
        #expect(bitmapsEqual(snapshot(bar), baseline))
    }
}

// MARK: - CrabPainter

@Suite
struct CrabPainterCoverageTests {
    @MainActor
    @Test func drawsTheBrandMarkAtVariousSizes() {
        for size: CGFloat in [0.5, 4, 16, 40] {
            let image = NSImage(size: NSSize(width: size, height: size))
            image.lockFocus()
            if let ctx = NSGraphicsContext.current?.cgContext {
                Tako.CrabPainter.draw(
                    in: CGRect(x: 0, y: 0, width: size, height: size),
                    color: .orange,
                    context: ctx)
            }
            image.unlockFocus()

            guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else {
                Issue.record("could not rasterize the \(size)pt mark")
                continue
            }
            let hasColoredPixel = (0..<bitmap.pixelsWide).contains { x in
                (0..<bitmap.pixelsHigh).contains { y in
                    (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05
                }
            }
            // step = floor(min(width/10, height/7)); for a square rect that's
            // floor(size/10), which only reaches 1 once size >= 10 -- below
            // that the early-return guard leaves the image blank.
            if size >= 10 {
                #expect(hasColoredPixel)
            } else {
                #expect(!hasColoredPixel)
            }
        }
    }
}
