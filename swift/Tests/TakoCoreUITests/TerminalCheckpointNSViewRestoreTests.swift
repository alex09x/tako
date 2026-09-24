import Foundation
import XCTest
@testable import TakoCoreUI

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

/// The checkpoint restore as the real macOS surface performs it.
///
/// The coordinator tests prove the barrier's ordering in isolation, against a
/// bare engine. This file proves the thing a host actually holds: an
/// `NSView` with its own grid, its own debounced layout intent and its own
/// sub-row scroll accumulator, all of which describe the terminal that a
/// restore is about to replace. Every one of them is a way for the view to
/// contradict the grid it has just been handed, and none of them is visible
/// from the coordinator.
@MainActor
final class TerminalCheckpointNSViewRestoreTests: XCTestCase {

    /// Records what a restore told the host, kept apart from the resize
    /// callback on purpose: the whole point is that a restore is reported and
    /// never re-enters the view as a resize request.
    @MainActor
    private final class RestoreDelegate: TakoTerminalNSViewDelegate {
        var restores: [TerminalCheckpointRestore] = []
        var resizeCount = 0
        var lastResizedCols: Int?
        var lastResizedRows: Int?
        var contentChangeCount = 0
        var inputDataReceived = Data()

        func terminalView(_ view: TakoTerminalNSView, sendInputData data: Data) {
            inputDataReceived.append(data)
        }

        func terminalView(_ view: TakoTerminalNSView, sendDeviceReplyData data: Data) {}

        func terminalView(_ view: TakoTerminalNSView, didResizeCols cols: Int, rows: Int) {
            resizeCount += 1
            lastResizedCols = cols
            lastResizedRows = rows
        }

        func terminalView(
            _ view: TakoTerminalNSView,
            didRestoreCheckpoint restore: TerminalCheckpointRestore
        ) {
            restores.append(restore)
        }

