import Testing
import SwiftUI
import AppKit
import Combine
@testable import Tako

/// Records calls instead of performing the real (heavy, AppKit-driving)
/// logic `BaseTerminalController` would, so the `TerminalView` handler
/// methods below can be asserted against directly.
@MainActor
private final class RecordingDelegate: TerminalViewModel, TerminalViewDelegate {
    @Published var surfaceTree: SplitTree<Tako.SurfaceView>
    @Published var commandPaletteIsShowing = false

    var focusedSurfaceDidChangeCalls: [Tako.SurfaceView?] = []
    var pwdDidChangeCalls: [URL?] = []
    var cellSizeDidChangeCalls: [NSSize] = []
    var performSplitActionCalls: [TerminalSplitOperation] = []
    var performActionCalls: [(String, Tako.SurfaceView)] = []

    init(surfaceView: Tako.SurfaceView) {
        surfaceTree = .init(view: surfaceView)
    }

    func focusedSurfaceDidChange(to: Tako.SurfaceView?) { focusedSurfaceDidChangeCalls.append(to) }
    func pwdDidChange(to: URL?) { pwdDidChangeCalls.append(to) }
    func cellSizeDidChange(to: NSSize) { cellSizeDidChangeCalls.append(to) }
    func performAction(_ action: String, on surfaceView: Tako.SurfaceView) { performActionCalls.append((action, surfaceView)) }
    func performSplitAction(_ action: TerminalSplitOperation) { performSplitActionCalls.append(action) }
}

@MainActor
struct TerminalViewCoverageTests {
    private func makeController() -> BaseTerminalController {
        let view = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        return BaseTerminalController(Tako.App(), surfaceTree: .init(view: view))
    }

    @Test func bodyBuildsWhileLoading() {
        let controller = makeController()
        controller.tako.readiness = .loading
        let view = TerminalView(tako: controller.tako, viewModel: controller, delegate: controller)
        _ = view.body
    }

    @Test func bodyBuildsOnError() {
        let controller = makeController()
        controller.tako.readiness = .error
        let view = TerminalView(tako: controller.tako, viewModel: controller, delegate: controller)
        _ = view.body
    }

    @Test func bodyBuildsWhenReady() {
        let controller = makeController()
        controller.tako.readiness = .ready
        let view = TerminalView(tako: controller.tako, viewModel: controller, delegate: controller)
        _ = view.body
    }

    @Test func bodyBuildsWithoutADelegate() {
        let controller = makeController()
        controller.tako.readiness = .ready
        let view = TerminalView(tako: controller.tako, viewModel: controller, delegate: nil)
        _ = view.body
    }

    @Test func debugBuildWarningViewBuilds() {
        let view = DebugBuildWarningView()
        _ = view.body
    }

    @Test func handleFocusedSurfaceChangeForwardsNonNilValuesToTheDelegate() {
        let surfaceView = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        let delegate = RecordingDelegate(surfaceView: surfaceView)
        let controller = makeController()
        let view = TerminalView(tako: controller.tako, viewModel: delegate, delegate: delegate)
        view.handleFocusedSurfaceChange(surfaceView)
        #expect(delegate.focusedSurfaceDidChangeCalls == [surfaceView])
    }

    @Test func handleFocusedSurfaceChangeIgnoresNilValues() {
        let surfaceView = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        let delegate = RecordingDelegate(surfaceView: surfaceView)
        let controller = makeController()
        let view = TerminalView(tako: controller.tako, viewModel: delegate, delegate: delegate)
        view.handleFocusedSurfaceChange(nil)
        #expect(delegate.focusedSurfaceDidChangeCalls.isEmpty)
    }

    @Test func handlePwdChangeForwardsToTheDelegate() {
        let surfaceView = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        let delegate = RecordingDelegate(surfaceView: surfaceView)
        let controller = makeController()
        let view = TerminalView(tako: controller.tako, viewModel: delegate, delegate: delegate)
        let url = URL(fileURLWithPath: "/tmp")
        view.handlePwdChange(url)
        #expect(delegate.pwdDidChangeCalls == [url])
    }

    @Test func handleCellSizeChangeIgnoresNilAndForwardsAValue() {
        let surfaceView = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        let delegate = RecordingDelegate(surfaceView: surfaceView)
        let controller = makeController()
        let view = TerminalView(tako: controller.tako, viewModel: delegate, delegate: delegate)
        view.handleCellSizeChange(nil)
        #expect(delegate.cellSizeDidChangeCalls.isEmpty)
        view.handleCellSizeChange(NSSize(width: 8, height: 16))
        #expect(delegate.cellSizeDidChangeCalls == [NSSize(width: 8, height: 16)])
    }

    @Test func handleSplitActionForwardsToTheDelegate() {
        let surfaceView = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        let delegate = RecordingDelegate(surfaceView: surfaceView)
        let controller = makeController()
        let view = TerminalView(tako: controller.tako, viewModel: delegate, delegate: delegate)
        let operation = TerminalSplitOperation.resize(.init(node: .leaf(view: surfaceView), ratio: 0.5))
        view.handleSplitAction(operation)
        #expect(delegate.performSplitActionCalls.count == 1)
    }

    @Test func handlePerformActionForwardsToTheDelegate() {
        let surfaceView = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        let delegate = RecordingDelegate(surfaceView: surfaceView)
        let controller = makeController()
        let view = TerminalView(tako: controller.tako, viewModel: delegate, delegate: delegate)
        view.handlePerformAction("copy", on: surfaceView)
        #expect(delegate.performActionCalls.count == 1)
        #expect(delegate.performActionCalls.first?.0 == "copy")
        #expect(delegate.performActionCalls.first?.1 == surfaceView)
    }

    @Test func debugBuildWarningHandleTapDoesNotCrash() {
        // `isPopover`'s `@State` storage has no location outside of a live
        // SwiftUI render tree, so writes to it don't persist on a bare
        // struct -- this only exercises that the handler runs safely.
        var view = DebugBuildWarningView()
        view.handleTap()
        #expect(true)
    }
}
