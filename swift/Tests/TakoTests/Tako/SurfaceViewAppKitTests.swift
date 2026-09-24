// Every `y` here moved down by one cell when the shim's own copy of this
// geometry was deleted in favour of the surface's.
//
// AppKit wants the *bottom* edge of the character rect in unflipped
// coordinates. Row `r` in a 400pt view of 20pt cells spans 400-(r+1)*20 up to
// 400-r*20, so the origin is the former. The shim returned the latter -- the
// top edge -- which put the dictation indicator one row above the cell it
// belonged to. These expectations encoded that, so they moved with the fix.
@testable import Tako
import Foundation
import Testing

// The input-method geometry these exercise now lives on the terminal
// surface itself, which is main-actor isolated.
@MainActor
struct SurfaceViewAppKitTests {
    @Test(arguments: [
        ("\u{0008}", true),
        ("\u{001F}", true),
        ("\u{007F}", false),
        (" ", false),
        ("h", false),
        ("", false),
        ("\u{0009}x", false),
        ("\u{0009}\u{0009}", false),
    ])
    func suppressesOnlySingleC0ControlTextWhileComposing(
        text: String,
        expected: Bool
    ) {
        #expect(
            Tako.SurfaceView.shouldSuppressComposingControlInput(
                text,
                composing: true
            ) == expected
        )
    }

    @Test func doesNotSuppressControlTextWhenNotComposing() {
        #expect(
            Tako.SurfaceView.shouldSuppressComposingControlInput(
                "\u{0008}",
                composing: false
            ) == false
        )
    }

    @Test func doesNotSuppressMissingText() {
        #expect(
            Tako.SurfaceView.shouldSuppressComposingControlInput(
                nil,
                composing: true
            ) == false
        )
    }

    @Test func dictationInsertionRectIsZeroWidthAndTracksSpokenText() {
        let rect = Tako.SurfaceView.inputMethodViewRect(
            cursorCol: 2,
            cursorRow: 3,
            cols: 10,
            rows: 10,
            cellSize: CGSize(width: 10, height: 20),
            viewHeight: 400,
            range: NSRange(location: 7, length: 0)
        )

        #expect(rect == CGRect(x: 90, y: 320, width: 0, height: 20))
    }

    @Test func nonemptyInputRectKeepsTheCursorCellBounds() {
        let rect = Tako.SurfaceView.inputMethodViewRect(
            cursorCol: 2,
            cursorRow: 3,
            cols: 10,
            rows: 10,
            cellSize: CGSize(width: 10, height: 20),
            viewHeight: 400,
            range: NSRange(location: 7, length: 4)
        )

        #expect(rect == CGRect(x: 20, y: 320, width: 10, height: 20))
    }

    @Test func longDictationInsertionRectWrapsToTheNextGridRow() {
        let rect = Tako.SurfaceView.inputMethodViewRect(
            cursorCol: 2,
            cursorRow: 3,
            cols: 10,
            rows: 10,
            cellSize: CGSize(width: 10, height: 20),
            viewHeight: 400,
            range: NSRange(location: 9, length: 0)
        )

        #expect(rect == CGRect(x: 10, y: 300, width: 0, height: 20))
    }

    @Test func dictationInsertionRectStaysVisibleAfterFillingTheLastRow() {
        let rect = Tako.SurfaceView.inputMethodViewRect(
            cursorCol: 8,
            cursorRow: 9,
            cols: 10,
            rows: 10,
            cellSize: CGSize(width: 10, height: 20),
            viewHeight: 400,
            range: NSRange(location: 100, length: 0)
        )

        #expect(rect == CGRect(x: 100, y: 200, width: 0, height: 20))
    }
}