        func terminalViewDidChangeContent(_ view: TakoTerminalNSView) {
            contentChangeCount += 1
        }
    }

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.accessory)
        MainActor.assumeIsolated {
            TakoTerminalNSView.isMetalDisabledForTesting = true
        }
    }

    private func makeView(width: CGFloat = 600, height: CGFloat = 300) -> TakoTerminalNSView {
        let view = TakoTerminalNSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        let window = NSWindow(
            contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return view
    }

    /// A terminal of a deliberately different shape from any view's default,
    /// so "did the view adopt the restored geometry" cannot pass by accident.
    private func sourceCheckpoint(
        cols: UInt32 = 101, rows: UInt32 = 13, text: String = "restored-from-checkpoint"
    ) throws -> Data {
        let source = TakoCore(cols: cols, rows: rows)
        source.feed(bytes: Data("\(text)\r\n".utf8))
        return try source.checkpointExport(flags: 0, maxBytes: 8 << 20)
    }

    private func scrollEvent(deltaY: Int32, precise: Bool) -> NSEvent? {
        guard let cg = CGEvent(
            scrollWheelEvent2Source: nil,
            units: precise ? .pixel : .line,
            wheelCount: 1,
            wheel1: deltaY, wheel2: 0, wheel3: 0
        ) else { return nil }
        return NSEvent(cgEvent: cg)
    }

    // MARK: - The restore itself

    /// The content and the geometry arrive together, through the view's own
    /// public entry point rather than the coordinator's.
    func testAppKitViewRestoresACheckpointThroughItsOwnImportPath() throws {
        let view = makeView()
        let delegate = RestoreDelegate()
        view.delegate = delegate
        view.feed(data: Data("this terminal is about to be replaced\r\n".utf8))

        let blob = try sourceCheckpoint()
        let restore = try view.importCheckpoint(blob)

        XCTAssertEqual(restore.cols, 101)
        XCTAssertEqual(restore.rows, 13)
        XCTAssertEqual(Int(view.core.cols()), 101, "the engine did not adopt the restored grid")
        XCTAssertEqual(Int(view.core.rows()), 13)
        XCTAssertEqual(view.cols, 101, "the view kept mirroring a grid that no longer exists")
        XCTAssertEqual(view.rows, 13)

        let screen = view.plainText(startRow: 0, maxRows: 2)
        XCTAssertTrue(screen.contains("restored-from-checkpoint"),
                      "restored content never reached the surface: \(screen)")
        XCTAssertFalse(screen.contains("about to be replaced"),
                       "the replaced terminal is still on screen")

        XCTAssertEqual(delegate.restores, [restore],
                       "the host was not told, or was told something else")
        XCTAssertGreaterThanOrEqual(delegate.contentChangeCount, 1)
    }

    /// Reported, not requested. A restored grid is the canonical one; turning
    /// it into `didResizeCols:rows:` would invite the host to reflow the very
    /// state it just asked to be restored.
    func testAppKitRestoreIsReportedAndNeverSynthesizedAsAResize() throws {
        let view = makeView()
        let delegate = RestoreDelegate()
        view.delegate = delegate

        let resizesBefore = delegate.resizeCount
        _ = try view.importCheckpoint(try sourceCheckpoint())

        XCTAssertEqual(delegate.resizeCount, resizesBefore,
                       "the restore was pushed back at the host as a resize")
        XCTAssertEqual(delegate.restores.count, 1)
    }

    /// A debounced layout intent describes the geometry the *view* wanted for
    /// the terminal that has just been thrown away. Letting it fire after the
    /// restore reflows the canonical grid on the mirror's authority.
    func testAppKitRestoreCancelsALayoutResizeIntentQueuedBeforeIt() throws {
        let view = makeView()
        let delegate = RestoreDelegate()
        view.delegate = delegate

        // Schedule, but deliberately do not flush: this is the debounced
        // intent that is in flight when a restore lands.
        view.setFrameSize(NSSize(width: 320, height: 180))
        let requestedCols = view.cols
        let requestedRows = view.rows

        _ = try view.importCheckpoint(try sourceCheckpoint())
        XCTAssertEqual(view.cols, 101)
        XCTAssertEqual(view.rows, 13)

        // Firing the debounce now must find nothing pending.
        view.flushPendingResizeForTesting()

        XCTAssertEqual(Int(view.core.cols()), 101,
                       "a stale layout intent reflowed the restored grid")
        XCTAssertEqual(Int(view.core.rows()), 13)
        XCTAssertEqual(view.cols, 101)
        XCTAssertEqual(view.rows, 13)
        XCTAssertEqual(delegate.resizeCount, 0,
                       "a resize from before the restore was still delivered")
        XCTAssertNotEqual(requestedCols, 101,
                          "fixture is not exercising the case: the pending intent matched")
        XCTAssertNotEqual(requestedRows, 13)
    }

    /// The accumulator holds a fraction of a row measured against the grid the
    /// restore replaces. Carried across, it presents the new grid at an offset
    /// it never agreed to.
    func testAppKitRestoreClearsSubRowScrollMeasuredAgainstTheOldGrid() throws {
        let view = makeView()
        let text = (0..<200).map { "L\($0)" }.joined(separator: "\r\n") + "\r\n"
        view.feed(data: Data(text.utf8))

        view.scrollWheel(with: try XCTUnwrap(scrollEvent(deltaY: 1, precise: true)))
        // Signed, not positive: during a precise gesture the engine is parked
        // a row further back than the eye should see and the accumulator makes
        // the difference up, so the residue against `viewportOffset` is
        // negative. What matters is that there is one at all.
        let fraction = view.presentedScrollRows - CGFloat(view.viewportOffset)
        XCTAssertGreaterThan(abs(fraction), 1e-6,
                             "fixture is not exercising the case: no sub-row offset was presented")

        _ = try view.importCheckpoint(try sourceCheckpoint())

        XCTAssertEqual(view.presentedScrollRows, CGFloat(view.viewportOffset), accuracy: 1e-9,
                       "a sub-row offset from the replaced grid survived the restore")
    }

    // MARK: - Refusal

    /// A refused import is not a partial one. The surface it was aimed at is
    /// the same surface afterwards.
    func testAppKitRejectedImportLeavesTheViewIntact() throws {
        let view = makeView()
        let delegate = RestoreDelegate()
        view.delegate = delegate
        view.feed(data: Data("survivor line\r\n".utf8))

        let colsBefore = view.cols
        let rowsBefore = view.rows
        let screenBefore = view.plainText(startRow: 0, maxRows: 4)

        var corrupt = try sourceCheckpoint()
        corrupt[corrupt.count - 1] ^= 0xFF

        XCTAssertThrowsError(try view.importCheckpoint(corrupt)) { error in
            guard case TakoCheckpointError.Corrupt = error else {
                return XCTFail("expected Corrupt, got \(error)")
            }
            // And the same refusal as a host outside this module reads it.
            XCTAssertFalse(TerminalCheckpointFailure(error).isRecoverableByNegotiation)
            guard case .corrupt = TerminalCheckpointFailure(error) else {
                return XCTFail("classification lost the reason: \(error)")
            }
        }

        XCTAssertEqual(view.cols, colsBefore)
        XCTAssertEqual(view.rows, rowsBefore)
        XCTAssertEqual(Int(view.core.cols()), colsBefore)
        XCTAssertEqual(Int(view.core.rows()), rowsBefore)
        XCTAssertEqual(view.plainText(startRow: 0, maxRows: 4), screenBefore,
                       "a refused import still moved the screen")
        XCTAssertTrue(delegate.restores.isEmpty, "a refused import reported a restore")
        XCTAssertEqual(delegate.resizeCount, 0)
    }

    // MARK: - The ordered resize, on the real surface

    /// The view's layout path now goes through the parser FIFO, and the host
    /// is told the geometry the *engine* ended up with rather than the one the
    /// layout asked for.
    func testAppKitOrderedResizeReportsTheGeometryTheEngineAdopted() throws {
        let view = makeView()
        let delegate = RestoreDelegate()
        view.delegate = delegate

        // Bytes still in the queue when the resize is requested: the reflow
        // must take its turn behind them, not race them.
        view.enqueue(data: Data(String(repeating: "x", count: 4096).utf8))

        view.setFrameSize(NSSize(width: 320, height: 180))
        view.flushPendingResizeForTesting()

        XCTAssertEqual(delegate.resizeCount, 1, "the host was told once, after the engine agreed")
        XCTAssertEqual(delegate.lastResizedCols, Int(view.core.cols()),
                       "the host was told the requested geometry, not the adopted one")
        XCTAssertEqual(delegate.lastResizedRows, Int(view.core.rows()))
        XCTAssertEqual(view.parserCoordinator.suppressedOutcomeCount, 0,
                       "an ordered resize discarded outcomes parsed before it")
    }

    /// A resize and a restore travel the one queue, so the surface cannot end
    /// up describing a grid that is half of each.
    func testAppKitResizeAndRestoreShareTheOneOrder() throws {
        let view = makeView()
        let delegate = RestoreDelegate()
        view.delegate = delegate

        view.enqueue(data: Data("before\r\n".utf8))
        view.setFrameSize(NSSize(width: 320, height: 180))
        view.flushPendingResizeForTesting()
        let adoptedCols = Int(view.core.cols())

        _ = try view.importCheckpoint(try sourceCheckpoint())

        XCTAssertEqual(delegate.resizeCount, 1, "the resize was replayed or lost across the restore")
        XCTAssertEqual(delegate.restores.count, 1)
        XCTAssertNotEqual(adoptedCols, 101, "fixture is not exercising the case")
        XCTAssertEqual(Int(view.core.cols()), 101, "the restored grid did not win")
        XCTAssertEqual(view.cols, 101)
    }

    /// A refused import leaves the *presented* view alone too, not just the
    /// engine.
    ///
    /// Fail-intact is a promise about what the user sees. Clearing the
    /// sub-row accumulator before handing the blob to the engine breaks it on
    /// exactly the paths the typed errors exist for -- a corrupt payload, an
    /// unreadable version, an over-budget container -- by jumping the viewport
    /// a fraction of a row for an import that never happened.
    func testAppKitRejectedImportLeavesTheSubRowScrollWhereItWas() throws {
        let view = makeView()
        let delegate = RestoreDelegate()
        view.delegate = delegate
        let text = (0..<200).map { "L\($0)" }.joined(separator: "\r\n") + "\r\n"
        view.feed(data: Data(text.utf8))

        view.scrollWheel(with: try XCTUnwrap(scrollEvent(deltaY: 1, precise: true)))
        let presentedBefore = view.presentedScrollRows
        let offsetBefore = view.viewportOffset
        let fraction = presentedBefore - CGFloat(offsetBefore)
        XCTAssertGreaterThan(abs(fraction), 1e-6,
                             "fixture is not exercising the case: no sub-row offset was presented")

        let colsBefore = view.cols
        let rowsBefore = view.rows
        let screenBefore = view.plainText(startRow: 0, maxRows: 4)
        let epochBefore = view.core.stateEpoch()

        var corrupt = try sourceCheckpoint()
        corrupt[corrupt.count - 1] ^= 0xFF
        XCTAssertThrowsError(try view.importCheckpoint(corrupt))

        XCTAssertEqual(view.presentedScrollRows, presentedBefore, accuracy: 1e-9,
                       "a refused import moved the presented viewport")
        XCTAssertEqual(view.viewportOffset, offsetBefore)
        XCTAssertEqual(view.cols, colsBefore)
        XCTAssertEqual(view.rows, rowsBefore)
        XCTAssertEqual(view.plainText(startRow: 0, maxRows: 4), screenBefore)
        XCTAssertEqual(view.core.stateEpoch(), epochBefore, "a refused import bumped the epoch")
        XCTAssertTrue(delegate.restores.isEmpty)
        XCTAssertEqual(delegate.resizeCount, 0)
    }

}

#endif
