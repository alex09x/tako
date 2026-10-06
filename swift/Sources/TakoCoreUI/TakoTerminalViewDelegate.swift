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

#if canImport(UIKit)
import UIKit

/// Delegate protocol for `TakoTerminalView`.
@MainActor
public protocol TakoTerminalViewDelegate: AnyObject {
    /// Called when user input (typing, hardware keys, paste, soft keyboard) produces bytes to send to the PTY.
    func terminalView(_ view: TakoTerminalView, sendInputData data: Data)

    /// Called when the terminal engine generates device reply bytes (e.g. DA/DSR/XTVERSION responses) to send to the PTY.
    func terminalView(_ view: TakoTerminalView, sendDeviceReplyData data: Data)

    /// Called when the terminal grid dimensions change.
    func terminalView(_ view: TakoTerminalView, didResizeCols cols: Int, rows: Int)

    /// A checkpoint was restored into the engine, in parser order.
    func terminalView(_ view: TakoTerminalView, didRestoreCheckpoint restore: TerminalCheckpointRestore)

    /// Optional: Called when the terminal window/session title changes.
    func terminalView(_ view: TakoTerminalView, didChangeTitle title: String)

    /// Optional: Called when a bell event occurs.
    func terminalViewDidBell(_ view: TakoTerminalView)

    /// Shell-integration markers used by hosts to expose command activity.
    func terminalViewCommandDidStart(_ view: TakoTerminalView)
    func terminalView(_ view: TakoTerminalView, commandDidEnd exitCode: Int32?)

    /// A remote program asked for text to be put on the clipboard (OSC 52).
    func terminalView(_ view: TakoTerminalView, didRequestClipboardCopy text: String)

    /// The shell reported its working directory (OSC 7).
    func terminalView(_ view: TakoTerminalView, didChangeWorkingDirectory url: String)

    /// The viewport moved, as a fraction: 0 is the oldest retained line, 1 is the live screen.
    func terminalView(_ view: TakoTerminalView, didScrollTo position: Double)

    /// Screen content changed.
    func terminalViewDidChangeContent(_ view: TakoTerminalView)
}

public extension TakoTerminalViewDelegate {
    func terminalView(_ view: TakoTerminalView, didRestoreCheckpoint restore: TerminalCheckpointRestore) {}
    func terminalView(_ view: TakoTerminalView, didChangeTitle title: String) {}
    func terminalViewDidBell(_ view: TakoTerminalView) {}
    func terminalViewCommandDidStart(_ view: TakoTerminalView) {}
    func terminalView(_ view: TakoTerminalView, commandDidEnd exitCode: Int32?) {}
    func terminalView(_ view: TakoTerminalView, didRequestClipboardCopy text: String) {}
    func terminalView(_ view: TakoTerminalView, didChangeWorkingDirectory url: String) {}
    func terminalView(_ view: TakoTerminalView, didScrollTo position: Double) {}
    func terminalViewDidChangeContent(_ view: TakoTerminalView) {}
}
#endif
