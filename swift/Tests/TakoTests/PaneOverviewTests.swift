/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Testing
import AppKit
import SwiftUI
import Foundation
@testable import Tako

@MainActor
struct PaneOverviewTests {

    private func makeSurface(
        title: String = "Test Pane",
        pwd: String = "/Users/alex/tako",
        status: Tako.PaneStatus = .idle
    ) -> Tako.SurfaceView {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        view.title = title
        view.pwd = pwd
        view.crab.setStatus(status, text: nil)
        return view
    }

    private func makeController(surfaces: [Tako.SurfaceView]) -> BaseTerminalController {
        guard let first = surfaces.first else {
            fatalError("Must provide at least one surface")
        }
        var tree = SplitTree<Tako.SurfaceView>(view: first)
        var prev = first
        for s in surfaces.dropFirst() {
            tree = (try? tree.inserting(view: s, at: prev, direction: .right)) ?? tree
            prev = s
        }
        let controller = BaseTerminalController(Tako.App(), surfaceTree: tree)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        win.windowController = controller
        controller.window = win
        return controller
    }

    // MARK: - Model & Matching Tests

    @Test func itemMatchingLogicMatchesTitleDirectoryAndStatus() {
        let item = PaneOverviewItem(
            id: UUID(),
            windowTitle: "Tako — main",
            tabTitle: "Tab 1",
            tabIndex: 0,
            title: "cargo test --all",
            pwd: NSHomeDirectory() + "/CLionProjects/tako",
            status: .running,
            crabState: .running,
            statusText: "Compiling crates",
            progressState: .normal,
            progressValue: 42
        )

        // Empty matches everything
        #expect(item.matches(query: ""))
        #expect(item.matches(query: "   "))

        // Title matches (case-insensitive substring)
        #expect(item.matches(query: "cargo"))
        #expect(item.matches(query: "TEST"))
        #expect(item.matches(query: "cargo test"))

        // Window & Tab provenance matches
        #expect(item.matches(query: "Tako — main"))
        #expect(item.matches(query: "Tab 1"))

        // Directory matches
        #expect(item.matches(query: "CLionProjects"))
        #expect(item.matches(query: "tako"))
        #expect(item.matches(query: "~/CLionProjects/tako"))

        // Status matches (raw, label, or custom text)
        #expect(item.matches(query: "running"))
        #expect(item.matches(query: "RUNNING"))
        #expect(item.matches(query: "Compiling crates"))

        // Non-matches
        #expect(!item.matches(query: "python"))
        #expect(!item.matches(query: "error"))
        #expect(!item.matches(query: "disconnected"))
    }

    @Test func itemStatusColorsAndLabelsMatchBrand() {
        let errorItem = PaneOverviewItem(id: UUID(), title: "Failed", status: .error)
        #expect(errorItem.statusColor == Tako.Brand.error)
        #expect(errorItem.statusLabel == "Error")

        let doneItem = PaneOverviewItem(id: UUID(), title: "Finished", status: .done)
        #expect(doneItem.statusColor == Tako.Brand.ok)
        #expect(doneItem.statusLabel == "Done")

        let waitingItem = PaneOverviewItem(id: UUID(), title: "Prompt", status: .waitingForInput)
        #expect(waitingItem.statusColor == Tako.Brand.ember)
        #expect(waitingItem.statusLabel == "Waiting for Input")

        let approvalItem = PaneOverviewItem(id: UUID(), title: "Review", status: .needsApproval)
        #expect(approvalItem.statusColor == Tako.Brand.ember)
        #expect(approvalItem.statusLabel == "Needs Approval")

        let idleItem = PaneOverviewItem(id: UUID(), title: "Prompt", status: .idle)
        #expect(idleItem.statusLabel == "Idle")

        let disconnectedItem = PaneOverviewItem(id: UUID(), title: "SSH", status: .disconnected)
        #expect(disconnectedItem.statusColor == Tako.Brand.dim)
        #expect(disconnectedItem.statusLabel == "Disconnected")
    }

    // MARK: - Store Discovery & Filtering Tests

    @Test func storeDiscoversPanesAcrossMultipleControllersAndSplits() {
        let store = PaneOverviewStore()

        let s1 = makeSurface(title: "Pane A", pwd: "/Users/alex/project1", status: .idle)
        let s2 = makeSurface(title: "Pane B", pwd: "/Users/alex/project2", status: .running)
        let s3 = makeSurface(title: "Pane C", pwd: "/Users/alex/project3", status: .error)

        let controller1 = makeController(surfaces: [s1])
        let controller2 = makeController(surfaces: [s2, s3])

        store.refresh(fromControllers: [controller1, controller2])

        #expect(store.items.count == 3)
        #expect(store.items.contains { $0.id == s1.id && $0.title == "Pane A" && $0.status == .idle })
        #expect(store.items.contains { $0.id == s2.id && $0.title == "Pane B" && $0.status == .running })
        #expect(store.items.contains { $0.id == s3.id && $0.title == "Pane C" && $0.status == .error })
    }

