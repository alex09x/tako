import Foundation
import UIKit
import XCTest
@testable import TakoCore

/// Polls `condition` on the main actor until it is true or `timeout`
/// elapses, sleeping between checks rather than blocking the run loop --
/// `enqueue(data:)` finishes its parsing off Main and applies the result on
/// a later main-queue hop, so a synchronous wait would never see it land.
@MainActor
func pollUntil(
    timeout: TimeInterval = 3,
    interval: TimeInterval = 0.02,
    _ condition: () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline { return condition() }
        try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
    }
    return true
}

/// Wires a `TakoTerminalView` back to a `Session` the same way
/// `TerminalSurface.Coordinator` does in the app, so a test can mount a real
/// surface on a session and exercise the input/output path `LaunchProbe`
/// and `Session.receive` actually use, without pulling in SwiftUI.
///
/// Also records every `sendInputData` call, since that -- one call per
/// `insertText` -- is the thing `LaunchProbe`'s "one character per
/// insertText" behaviour is checked against.
@MainActor
final class RecordingTerminalDelegate: NSObject, TakoTerminalViewDelegate {
    private weak var session: Session?
    private(set) var sentInputs: [Data] = []
    var onContentChanged: (() -> Void)?

    init(session: Session) {
        self.session = session
    }

    func terminalView(_ view: TakoTerminalView, sendInputData data: Data) {
        sentInputs.append(data)
        guard let session else { return }
        session.sendInput(session.keyRow.applyingControl(to: data))
    }

    func terminalView(_ view: TakoTerminalView, sendDeviceReplyData data: Data) {
        session?.sendDeviceReply(data)
    }

    func terminalView(_ view: TakoTerminalView, didResizeCols cols: Int, rows: Int) {
        session?.handleResize(cols: cols, rows: rows)
    }

    func terminalView(_ view: TakoTerminalView, didChangeTitle title: String) {
        session?.title = title
    }

    func terminalViewDidBell(_ view: TakoTerminalView) {
        session?.handleBell()
    }

    func terminalViewCommandDidStart(_ view: TakoTerminalView) {
        session?.commandDidStart()
    }

    func terminalView(_ view: TakoTerminalView, commandDidEnd exitCode: Int32?) {
        session?.commandDidEnd(exitCode: exitCode)
    }

    func terminalViewDidChangeContent(_ view: TakoTerminalView) {
        onContentChanged?()
    }
}

/// A mounted surface plus its delegate, kept alive together -- `Session`
/// holds the view only `weak`, so a test that lets the delegate (which owns
/// no reference back) go out of scope would find `session.surface` nilled
/// out from under it.
@MainActor
struct MountedSurface {
    let view: TakoTerminalView
    let delegate: RecordingTerminalDelegate

    init(session: Session) {
        let view = TakoTerminalView(core: session.core)
        let delegate = RecordingTerminalDelegate(session: session)
        view.delegate = delegate
        session.surface = view
        self.view = view
        self.delegate = delegate
    }
}

extension Session {
    /// What the screen shows. `bufferText()` returns every row, each with its
    /// trailing blanks trimmed, so the rows below the last line come back as
    /// bare newlines; exact comparisons want them gone.
    var screenText: String {
        var text = core.bufferText()
        while text.hasSuffix("\n") { text.removeLast() }
        return text
    }
}
