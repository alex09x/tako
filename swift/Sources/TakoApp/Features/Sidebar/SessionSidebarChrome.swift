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
import SwiftUI

/// Window-chrome header strip above the permanent left Session Sidebar.
/// Reserves space for standard macOS traffic lights on the left column and
/// preserves window dragging and double-click zoom across the free header area
/// while leaving the right-hand terminal pane completely edge-to-edge.
enum SessionSidebarChrome {
    static let titlebarStripHeight: CGFloat = 32
    static let hiddenTitlebarStripHeight: CGFloat = 16

    @MainActor
    static func showsTitlebarStrip(for window: NSWindow?) -> Bool {
        topStripHeight(for: window) > 0
    }

    @MainActor
    static func topStripHeight(for window: NSWindow?) -> CGFloat {
        guard let window else { return 0 }
        guard window.styleMask.contains(.titled), !window.styleMask.contains(.fullScreen) else {
            return 0
        }
        if let controller = window.windowController as? BaseTerminalController,
           controller.fullscreenStyle?.isFullscreen == true {
            return 0
        }
        if window is HiddenTitlebarTerminalWindow {
            return hiddenTitlebarStripHeight
        }
        if (window is TerminalWindow) || window.styleMask.contains(.fullSizeContentView) {
            return titlebarStripHeight
        }
        return 0
    }
}

final class SidebarTitlebarDragView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("SidebarWindowDragRegion")
        setAccessibilityLabel("Window drag area")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override var mouseDownCanMoveWindow: Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        handleWindowChromeMouseDown(event)
    }

    func handleWindowChromeMouseDown(_ event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            window.performZoom(nil)
        } else {
            let wasMovable = window.isMovable
            window.isMovable = true
            window.performDrag(with: event)
            window.isMovable = wasMovable
        }
    }
}

struct SidebarTitlebarDragStrip: NSViewRepresentable {
    func makeNSView(context: Context) -> SidebarTitlebarDragView {
        SidebarTitlebarDragView(frame: .zero)
    }

    func updateNSView(_ nsView: SidebarTitlebarDragView, context: Context) {}
}

struct SidebarWindowChromeBar: View {
    let window: NSWindow?
    @State private var revision: Int = 0

    var body: some View {
        let _ = revision
        let height = SessionSidebarChrome.topStripHeight(for: window)
        Group {
            if height > 0 {
                SidebarTitlebarDragStrip()
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            revision &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            revision &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: .fullscreenDidExit)) { _ in
            revision &+= 1
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { notif in
            if let win = notif.object as? NSWindow, win === window {
                revision &+= 1
            }
        }
    }
}