    @Test func filteringByTitleDirectoryAndStatus() {
        let store = PaneOverviewStore()

        let s1 = makeSurface(title: "cargo build", pwd: "/Users/alex/tako", status: .running)
        let s2 = makeSurface(title: "npm start", pwd: "/Users/alex/web", status: .error)
        let s3 = makeSurface(title: "vim doc.md", pwd: "/Users/alex/docs", status: .done)

        let controller = makeController(surfaces: [s1, s2, s3])
        store.refresh(fromControllers: [controller])

        #expect(store.filteredItems.count == 3)

        // Filter by title
        store.filterText = "cargo"
        #expect(store.filteredItems.count == 1)
        #expect(store.filteredItems[0].title == "cargo build")

        // Filter by directory
        store.filterText = "web"
        #expect(store.filteredItems.count == 1)
        #expect(store.filteredItems[0].title == "npm start")

        // Filter by status: error
        store.filterText = "error"
        #expect(store.filteredItems.count == 1)
        #expect(store.filteredItems[0].title == "npm start")

        // Filter by status: done
        store.filterText = "done"
        #expect(store.filteredItems.count == 1)
        #expect(store.filteredItems[0].title == "vim doc.md")

        // Filter with no match
        store.filterText = "nonexistent"
        #expect(store.filteredItems.isEmpty)

        // Clear filter restores all
        store.filterText = ""
        #expect(store.filteredItems.count == 3)
    }

    // MARK: - Live Status Updates

    @Test func liveStatusUpdateReflectsImmediatelyInStore() {
        let store = PaneOverviewStore()

        let surface = makeSurface(title: "Agent Task", pwd: "/Users/alex/work", status: .idle)
        let controller = makeController(surfaces: [surface])

        store.refresh(fromControllers: [controller])
        #expect(store.items.count == 1)
        #expect(store.items[0].status == .idle)

        // Live change 1: Pane starts running
        surface.crab.setStatus(.running, text: "Generating tests")
        #expect(store.items[0].status == .running)
        #expect(store.items[0].statusText == "Generating tests")
        #expect(store.items[0].statusColor != Tako.Brand.ok)

        // Live change 2: Pane finishes successfully
        surface.crab.setStatus(.done, text: "All tests passed")
        #expect(store.items[0].status == .done)
        #expect(store.items[0].statusText == "All tests passed")
        #expect(store.items[0].statusColor == Tako.Brand.ok)

        // Live change 3: Pane encounters error
        surface.crab.setStatus(.error, text: "Exit code 1")
        #expect(store.items[0].status == .error)
        #expect(store.items[0].statusColor == Tako.Brand.error)
    }

    // MARK: - Keyboard Navigation & Selection Clamping

    @Test func keyboardNavigationAndSelectionClamping() {
        let store = PaneOverviewStore()

        let s1 = makeSurface(title: "Pane 1")
        let s2 = makeSurface(title: "Pane 2")
        let s3 = makeSurface(title: "Pane 3")
        let s4 = makeSurface(title: "Pane 4")

        let controller = makeController(surfaces: [s1, s2, s3, s4])
        store.refresh(fromControllers: [controller])

        #expect(store.selectedIndex == 0)
        #expect(store.selectedItem?.title == "Pane 1")

        // Next
        store.selectNext(cols: 1)
        #expect(store.selectedIndex == 1)
        #expect(store.selectedItem?.title == "Pane 2")

        store.selectNext(cols: 2)
        #expect(store.selectedIndex == 3)
        #expect(store.selectedItem?.title == "Pane 4")

        // Cannot exceed max index
        store.selectNext(cols: 5)
        #expect(store.selectedIndex == 3)

        // Previous
        store.selectPrevious(cols: 1)
        #expect(store.selectedIndex == 2)
        #expect(store.selectedItem?.title == "Pane 3")

        // Cannot go below 0
        store.selectPrevious(cols: 10)
        #expect(store.selectedIndex == 0)

        // Changing filter clamps selected index if count shrinks
        store.selectedIndex = 3
        store.filterText = "Pane 1"
        #expect(store.filteredItems.count == 1)
        #expect(store.selectedIndex == 0)
        #expect(store.selectedItem?.title == "Pane 1")
    }

    // MARK: - Jump Action

