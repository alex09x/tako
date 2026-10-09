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
        print("[BENCHMARK] 30-pane overview presentation breakdown: refresh=\(Int(tRefresh*1000))ms, layout=\(Int(tLayout*1000))ms, display=\(Int(tDisplay*1000))ms, cacheDisplay=\(Int(tCache*1000))ms -> presentation=\(Int(tPresentation*1000))ms, total=\(Int(elapsed*1000))ms")

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

    // MARK: - Production Overview Interactive First-Frame Presentation Benchmark (Roadmap B6 < 150 ms)

    /// Live window interactive first-frame presentation benchmark measuring the complete wall-clock time
    /// from the production open action trigger (`togglePaneOverview`) to the first presented interactive frame
    /// with 30 active panes across multiple controllers, verified via production presentation callback.
    ///
    /// Validates:
    /// 1. Triggering via production open action (`controller.togglePaneOverview(nil)`).
    /// 2. Live first-frame presentation callback receives exactly 30 items.
    /// 3. Interactive presentation latency completes within budget (< 150 ms).
    /// 4. Synchronous layout and display timing passes are isolated and labeled separately.
    /// 5. Window rendered bitmap contains painted cards and non-blank opaque modal content.
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
            PaneOverviewView.onFirstFramePresented = nil
            window.orderOut(nil)
            window.close()
        }

        // Warm up SwiftUI runtime, SF Symbols, and AppKit rasterizer
        hostingView.layoutSubtreeIfNeeded()
        if let warmupRep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) {
            hostingView.cacheDisplay(in: hostingView.bounds, to: warmupRep)
        }

        // Wire presentation callback measurement
        var recordedElapsed: TimeInterval?
        var recordedItemCount: Int?

        primaryController.onPaneOverviewPresented = { elapsed, count in
            recordedElapsed = elapsed
            recordedItemCount = count
        }

        // Measure live opening time: from production trigger to first presented interactive frame
        let tStart = CFAbsoluteTimeGetCurrent()
        primaryController.togglePaneOverview(nil)
        let tOpenAction = CFAbsoluteTimeGetCurrent() - tStart

        // Measure synchronous layout and display passes separately
        let tL0 = CFAbsoluteTimeGetCurrent()
        hostingView.layoutSubtreeIfNeeded()
        let tSynchronousLayout = CFAbsoluteTimeGetCurrent() - tL0

        let tD0 = CFAbsoluteTimeGetCurrent()
        window.displayIfNeeded()
        let tSynchronousDisplay = CFAbsoluteTimeGetCurrent() - tD0

        // Pump runloop until the first interactive presentation callback fires
        let deadline = Date().addingTimeInterval(2.0)
        while recordedElapsed == nil && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
            CATransaction.flush()
            hostingView.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }

        guard let elapsed = recordedElapsed, let itemCount = recordedItemCount else {
            Issue.record("Overview first-frame presentation callback was not received within 2s timeout")
            return
        }

        print("[BENCHMARK] 30-pane interactive overview presentation breakdown: openAction=\(String(format: "%.1f", tOpenAction*1000))ms, syncLayout=\(String(format: "%.1f", tSynchronousLayout*1000))ms, syncDisplay=\(String(format: "%.1f", tSynchronousDisplay*1000))ms -> interactiveFirstFrame=\(String(format: "%.1f", elapsed*1000))ms (items=\(itemCount))")

        // Assertions
        #expect(primaryController.paneOverviewIsShowing == true, "Pane overview must be showing")
        #expect(itemCount == 30, "Expected 30 items in first interactive frame, got \(itemCount)")
        #expect(elapsed < 0.150, "Interactive first-frame presentation for 30 panes took \(Int(elapsed * 1000)) ms, exceeding 150 ms budget")

        // Visual content assertion on presented frame
        guard let rep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            Issue.record("Failed to create bitmap cache rep for overview window")
            return
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: rep)
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

}
