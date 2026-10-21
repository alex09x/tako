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
import Testing
@testable import Tako

/// A tab group on a clock of the test's own, a strip mounted in every tab's
/// window as the app has it.
@MainActor
final class StripScene {
    var now: CFTimeInterval = 1_000
    let windows: [NSWindow]
    private(set) var bars: [Tako.TabBarView] = []

    /// What the scene found and set aside to force motion on, put back on close.
    private var restore: (() -> Void)?

    /// With `motionOn` (the default) the strip moves whatever the host says
    /// -- Reduce Motion off, no window counted as covered -- so a test of its
    /// motion never passes or fails by the test Mac's own screen. A test of
    /// Reduce Motion or of the pause sets those itself and passes false.
    init(tabs: Int, style: Tako.Config.TabStyle = .pill, motionOn: Bool = true) {
        if motionOn {
            let motion = LivingAnimationState.shared
            let (reduce, watched) = (motion.reduceMotionSource, motion.windowsToWatch)
            motion.reduceMotionSource = { false }
            motion.windowsToWatch = { [] }
            motion.refreshReduceMotion()
            motion.recomputeOcclusion()
            restore = {
                motion.reduceMotionSource = reduce
                motion.windowsToWatch = watched
                motion.refreshReduceMotion()
                motion.recomputeOcclusion()
            }
        }
        windows = (0..<tabs).map { makeWindow(title: "tab \($0)") }
        Tako.TabStripTransitions.clock = { [unowned self] in self.now }
        for window in windows.dropFirst() { Tako.CustomTabGroup.join(window, to: windows[0], select: false) }
        for window in windows {
            // Installed as the app installs it: drags reach only the strips the controller knows.
            window.setContentSize(NSSize(width: 900, height: 200))
            Tako.TabBarController.install(in: window)
            window.contentView?.layoutSubtreeIfNeeded()
            let bar = Tako.TabBarController.bar(for: window)!
            bar.styleOverride = style
            bars.append(bar)
        }
        group.select(windows[0])
        windows[0].orderFrontRegardless()
        now += 5   // everything above has come to rest
    }

    var group: Tako.CustomTabGroup { Tako.CustomTabGroup.group(for: windows[0]) }

    /// The strip of the window shown now.
    var shown: Tako.TabBarView {
        let selected = group.selectedWindow ?? windows[0]
        return bars[windows.firstIndex { $0 === selected } ?? 0]
    }

    /// The shown strip's tabs at the scene's clock.
    func laid() -> [Tako.TabBarView.Tab] {
        shown.layoutTabs()
        return shown.tabs
    }

    func frame(of window: NSWindow) -> CGRect? {
        laid().first { $0.window === window }?.frame
    }

    func close(adding extra: [NSWindow] = []) {
        for window in windows + extra {
            Tako.CustomTabGroup.leave(window)
            window.close()
        }
        Tako.TabStripTransitions.clock = { CACurrentMediaTime() }
        restore?()
        restore = nil
    }

    static func event(_ type: NSEvent.EventType, at point: CGPoint, in bar: Tako.TabBarView) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: bar.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                           windowNumber: bar.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                           clickCount: 1, pressure: 1)!
    }
}