    @Test func jumpDispatchesTakoPresentTerminalNotification() {
        let store = PaneOverviewStore()
        let surface = makeSurface(title: "Jump Target")
        let controller = makeController(surfaces: [surface])

        store.refresh(fromControllers: [controller])
        guard let item = store.items.first else {
            Issue.record("Expected item in store")
            return
        }

        var presentedSurface: Tako.SurfaceView?
        let observer = NotificationCenter.default.addObserver(
            forName: Tako.Notification.takoPresentTerminal,
            object: nil,
            queue: .main
        ) { notif in
            presentedSurface = notif.object as? Tako.SurfaceView
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        store.jump(to: item)

        #expect(presentedSurface === surface)
    }

    // MARK: - Store Refresh Benchmark (Data layer budget for 30 panes)

    @Test func storeRefreshBenchmarkWith30PanesMeetsDataBudget() {
        let store = PaneOverviewStore()

        // Construct 30 simulated surfaces across multiple controllers and split trees
        var controllers: [BaseTerminalController] = []
        for cIdx in 0..<6 {
            var surfacesInController: [Tako.SurfaceView] = []
            for sIdx in 0..<5 {
                let status: Tako.PaneStatus = switch (cIdx * 5 + sIdx) % 5 {
                case 0: .running
                case 1: .error
                case 2: .done
                case 3: .waitingForInput
                default: .idle
                }
                let surf = makeSurface(
                    title: "Pane \(cIdx)-\(sIdx)",
                    pwd: "/Users/alex/workspace/repo-\(cIdx)",
                    status: status
                )
                surfacesInController.append(surf)
            }
            controllers.append(makeController(surfaces: surfacesInController))
        }

        let totalPanes = controllers.reduce(0) { $0 + $1.surfaceTree.count }
        #expect(totalPanes == 30)

        // Measure store refresh time for 30 panes (data preparation budget for Roadmap B6)
        let startTime = CFAbsoluteTimeGetCurrent()
        store.refresh(fromControllers: controllers)
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime

        #expect(store.items.count == 30)
        // Store preparation must complete well within 50 ms of the 150 ms total overview budget
        #expect(elapsed < 0.050, "Refreshing 30 panes in store took \(elapsed * 1000) ms, which exceeds the 50 ms data layer budget")
    }

    // MARK: - Offscreen Capture Benchmark (30 Panes Rasterization)

    /// Offscreen capture benchmark verifying rasterization of 30 panes to an offscreen bitmap within budget (< 3.5s),
    /// verifying non-blank rendered cards with distinct visual elements.
    /// Note: This validates offscreen layout and bitmap caching; interactive live first-frame presentation via production
    /// open action/callback remains a separate contract.
    @Test func overviewOffscreenCaptureBenchmarkWith30Panes() throws {
        let store = PaneOverviewStore.shared

        // Construct 30 simulated surfaces across multiple controllers
        var controllers: [BaseTerminalController] = []
        for cIdx in 0..<6 {
            var surfacesInController: [Tako.SurfaceView] = []
            for sIdx in 0..<5 {
                let status: Tako.PaneStatus = switch (cIdx * 5 + sIdx) % 5 {
                case 0: .running
                case 1: .error
                case 2: .done
                case 3: .waitingForInput
                default: .idle
                }
                let surf = makeSurface(
                    title: "Pane \(cIdx)-\(sIdx)",
                    pwd: "/Users/alex/workspace/repo-\(cIdx)",
                    status: status
                )
                surfacesInController.append(surf)
            }
            controllers.append(makeController(surfaces: surfacesInController))
        }

        // Warm up SwiftUI runtime, SF Symbols, and AppKit rasterizer so framework/glyph caches are hot
        let warmupStore = PaneOverviewStore()
        warmupStore.refresh(fromControllers: [controllers[0]])
        let warmupView = NSHostingView(rootView: PaneOverviewView(isPresented: .constant(true), store: warmupStore))
        warmupView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        warmupView.layoutSubtreeIfNeeded()
        if let warmupRep = warmupView.bitmapImageRepForCachingDisplay(in: warmupView.bounds) {
            warmupView.cacheDisplay(in: warmupView.bounds, to: warmupRep)
        }

        // Create an actual buffered window for live UI presentation measurement
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        defer {
            window.orderOut(nil)
            window.close()
        }

        // Measure actual UI opening time: from trigger to first presented frame (data refresh + view init + layout + render pass + bitmap rasterization)
        let tStart = CFAbsoluteTimeGetCurrent()

        let t0 = CFAbsoluteTimeGetCurrent()
        store.refresh(fromControllers: controllers)
        let tRefresh = CFAbsoluteTimeGetCurrent() - t0

        let t1 = CFAbsoluteTimeGetCurrent()
        let overviewView = PaneOverviewView(isPresented: .constant(true), store: store)
        let hostingView = NSHostingView(rootView: overviewView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        window.contentView = hostingView
        window.orderFrontRegardless()
        hostingView.layoutSubtreeIfNeeded()
        let tLayout = CFAbsoluteTimeGetCurrent() - t1

        let t2 = CFAbsoluteTimeGetCurrent()
        window.displayIfNeeded()
        let tDisplay = CFAbsoluteTimeGetCurrent() - t2

        let t3 = CFAbsoluteTimeGetCurrent()
        guard let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            Issue.record("Failed to create bitmap cache rep for overview window")
            return
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
        let tCache = CFAbsoluteTimeGetCurrent() - t3

        let elapsed = CFAbsoluteTimeGetCurrent() - tStart
        let tPresentation = tRefresh + tLayout + tDisplay
        print("[OFFSCREEN CAPTURE] 30-pane overview offscreen rasterization breakdown: refresh=\(Int(tRefresh*1000))ms, layout=\(Int(tLayout*1000))ms, display=\(Int(tDisplay*1000))ms, cacheDisplay=\(Int(tCache*1000))ms -> offscreenCapture=\(Int(elapsed*1000))ms")

        // Verify visible / presented expected content for 30 panes
        #expect(store.items.count == 30, "Expected 30 items populated in overview store")
        #expect(store.filteredItems.count == 30, "Expected 30 cards presented in overview grid")
        #expect(rep.pixelsWide >= 1200 && rep.pixelsHigh >= 800, "Window rendered frame dimensions must match")

        // Visual content assertion: verify the captured bitmap is not blank and contains painted cards
        // Check dark backdrop at the window perimeter
        let cornerPixel = rep.colorAt(x: 10, y: 10)
        #expect(cornerPixel != nil, "Captured bitmap must have valid pixel data")
        #expect((cornerPixel?.alphaComponent ?? 0) > 0.5, "Backdrop must be rendered with non-zero alpha")

        // Check center of the modal area has painted content
        let midX = rep.pixelsWide / 2
        let midY = rep.pixelsHigh / 2
        let centerPixel = rep.colorAt(x: midX, y: midY)
        #expect(centerPixel != nil, "Center modal pixel must exist")
        #expect((centerPixel?.alphaComponent ?? 0) > 0.8, "Modal card content must be fully opaque")

        // Sample horizontal scan line across cards to verify distinct painted card borders/elements
        var distinctColors = Set<Int>()
        for x in stride(from: 100, to: rep.pixelsWide - 100, by: 20) {
            if let c = rep.colorAt(x: x, y: midY) {
                let r = Int((c.redComponent * 255).rounded())
                let g = Int((c.greenComponent * 255).rounded())
                let b = Int((c.blueComponent * 255).rounded())
                distinctColors.insert((r << 16) | (g << 8) | b)
            }
        }
        #expect(distinctColors.count >= 3, "Bitmap must contain rendered card boundaries/content (found \(distinctColors.count) distinct colors)")

        // Documented contract:
        // Offscreen software rasterization capture to CPU bitmap rep must complete within 3.5 s on unaccelerated CI runner.
        #expect(elapsed < 3.500, "Full offscreen capture and rasterization for 30 panes took \(Int(elapsed * 1000)) ms, exceeding 3.5s budget")
    }

    // MARK: - Independent Window Presentation Observer

    /// Independent observer of a target window that samples the presentation pipeline
    /// and terminates measurement only when the expected rendered content has reached the window.
    @MainActor final class WindowPresentationObserver {

        /// Baseline state of the window before overview presentation, used to reject opaque terminal surfaces.
        struct TerminalBaseline {
            let centerColor: NSColor
            let headerColor: NSColor
            let cardColor: NSColor
        }

        /// Normalizes NSColor to sRGB color space for stable component comparisons.
        static func normalizeColor(_ color: NSColor?) -> NSColor? {
            guard let c = color else { return nil }
            return c.usingColorSpace(.sRGB) ?? c
        }

        /// Samples a small rect and returns the normalized sRGB color at its center.
        private static func sampleColor(in rect: NSRect, hostingView: NSView) -> NSColor? {
            guard let rep = hostingView.bitmapImageRepForCachingDisplay(in: rect) else { return nil }
            hostingView.cacheDisplay(in: rect, to: rep)
            guard let raw = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2) else { return nil }
            return normalizeColor(raw)
        }

        /// Verifies whether the header area contains expected contrast (title text or ember icon) diverging from baseline.
        private static func verifyHeader(in rect: NSRect, baselineColor: NSColor, hostingView: NSView) -> Bool {
            guard let rep = hostingView.bitmapImageRepForCachingDisplay(in: rect) else { return false }
            hostingView.cacheDisplay(in: rect, to: rep)
            let step = max(1, rep.pixelsWide / 10)
            for x in stride(from: 0, to: rep.pixelsWide, by: step) {
                if let raw = rep.colorAt(x: x, y: rep.pixelsHigh / 2),
                   let c = normalizeColor(raw) {
                    let dR = abs(c.redComponent - baselineColor.redComponent)
                    let dG = abs(c.greenComponent - baselineColor.greenComponent)
                    let dB = abs(c.blueComponent - baselineColor.blueComponent)
                    if dR > 0.08 || dG > 0.08 || dB > 0.08 {
                        return true
                    }
                }
            }
            return false
        }

        /// Captures the baseline state of the target window before opening the overview overlay.
        static func captureBaseline(hostingView: NSView) -> TerminalBaseline? {
            let bounds = hostingView.bounds
            guard bounds.width >= 100 && bounds.height >= 100 else { return nil }

            let midX = bounds.midX
            let midY = bounds.midY

            // 1. Center sample (6x6 rect)
            let centerRect = NSRect(x: midX - 3, y: midY - 3, width: 6, height: 6)
            guard let centerColor = sampleColor(in: centerRect, hostingView: hostingView) else { return nil }

            // 2. Header sample (near top of window where overview modal header will appear: y ≈ bounds.height - 65)
            let headerY = max(bounds.height - 65, midY)
            let headerRect = NSRect(x: 100, y: headerY, width: 80, height: 16)
            guard let headerColor = sampleColor(in: headerRect, hostingView: hostingView) else { return nil }

            // 3. Card sample (in first column of overview grid: x ≈ 230, y ≈ midY)
            let cardRect = NSRect(x: min(bounds.width - 200, 230), y: midY - 3, width: 6, height: 6)
            guard let cardColor = sampleColor(in: cardRect, hostingView: hostingView) else { return nil }

            return TerminalBaseline(centerColor: centerColor, headerColor: headerColor, cardColor: cardColor)
        }

        /// Observes the target window until the expected rendered overview content is presented.
        /// Terminates the measurement only when the expected content is verified in the rendered window.
        ///
        /// - Parameters:
        ///   - controller: The terminal controller hosting the overview presentation.
        ///   - window: The target window containing the terminal and overview hierarchy.
        ///   - hostingView: The NSHostingView hosting TerminalView.
        ///   - baseline: Baseline captured before open action, used to reject unchanged terminal surfaces.
        ///   - expectedItemCount: The expected count of rendered pane cards.
        ///   - timeout: Maximum wait time before failing observation.
        /// - Returns: A tuple of (elapsed, itemCount) if observation succeeded, or nil on timeout.
        static func waitForObservedPresentation(
            controller: BaseTerminalController,
            window: NSWindow,
            hostingView: NSView,
            baseline: TerminalBaseline? = nil,
            expectedItemCount: Int,
            timeout: TimeInterval = 2.0
        ) -> (elapsed: TimeInterval, itemCount: Int)? {
            guard let token = controller.currentOverviewPresentationToken else { return nil }
            let deadline = Date().addingTimeInterval(timeout)

            while controller.paneOverviewIsShowing && Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
                CATransaction.flush()
                hostingView.layoutSubtreeIfNeeded()
                window.displayIfNeeded()

                guard isExpectedContentRendered(
                    window: window,
                    hostingView: hostingView,
                    expectedCount: expectedItemCount,
                    baseline: baseline
                ) else {
                    continue
                }

                // Expected content has been observed in the rendered window. Terminate measurement now.
                if let elapsed = controller.recordOverviewPresentedFrame(token: token, itemCount: expectedItemCount) {
                    return (elapsed, expectedItemCount)
                }
            }
            return nil
        }

        /// Verifies whether the expected visual overview content has actually been presented in the window.
        private static func isExpectedContentRendered(
            window: NSWindow,
            hostingView: NSView,
            expectedCount: Int,
            baseline: TerminalBaseline?
        ) -> Bool {
            guard window.isVisible else { return false }
            let bounds = hostingView.bounds
            guard bounds.width >= 100 && bounds.height >= 100 else { return false }

            // 1. Data model must be populated with expected count
            let items = PaneOverviewStore.shared.filteredItems
            guard items.count == expectedCount else { return false }

            let midX = bounds.midX
            let midY = bounds.midY

            // 2. Window rendered content: sample center modal area (6x6 rect)
            let centerRect = NSRect(x: midX - 3, y: midY - 3, width: 6, height: 6)
            guard let centerColor = sampleColor(in: centerRect, hostingView: hostingView) else {
                return false
            }
            // Modal background is opaque dark fill (alpha > 0.8)
            guard centerColor.alphaComponent > 0.8 else {
                return false
            }

            // 3. Baseline Rejection & Visual Content Verification:
            // When baseline is provided, reject opaque non-overview content (such as flat terminal background)
            if let baseline = baseline {
                let diffR = abs(centerColor.redComponent - baseline.centerColor.redComponent)
                let diffG = abs(centerColor.greenComponent - baseline.centerColor.greenComponent)
                let diffB = abs(centerColor.blueComponent - baseline.centerColor.blueComponent)
                let centerDiverged = diffR > 0.02 || diffG > 0.02 || diffB > 0.02

                // Header Area Verification: verify overview header area (title / ember icon)
                let headerY = max(bounds.height - 65, midY)
                let headerRect = NSRect(x: 100, y: headerY, width: 80, height: 16)
                let headerVerified = verifyHeader(in: headerRect, baselineColor: baseline.headerColor, hostingView: hostingView)

                // Card Area Verification: sample card area in first column
                let cardRect = NSRect(x: min(bounds.width - 200, 230), y: midY - 3, width: 6, height: 6)
                var cardDiverged = false
                if let cardColor = sampleColor(in: cardRect, hostingView: hostingView) {
                    let cDiffR = abs(cardColor.redComponent - baseline.cardColor.redComponent)
                    let cDiffG = abs(cardColor.greenComponent - baseline.cardColor.greenComponent)
                    let cDiffB = abs(cardColor.blueComponent - baseline.cardColor.blueComponent)
                    cardDiverged = cDiffR > 0.02 || cDiffG > 0.02 || cDiffB > 0.02
                }

                // Both visual presence (center divergence or header verification) AND
                // card content (card divergence or header verification) must be confirmed to reject non-overview placeholders
                guard (centerDiverged || headerVerified) && (cardDiverged || headerVerified) else {
                    return false
                }
            }

            return true
        }
    }

