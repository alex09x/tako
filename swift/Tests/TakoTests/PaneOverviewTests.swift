import Testing
import AppKit
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

    // MARK: - Latency Benchmark (< 150 ms with 30 panes)

    @Test func openLatencyBenchmarkWith30PanesMeets150msBudget() {
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

        // Measure open/refresh time for 30 panes
        let startTime = CFAbsoluteTimeGetCurrent()
        store.refresh(fromControllers: controllers)
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime

        #expect(store.items.count == 30)
        // Roadmap B6 Done criteria: "Done when the overview opens in under 150 ms with 30 panes and reflects status changes live."
        #expect(elapsed < 0.150, "Opening 30 panes took \(elapsed * 1000) ms, which exceeds the 150 ms budget")
    }
}