/// The tab strip's transitions (Terminal UI «Вкладки: анатомия, состояния,
/// переходы»): growing, collapsing, the travelling bar, the lifted tab, its
/// neighbours and its spring, the buttons' hover, the tooltips' delay.
@Suite(.serialized) @MainActor
struct MotionTabStripTests {
    @Test func theNumbersAreTheDesigns() {
        typealias T = Tako.TabStripTransitions
        #expect(T.appearDuration == MotionSpec.tabAppear)
        #expect(T.closeDuration == MotionSpec.tabClose)
        #expect(T.barDuration == MotionSpec.tabBarSlide)
        #expect(T.reorderDuration == MotionSpec.tabReorder)
        #expect(T.hoverDuration == MotionSpec.buttonHover)
        #expect(T.springStiffness == MotionSpec.dropSpring.stiffness && T.springDamping == MotionSpec.dropSpring.damping)
        #expect(T.liftTiltDegrees == MotionSpec.liftTilt)
        #expect(T.liftShadowOffset == MotionSpec.liftShadow.offset && T.liftShadowBlur == MotionSpec.liftShadow.blur
                && T.liftShadowAlpha == MotionSpec.liftShadow.alpha)
        #expect(Tako.tooltipDelayMilliseconds == MotionSpec.tooltipDelayMs)
    }

    @Test(arguments: [0.0, 0.25, 0.5, 0.75, 1.0])
    func theCurvesAreCSSs(_ k: Double) {
        typealias T = Tako.TabStripTransitions
        #expect(abs(T.appearFactor(elapsed: k * MotionSpec.tabAppear) - CGFloat(MotionSpec.cssEaseOut(k))) < 0.001)
        #expect(abs(T.closeFactor(elapsed: k * MotionSpec.tabClose) - CGFloat(1 - MotionSpec.cssEaseIn(k))) < 0.001)
        #expect(abs(T.barProgress(elapsed: k * MotionSpec.tabBarSlide) - CGFloat(MotionSpec.cssEaseOut(k))) < 0.001)
        #expect(abs(T.hoverAlpha(elapsed: k * MotionSpec.buttonHover) - CGFloat(MotionSpec.cssEaseOut(k))) < 0.001)
    }

    @Test func theDropSpringOvershootsAFewPercentAndSettles() {
        let x0: CGFloat = 100
        let path = stride(from: 0.0, through: 0.6, by: 0.005).map { Tako.TabStripTransitions.springRemaining(x0, elapsed: $0) }
        let undershoot = -(path.min() ?? 0)
        // 300/24, mass 1: damping ratio 0.69, an overshoot of about 5 %.
        #expect(undershoot > 3 && undershoot < 7, "overshoot \(undershoot) % of the way")
        #expect(abs(path.last ?? x0) < 0.5)
        #expect(Tako.TabStripTransitions.springRemaining(x0, elapsed: 0.05) < x0 * 0.9)
    }

    @Test func aNewTabGrowsFromNothingIn160msAndItsContentComesAfter() throws {
        let scene = StripScene(tabs: 2)
        let new = makeWindow(title: "new")
        defer { scene.close(adding: [new]) }
        let right = scene.windows[1]
        let restX = try #require(scene.frame(of: right)).minX
        Tako.CustomTabGroup.insert(new, into: scene.windows[0], at: 1, select: false)
        let full = try #require(scene.frame(of: new)).width
        let started = scene.now

        let born = try #require(scene.laid().first { $0.window === new })
        #expect(born.frame.width < 1 && !born.showsContent, "a new tab starts at \(born.frame.width) pt")

        scene.now = started + MotionSpec.tabAppear / 2
        _ = scene.shown.expireMotion()
        let half = try #require(scene.laid().first { $0.window === new })
        let k = CGFloat(MotionSpec.cssEaseOut(0.5))
        let fullWidth = scene.shown.restingTabs.first { $0.window === new }?.frame.width ?? full
        #expect(abs(half.frame.width - fullWidth * k) < 1.5, "half way it is \(half.frame.width) of \(fullWidth)")
        #expect(!half.showsContent)
        let pushed = try #require(scene.frame(of: right)).minX
        #expect(pushed > restX + 1, "the next tab was not pushed along: \(restX) -> \(pushed)")

        scene.now = started + MotionSpec.tabAppear + 0.01
        let grown = try #require(scene.laid().first { $0.window === new })
        #expect(abs(grown.frame.width - fullWidth) < 0.5 && grown.showsContent)
    }

    @Test func aClosedTabCollapsesIn140msAndItsNeighboursCloseUp() throws {
        let scene = StripScene(tabs: 3)
        defer { scene.close() }
        let gone = scene.windows[1], right = scene.windows[2]
        let before = try #require(scene.frame(of: right)).minX
        let started = scene.now
        Tako.CustomTabGroup.leave(gone)
        gone.orderOut(nil)
        scene.now = started + 1
        let after = try #require(scene.frame(of: right)).minX   // at rest: where it ends up
        #expect(after < before - 10)

        scene.now = started + MotionSpec.tabClose / 2
        _ = scene.shown.expireMotion()
        let mid = try #require(scene.frame(of: right)).minX
        let k = CGFloat(MotionSpec.cssEaseIn(0.5))
        #expect(abs(mid - (before + (after - before) * k)) < 1.5, "half way at \(mid), from \(before) to \(after)")
        scene.now = started + MotionSpec.tabClose + 0.01
        #expect(abs(try #require(scene.frame(of: right)).minX - after) < 0.5)
    }

    @Test func choosingATabMovesOnlyTheBarIn120ms() throws {
        let scene = StripScene(tabs: 3, style: .classic)
        defer { scene.close() }
        let from = try #require(scene.frame(of: scene.windows[0]))
        let started = scene.now
        scene.group.select(scene.windows[2])
        let to = try #require(scene.frame(of: scene.windows[2]))
        // The content changes at once: the new tab is the active one now.
        #expect(scene.laid().first { $0.window === scene.windows[2] }?.isActive == true)

        scene.now = started + MotionSpec.tabBarSlide / 2
        _ = scene.laid()
        let bar = try #require(scene.shown.activeBarFrame)
        let k = CGFloat(MotionSpec.cssEaseOut(0.5))
        #expect(abs(bar.minX - (from.minX + (to.minX - from.minX) * k)) < 1.5, "the bar is at \(bar.minX), \(from.minX) -> \(to.minX)")
        scene.now = started + MotionSpec.tabBarSlide + 0.01
        _ = scene.laid()
        #expect(abs((scene.shown.activeBarFrame?.minX ?? 0) - to.minX) < 0.5)
    }

    @Test func aDraggedTabIsLiftedAndFollowsThePointer() throws {
        let scene = StripScene(tabs: 3)
        defer { scene.close() }
        let bar = scene.shown
        let first = try #require(scene.frame(of: scene.windows[0]))
        let grab = CGPoint(x: first.minX + 20, y: first.midY)
        bar.mouseDown(with: StripScene.event(.leftMouseDown, at: grab, in: bar))
        bar.mouseDragged(with: StripScene.event(.leftMouseDragged, at: CGPoint(x: grab.x + 30, y: grab.y), in: bar))
        #expect(bar.isTabDragging)
        let lifted = try #require(scene.frame(of: scene.windows[0]))
        #expect(abs(lifted.minX - (first.minX + 30)) < 0.5, "the lifted tab is at \(lifted.minX), the pointer took it to \(first.minX + 30)")
        let tab = try #require(bar.tabs.first { $0.window === scene.windows[0] })
        #expect(bar.liftTilt(for: tab) == MotionSpec.liftTilt)

        // Drawn, its ring turns with it.
        let image = NSImage(size: bar.bounds.size)
        image.lockFocus()
        bar.draw(bar.bounds)
        image.unlockFocus()
        let ring = try #require(bar.statusLayers[ObjectIdentifier(scene.windows[0])])
        let turned = atan2(ring.transform.m12, ring.transform.m11) * 180 / .pi
        #expect(abs(turned + MotionSpec.liftTilt) < 0.1, "the ring turned \(turned)°")
        bar.mouseUp(with: StripScene.event(.leftMouseUp, at: CGPoint(x: grab.x + 30, y: grab.y), in: bar))
        image.lockFocus()
        bar.draw(bar.bounds)
        image.unlockFocus()
        #expect(abs(atan2(ring.transform.m12, ring.transform.m11)) < 0.001, "the ring stayed turned after the drop")
    }

    /// Drawn while lifted, the tab casts its shadow below it and leans:
    /// "тень 0 14px 30px rgba(0,0,0,.55), наклон −3°".
    @Test func aLiftedTabCastsItsShadowAndLeans() throws {
        let scene = StripScene(tabs: 3)
        defer { scene.close() }
        let bar = scene.shown
        func drawn() -> NSBitmapImageRep {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bar.bounds.width), pixelsHigh: Int(bar.bounds.height),
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            bar.draw(bar.bounds)
            NSGraphicsContext.restoreGraphicsState()
            return rep
        }
        func light(_ rep: NSBitmapImageRep, x: Int, cgY: Int) -> CGFloat {
            guard let c = rep.colorAt(x: x, y: rep.pixelsHigh - 1 - cgY) else { return 0 }
            return c.redComponent + c.greenComponent + c.blueComponent
        }
        let resting = try #require(scene.frame(of: scene.windows[0]))
        let still = drawn()
        let grab = CGPoint(x: resting.minX + 20, y: resting.midY)
        bar.mouseDown(with: StripScene.event(.leftMouseDown, at: grab, in: bar))
        bar.mouseDragged(with: StripScene.event(.leftMouseDragged, at: CGPoint(x: grab.x + 30, y: grab.y), in: bar))
        defer { bar.mouseUp(with: StripScene.event(.leftMouseUp, at: CGPoint(x: grab.x + 30, y: grab.y), in: bar)) }
        let lifted = try #require(scene.frame(of: scene.windows[0]))
        let up = drawn()
        // The shadow: the strip just below the lifted tab is darker than at rest.
        let below = max(1, Int(lifted.minY) - 2)
        let xs = stride(from: Int(lifted.minX) + 10, to: Int(lifted.maxX) - 10, by: 4)
        let shaded = xs.map { light(up, x: $0, cgY: below) }.reduce(0, +)
        let plain = xs.map { light(still, x: $0, cgY: below) }.reduce(0, +)
        #expect(shaded < plain - 0.05, "no shadow under the lifted tab: \(shaded) vs \(plain)")
        // The lean: the tab's top edge is lower at one end than the other.
        func isFill(_ rep: NSBitmapImageRep, x: Int, cgY: Int) -> Bool {
            guard let c = rep.colorAt(x: x, y: rep.pixelsHigh - 1 - cgY) else { return false }
            return abs(c.redComponent - 0x24 / 255) < 0.03 && abs(c.greenComponent - 0x1C / 255) < 0.03 && abs(c.blueComponent - 0x16 / 255) < 0.03
        }
        func top(_ rep: NSBitmapImageRep, x: Int) -> Int {
            (Int(lifted.minY) - 4...min(rep.pixelsHigh - 1, Int(lifted.maxY) + 8)).last { isFill(rep, x: x, cgY: $0) } ?? -1
        }
        let left = top(up, x: Int(lifted.minX) + 12), right = top(up, x: Int(lifted.maxX) - 12)
        #expect(abs(left - right) >= 3, "the lifted tab does not lean: its top at \(left) and \(right)")
    }

    @Test func aButtonsHoverFillIsTheDesigns241C16() {
        let c = Tako.TabBarView.Palette.activeTab.usingColorSpace(.sRGB)!
        #expect([c.redComponent, c.greenComponent, c.blueComponent].map { Int(($0 * 255).rounded()) } == [0x24, 0x1C, 0x16])
    }

    @Test func neighboursMakeRoomIn120msAndTheDroppedTabSpringsHome() throws {
        let scene = StripScene(tabs: 3)
        defer { scene.close() }
        let bar = scene.shown
        let a = try #require(scene.frame(of: scene.windows[0]))
        let b = try #require(scene.frame(of: scene.windows[1]))
        let grab = CGPoint(x: a.minX + 10, y: a.midY)
        bar.mouseDown(with: StripScene.event(.leftMouseDown, at: grab, in: bar))
        // Past the next tab's far side: the two change places.
        let past = CGPoint(x: b.maxX - 2, y: a.midY)
        bar.mouseDragged(with: StripScene.event(.leftMouseDragged, at: CGPoint(x: grab.x + 6, y: grab.y), in: bar))
        let reordered = scene.now
        bar.mouseDragged(with: StripScene.event(.leftMouseDragged, at: past, in: bar))
        #expect(scene.group.visibleWindows.firstIndex(of: scene.windows[0]) == 1, "no reorder")

        let neighbourStart = try #require(scene.frame(of: scene.windows[1])).minX
        #expect(abs(neighbourStart - b.minX) < 1, "the neighbour jumped: \(b.minX) -> \(neighbourStart)")
        scene.now = reordered + MotionSpec.tabReorder / 2
        let neighbourMid = try #require(scene.frame(of: scene.windows[1])).minX
        scene.now = reordered + MotionSpec.tabReorder + 0.01
        let neighbourEnd = try #require(scene.frame(of: scene.windows[1])).minX
        let k = CGFloat(MotionSpec.cssEaseOut(0.5))
        #expect(abs(neighbourEnd - a.minX) < 1, "the neighbour ends at \(neighbourEnd), not where the dragged tab was")
        #expect(abs(neighbourMid - (neighbourStart + (neighbourEnd - neighbourStart) * k)) < 1.5, "half way at \(neighbourMid)")

        let held = try #require(scene.frame(of: scene.windows[0])).minX
        let dropped = scene.now
        bar.mouseUp(with: StripScene.event(.leftMouseUp, at: past, in: bar))
        scene.now = dropped + 1
        let home = try #require(scene.frame(of: scene.windows[0])).minX
        scene.now = dropped
        #expect(abs(try #require(scene.frame(of: scene.windows[0])).minX - held) < 0.5, "it jumped home on release")
        var overshoot: CGFloat = 0
        for step in stride(from: 0.0, through: 0.6, by: 0.01) {
            scene.now = dropped + step
            let x = try #require(scene.frame(of: scene.windows[0])).minX
            overshoot = max(overshoot, (x - home) * (held > home ? -1 : 1))
        }
        #expect(overshoot > 0.2 && overshoot < abs(held - home) * 0.08, "the spring overshot \(overshoot) of \(abs(held - home))")
        scene.now = dropped + 0.61
        #expect(abs(try #require(scene.frame(of: scene.windows[0])).minX - home) < 0.5)
    }

    @Test func aButtonsHoverComesInOver80ms() {
        let scene = StripScene(tabs: 2)
        defer { scene.close() }
        let bar = scene.shown
        let t0 = scene.now
        #expect(bar.buttonHoverAlpha("plus", hovered: true) < 0.01)
        scene.now = t0 + MotionSpec.buttonHover / 2
        #expect(abs(bar.buttonHoverAlpha("plus", hovered: true) - CGFloat(MotionSpec.cssEaseOut(0.5))) < 0.01)
        scene.now = t0 + MotionSpec.buttonHover
        #expect(bar.buttonHoverAlpha("plus", hovered: true) > 0.99)
        #expect(bar.buttonHoverAlpha("plus", hovered: false) == 0, "the hover goes at once")
    }

    /// The hover as drawn: the split button's fill is #241C16 once it has
    /// come in, and the strip's own colour there without the hover.
    @Test func aHoveredButtonIsDrawnFilledWithTheDesigns241C16() throws {
        let scene = StripScene(tabs: 2)
        defer { scene.close() }
        let bar = scene.shown
        func pixel() throws -> NSColor {
            let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(bar.bounds.width), pixelsHigh: Int(bar.bounds.height),
                                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            bar.draw(bar.bounds)
            NSGraphicsContext.restoreGraphicsState()
            // Inside the button, clear of its glyph: a few points in from its left side.
            let r = bar.splitRect
            return try #require(rep.colorAt(x: Int(r.minX + 3), y: rep.pixelsHigh - 1 - Int(r.midY)))
        }
        #expect(bar.splitRect.width > 0)
        let plain = try pixel()
        bar.splitHovered = true
        _ = try pixel()   // the hover begins
        scene.now += MotionSpec.buttonHover + 0.01
        let hovered = try pixel()
        let rgb = [hovered.redComponent, hovered.greenComponent, hovered.blueComponent].map { Int(($0 * 255).rounded()) }
        #expect(zip(rgb, [0x24, 0x1C, 0x16]).allSatisfy { abs($0 - $1) <= 3 }, "the hovered button is drawn \(rgb)")
        #expect(abs(plain.redComponent - hovered.redComponent) > 0.01 || abs(plain.greenComponent - hovered.greenComponent) > 0.01,
                "the button looks the same with the pointer off it")
    }

    @Test func tooltipsShowAfter800ms() throws {
        let suite = "test.tako.tooltip.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        Tako.registerTooltipDelay(in: defaults)
        #expect(defaults.integer(forKey: "NSInitialToolTipDelay") == MotionSpec.tooltipDelayMs)
    }

    @Test func aStripNobodySeesTakesEveryChangeAtOnce() throws {
        let scene = StripScene(tabs: 2)
        let new = makeWindow(title: "new")
        defer { scene.close(adding: [new]) }
        let hidden = scene.bars[1]   // the second tab's strip, its window ordered out
        Tako.CustomTabGroup.insert(new, into: scene.windows[0], at: 1, select: false)
        hidden.layoutTabs()
        let tab = try #require(hidden.tabs.first { $0.window === new })
        #expect(tab.showsContent && tab.frame.width > 50, "a hidden strip animated: \(tab.frame.width)")
    }
}