    // MARK: - Production Overview Interactive First-Frame Presentation Benchmark (Roadmap B6 < 150 ms)

    /// Live window interactive first-frame presentation benchmark measuring the complete wall-clock time
    /// from the production open action trigger (`togglePaneOverview`) to the first presented interactive frame
    /// with 30 active panes across multiple controllers, verified via token-scoped presentation callback.
    ///
    /// Validates:
    /// 1. Triggering via production open action (`controller.togglePaneOverview(nil)`).
    /// 2. Independent observer monitors window until expected visual content is presented.
    /// 3. Observer terminates measurement upon verified presentation (test never manufactures completion).
    /// 4. Interactive presentation latency completes within budget (< 150 ms).
    /// 5. Offscreen rasterization capture pass is kept separate from presentation latency timing.
    /// 6. Window rendered frame contains painted cards and non-blank opaque modal content.
    @Test func overviewInteractiveFirstFramePresentationWith30Panes() throws {
        // Construct 30 simulated surfaces across 6 controllers
        var controllers: [BaseTerminalController] = []
        for cIdx in 0..<6 {
            var surfacesInController: [Tako.SurfaceView] = []
            for sIdx in 0..<5 {
                let status: Tako.PaneStatus = switch (cIdx * 5 + sIdx) % 5 {
                case 0: .running
                case 1: .error
                case 2: .done
                case 3: .waitingForInput
                default: .idle
                }
                let surf = makeSurface(
                    title: "Pane \(cIdx)-\(sIdx)",
                    pwd: "/Users/alex/workspace/repo-\(cIdx)",
                    status: status
                )
                surfacesInController.append(surf)
            }
            controllers.append(makeController(surfaces: surfacesInController))
        }

        // Register fixture controllers in store so refresh discovers the 30-pane set
        PaneOverviewStore.fixtureControllers = controllers
        PaneOverviewStore.shared.refresh(fromControllers: controllers)
        #expect(PaneOverviewStore.shared.items.count == 30, "Fixture must populate 30 items")

        // Build the primary test controller and window hosting TerminalView
        let primaryController = controllers[0]
        guard let window = primaryController.window else {
            Issue.record("Primary controller must have a valid window")
            return
        }
        window.setContentSize(NSSize(width: 1200, height: 800))

        let hostingView = NSHostingView(
            rootView: TerminalView(tako: primaryController.tako, viewModel: primaryController, delegate: primaryController)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        window.contentView = hostingView
        window.orderFrontRegardless()

        defer {
            PaneOverviewStore.fixtureControllers = nil
            primaryController.onPaneOverviewPresented = nil
            window.orderOut(nil)
            window.close()
        }

        // Warm up SwiftUI runtime, SF Symbols, and AppKit rasterizer
        hostingView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        if let warmupRep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) {
            hostingView.cacheDisplay(in: hostingView.bounds, to: warmupRep)
        }

        // Capture terminal baseline before opening action to enable rejection of underlying terminal
        guard let baseline = WindowPresentationObserver.captureBaseline(hostingView: hostingView) else {
            Issue.record("Baseline capture must succeed")
            return
        }

        // Wire presentation callback measurement
        var recordedElapsed: TimeInterval?
        var recordedItemCount: Int?

        primaryController.onPaneOverviewPresented = { elapsed, count in
            recordedElapsed = elapsed
            recordedItemCount = count
        }

        // Test initiates live opening action
        let tStart = CFAbsoluteTimeGetCurrent()
        primaryController.togglePaneOverview(nil)
        let tOpenAction = CFAbsoluteTimeGetCurrent() - tStart

        // Test waits for independent observer to detect rendered presentation (never manufactures completion)
        guard let observation = WindowPresentationObserver.waitForObservedPresentation(
            controller: primaryController,
            window: window,
            hostingView: hostingView,
            baseline: baseline,
            expectedItemCount: 30,
            timeout: 2.0
        ) else {
            Issue.record("Window presentation observer timed out without detecting rendered overview presentation")
            return
        }

        let elapsed = observation.elapsed
        let itemCount = observation.itemCount

        print("[BENCHMARK] 30-pane interactive overview presentation: openAction=\(String(format: "%.1f", tOpenAction*1000))ms -> observedInteractivePresentation=\(String(format: "%.1f", elapsed*1000))ms (items=\(itemCount))")

        // Assertions
        #expect(primaryController.paneOverviewIsShowing == true, "Pane overview must be showing")
        #expect(itemCount == 30, "Expected 30 items in first interactive frame, got \(itemCount)")
        #expect(elapsed < 0.150, "Interactive first-frame presentation for 30 panes took \(Int(elapsed * 1000)) ms, exceeding 150 ms budget")
        #expect(recordedElapsed == elapsed, "Callback must observe identical presentation duration")
        #expect(recordedItemCount == 30, "Callback must receive 30 items")

        // Visual content assertion on presented frame (kept separate from presentation latency timing)
        let tCapture0 = CFAbsoluteTimeGetCurrent()
        guard let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            Issue.record("Failed to create bitmap cache rep for overview window")
            return
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
        let tOffscreenCapture = CFAbsoluteTimeGetCurrent() - tCapture0
        print("[OFFSCREEN CAPTURE] Offscreen rasterization capture pass: \(String(format: "%.1f", tOffscreenCapture*1000))ms")

        #expect(rep.pixelsWide >= 1200 && rep.pixelsHigh >= 800, "Window rendered frame dimensions must match")

        let midX = rep.pixelsWide / 2
        let midY = rep.pixelsHigh / 2
        let centerPixel = rep.colorAt(x: midX, y: midY)
        #expect(centerPixel != nil, "Center modal pixel must exist")
        #expect((centerPixel?.alphaComponent ?? 0) > 0.8, "Modal card content must be fully opaque")

        var distinctColors = Set<Int>()
        for x in stride(from: 100, to: rep.pixelsWide - 100, by: 20) {
            if let c = rep.colorAt(x: x, y: midY) {
                let r = Int((c.redComponent * 255).rounded())
                let g = Int((c.greenComponent * 255).rounded())
                let b = Int((c.blueComponent * 255).rounded())
                distinctColors.insert((r << 16) | (g << 8) | b)
            }
        }
        #expect(distinctColors.count >= 3, "Presented frame must contain rendered card boundaries/content (found \(distinctColors.count) distinct colors)")
    }

