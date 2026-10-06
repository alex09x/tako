/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

/// Delegate protocol for `TakoTerminalNSView`.
@MainActor
public protocol TakoTerminalNSViewDelegate: AnyObject {
    /// Called when user input (typing, hardware keys, paste, mouse events) produces bytes to send to the PTY.
    func terminalView(_ view: TakoTerminalNSView, sendInputData data: Data)

    /// Called when the terminal engine generates device reply bytes (e.g. DA/DSR/XTVERSION responses) to send to the PTY.
    func terminalView(_ view: TakoTerminalNSView, sendDeviceReplyData data: Data)

    /// Called when the terminal grid dimensions change.
    func terminalView(_ view: TakoTerminalNSView, didResizeCols cols: Int, rows: Int)

    /// A checkpoint was restored into the engine, in parser order.
    ///
    /// Deliberately not `didResizeCols:rows:`: the restored grid is the
    /// canonical one and this view is mirroring it, so its dimensions are
    /// reported, not requested. A host that has a genuinely newer layout
    /// intent sends it back through its own ordered resize path; nothing here
    /// reflows the restored grid on its own.
    func terminalView(_ view: TakoTerminalNSView, didRestoreCheckpoint restore: TerminalCheckpointRestore)

    /// Optional: Called when the terminal window/session title changes.
    func terminalView(_ view: TakoTerminalNSView, didChangeTitle title: String)

    /// Optional: Called when a bell event occurs.
    func terminalViewDidBell(_ view: TakoTerminalNSView)

    /// Shell-integration markers used by hosts to expose command activity.
    func terminalViewCommandDidStart(_ view: TakoTerminalNSView)
    func terminalView(_ view: TakoTerminalNSView, commandDidEnd exitCode: Int32?)

    /// A remote program asked for text to be put on the clipboard (OSC 52).
    ///
    /// Deliberately not written to the pasteboard directly: whether a program on
    /// the other end of a socket may replace what the user last copied is a
    /// policy question, and the host owns it.
    func terminalView(_ view: TakoTerminalNSView, didRequestClipboardCopy text: String)

    /// The shell reported its working directory (OSC 7).
    func terminalView(_ view: TakoTerminalNSView, didChangeWorkingDirectory url: String)

    /// The viewport moved, as a fraction: 0 is the oldest retained line, 1 is
    /// the live screen. A host stores this to restore the position after the
    /// surface is torn down and rebuilt.
    func terminalView(_ view: TakoTerminalNSView, didScrollTo position: Double)

    /// Screen content changed. A host that mirrors the buffer as text -- for
    /// a copy action or an accessibility element -- refreshes on this rather
    /// than polling.
    func terminalViewDidChangeContent(_ view: TakoTerminalNSView)

    /// A command action requested sending text to another pane.
    func terminalView(_ view: TakoTerminalNSView, sendTextToAnotherPane text: String)

    /// The link under the pointer changed on hover or became nil (E8).
    func terminalView(_ view: TakoTerminalNSView, didHoverLink url: String?)

    /// The shell reached an OSC 133 prompt mark (B1).
    func terminalViewPromptMark(_ view: TakoTerminalNSView)

    /// A program set explicit pane status via escape sequence (OSC 1337 / OSC 9;5) (B1).
    func terminalView(_ view: TakoTerminalNSView, didReportStatus status: String, text: String?)

    /// A program cleared explicit pane status via escape sequence (B1).
    func terminalViewDidClearStatus(_ view: TakoTerminalNSView)

    /// A validated source file path was clicked under Command (E6).
    func terminalView(_ view: TakoTerminalNSView, didClickSemanticPath payload: SemanticPathPayload)
}

public extension TakoTerminalNSViewDelegate {
    func terminalView(_ view: TakoTerminalNSView, didRestoreCheckpoint restore: TerminalCheckpointRestore) {}
    func terminalView(_ view: TakoTerminalNSView, didChangeTitle title: String) {}
    func terminalViewDidBell(_ view: TakoTerminalNSView) {}
    func terminalViewCommandDidStart(_ view: TakoTerminalNSView) {}
    func terminalView(_ view: TakoTerminalNSView, commandDidEnd exitCode: Int32?) {}
    func terminalView(_ view: TakoTerminalNSView, didRequestClipboardCopy text: String) {}
    func terminalView(_ view: TakoTerminalNSView, didChangeWorkingDirectory url: String) {}
    func terminalView(_ view: TakoTerminalNSView, didScrollTo position: Double) {}
    func terminalViewDidChangeContent(_ view: TakoTerminalNSView) {}
    func terminalView(_ view: TakoTerminalNSView, sendTextToAnotherPane text: String) {}
    func terminalView(_ view: TakoTerminalNSView, didHoverLink url: String?) {}
    func terminalViewPromptMark(_ view: TakoTerminalNSView) {}
    func terminalView(_ view: TakoTerminalNSView, didReportStatus status: String, text: String?) {}
    func terminalViewDidClearStatus(_ view: TakoTerminalNSView) {}
    func terminalView(_ view: TakoTerminalNSView, didClickSemanticPath payload: SemanticPathPayload) {}
}
#endif