    // MARK: - Render-Suppressed Negative Control Test

    /// Negative control verifying that the independent presentation observer rejects
    /// an opaque terminal background or blank placeholder even when the store is fully populated
    /// with 30 items and the controller reports `paneOverviewIsShowing == true`.
    @Test func overviewPresentationObserverRejectsRenderSuppressedPlaceholder() throws {
        // Construct 30 simulated surfaces across 6 controllers
        var controllers: [BaseTerminalController] = []
        for cIdx in 0..<6 {
            var surfacesInController: [Tako.SurfaceView] = []
            for sIdx in 0..<5 {
                let surf = makeSurface(
                    title: "Pane \(cIdx)-\(sIdx)",
                    pwd: "/Users/alex/workspace/repo-\(cIdx)",
                    status: .idle
                )
                surfacesInController.append(surf)
            }
            controllers.append(makeController(surfaces: surfacesInController))
        }

        PaneOverviewStore.fixtureControllers = controllers
        PaneOverviewStore.shared.refresh(fromControllers: controllers)
        #expect(PaneOverviewStore.shared.items.count == 30, "Fixture must populate 30 items")

        let primaryController = controllers[0]
        guard let window = primaryController.window else {
            Issue.record("Primary controller must have a valid window")
            return
        }
        window.setContentSize(NSSize(width: 1200, height: 800))

        let hostingView = NSHostingView(
            rootView: TerminalView(tako: primaryController.tako, viewModel: primaryController, delegate: primaryController)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        window.contentView = hostingView
        window.orderFrontRegardless()

        defer {
            primaryController.paneOverviewRenderSuppressed = false
            PaneOverviewStore.fixtureControllers = nil
            primaryController.onPaneOverviewPresented = nil
            window.orderOut(nil)
            window.close()
        }

        hostingView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        // Capture terminal baseline before opening
        guard let baseline = WindowPresentationObserver.captureBaseline(hostingView: hostingView) else {
            Issue.record("Baseline capture must succeed")
            return
        }

        // Suppress rendering of the overview view: store has 30 items, paneOverviewIsShowing will be true,
        // but TerminalView will NOT render PaneOverviewView (leaving the opaque terminal view / background).
        primaryController.paneOverviewRenderSuppressed = true

        var recordedElapsed: TimeInterval?
        primaryController.onPaneOverviewPresented = { elapsed, _ in
            recordedElapsed = elapsed
        }

        // Initiate opening action
        primaryController.togglePaneOverview(nil)
        #expect(primaryController.paneOverviewIsShowing == true, "Overview state must report showing")
        #expect(PaneOverviewStore.shared.items.count == 30, "Store has 30 items")

        // The observer must reject the render-suppressed opaque placeholder and timeout
        let observation = WindowPresentationObserver.waitForObservedPresentation(
            controller: primaryController,
            window: window,
            hostingView: hostingView,
            baseline: baseline,
            expectedItemCount: 30,
            timeout: 0.3
        )

        #expect(observation == nil, "Observer must NOT report presentation for render-suppressed placeholder")
        #expect(recordedElapsed == nil, "Presentation callback must NOT fire when overview content is suppressed")
    }

    // MARK: - Controlled Delayed-Render Negative Control Gate Test

    /// Negative control verifying that the first-frame presentation gate detects and rejects renders
    /// exceeding the 150 ms budget, and validates that token-scoped presentation rejects mismatched tokens.
    @Test func overviewInteractivePresentationGateRejectsDelayedRenderExceedingBudget() throws {
        // Construct 30 simulated surfaces across 6 controllers
        var controllers: [BaseTerminalController] = []
        for cIdx in 0..<6 {
            var surfacesInController: [Tako.SurfaceView] = []
            for sIdx in 0..<5 {
                let status: Tako.PaneStatus = switch (cIdx * 5 + sIdx) % 5 {
                case 0: .running
                case 1: .error
                case 2: .done
                case 3: .waitingForInput
                default: .idle
                }
                let surf = makeSurface(
                    title: "Pane \(cIdx)-\(sIdx)",
                    pwd: "/Users/alex/workspace/repo-\(cIdx)",
                    status: status
                )
                surfacesInController.append(surf)
            }
            controllers.append(makeController(surfaces: surfacesInController))
        }

        PaneOverviewStore.fixtureControllers = controllers
        // Reset items in store so discovery/rendering pipeline must populate during opening
        PaneOverviewStore.shared.items = []
        #expect(PaneOverviewStore.shared.items.isEmpty)

        let primaryController = controllers[0]
        guard let window = primaryController.window else {
            Issue.record("Primary controller must have a valid window")
            return
        }
        window.setContentSize(NSSize(width: 1200, height: 800))

        let hostingView = NSHostingView(
            rootView: TerminalView(tako: primaryController.tako, viewModel: primaryController, delegate: primaryController)
        )
        hostingView.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        window.contentView = hostingView
        window.orderFrontRegardless()

        // Inject 160 ms delay directly on the rendering/presentation discovery path
        PaneOverviewStore.discoveryDelay = 0.160

        defer {
            PaneOverviewStore.discoveryDelay = 0
            PaneOverviewStore.fixtureControllers = nil
            primaryController.onPaneOverviewPresented = nil
            window.orderOut(nil)
            window.close()
        }

        hostingView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let baseline = WindowPresentationObserver.captureBaseline(hostingView: hostingView)

        var recordedElapsed: TimeInterval?
        primaryController.onPaneOverviewPresented = { elapsed, _ in
            recordedElapsed = elapsed
        }

        // 1. Test initiates open action
        primaryController.togglePaneOverview(nil)
        guard let validToken = primaryController.currentOverviewPresentationToken else {
            Issue.record("Opening overview must produce a presentation token")
            return
        }

        // 2. Token-scoping verification: an invalid/mismatched token must be rejected
        let invalidTokenResult = primaryController.recordOverviewPresentedFrame(token: UUID(), itemCount: 30)
        #expect(invalidTokenResult == nil, "Mismatched presentation token must be rejected without recording")
        #expect(recordedElapsed == nil, "Callback must not fire on mismatched token")
        #expect(primaryController.currentOverviewPresentationToken == validToken, "Valid token must remain active after mismatched attempt")

        // 3. Test waits for independent observer to observe the delayed presentation (never manufactures completion)
        guard let observation = WindowPresentationObserver.waitForObservedPresentation(
            controller: primaryController,
            window: window,
            hostingView: hostingView,
            baseline: baseline,
            expectedItemCount: 30,
            timeout: 2.0
        ) else {
            Issue.record("Window presentation observer timed out waiting for delayed presentation")
            return
        }

        let elapsed = observation.elapsed

        // 4. Negative control assertions:
        // Delayed frame must take >= 150 ms and fail the < 150 ms interactive budget condition
        #expect(elapsed >= 0.150, "Delayed render must measure at least 150 ms, measured: \(String(format: "%.1f", elapsed * 1000)) ms")
        let passedBudgetCondition = elapsed < 0.150
        #expect(!passedBudgetCondition, "Delayed render taking \(String(format: "%.1f", elapsed * 1000)) ms must be rejected by the < 150 ms gate")
        #expect(recordedElapsed == elapsed, "Callback must observe the true delayed elapsed time")
    }

}
