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
import Combine

// Putting the drawn tab strip where the system's would have been.
//
// Chrome-style: the strip lives *in* the titlebar row, sharing it with the
// traffic lights, not in a strip below them. That means the content view has
// to extend under the titlebar (`fullSizeContentView`) and the strip is a
// plain subview of it, pinned to the top -- a `NSTitlebarAccessoryViewController`
// with `.bottom` (a first pass) puts a whole extra row *under* the traffic
// lights instead, which is not what the design shows.

extension Tako {
    @MainActor
    enum TabBarController {
        static let barHeight: CGFloat = 38

        private static var installedWindows: Set<ObjectIdentifier> = []
        private static let trackedWindows = NSHashTable<NSWindow>.weakObjects()
        private static var installed: [ObjectIdentifier: TabBarView] = [:]
        private static var monitor: Any?
        private static let refreshRequests = TabBarRefreshCoalescer { refreshAll() }

        /// Title bursts need at most one chrome layout per display frame.
        /// Explicit navigation/layout changes still use synchronous refreshAll.
        static func requestRefresh() { refreshRequests.request() }

        static func isInstalled(in window: NSWindow) -> Bool {
            installedWindows.contains(ObjectIdentifier(window))
        }

        static func bar(for window: NSWindow) -> TabBarView? {
            installed[ObjectIdentifier(window)]
        }

        static func install(in window: NSWindow) {
            let key = ObjectIdentifier(window)
            if installedWindows.contains(key) { return }
            installedWindows.insert(key)
            trackedWindows.add(window)

            // fullSizeContentView/titlebarAppearsTransparent/titleVisibility
            // are set in `TerminalWindow.awakeFromNib`, not here -- confirmed
            // live that setting them this late (once the surface view deep in
            // the SwiftUI tree finally attaches and triggers this call) is too
            // late for AppKit to actually extend the content view under the
            // titlebar, even though the properties themselves report true.
            window.tabbingMode = .disallowed // The whole point: AppKit never manages tabbing for this window.
            window.isMovable = false
            window.isMovableByWindowBackground = false

            // Clear `NSTitlebarContainerView`'s opaque gray CALayer background
            // so the permanent left sidebar header and edge-to-edge right
            // terminal render cleanly up to the top window edge.
            clearTitlebarBackground(in: window)
            DispatchQueue.main.async { [weak window] in
                guard let window else { return }
                clearTitlebarBackground(in: window)
            }

            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    if let bar = installed[key], bar.draggingTabIndex != nil || bar.draggingWindow === window {
                        setDragState(in: nil, index: nil, start: nil, isDragging: false)
                    }
                    Tako.CustomTabGroup.close(window)
                    installed.removeValue(forKey: key)
                    installedWindows.remove(key)
                    trackedWindows.remove(window)
                    refreshAll()
                }
            }

            // AppKit re-paints `NSTitlebarContainerView`'s opaque background
            // on its own schedule after window resize, fullscreen exit, and key/main transitions.
            for name: NSNotification.Name in [
                NSWindow.didResizeNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
                NSWindow.didBecomeMainNotification,
                NSWindow.didResignMainNotification,
                NSWindow.didEndLiveResizeNotification,
                NSWindow.didExitFullScreenNotification,
            ] {
                NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { _ in
                    MainActor.assumeIsolated {
                        clearTitlebarBackground(in: window)
                        installed[key]?.needsDisplay = true
                    }
                }
            }
        }

        /// Mounts a standalone `TabBarView` inside `window` for isolated tab-strip
        /// motion/rendering unit tests while desktop windows run without a top bar.
        @discardableResult
        static func installTabBarForTesting(in window: NSWindow) -> TabBarView? {
            install(in: window)
            let key = ObjectIdentifier(window)
            if let existing = installed[key] { return existing }
            guard let contentView = window.contentView else { return nil }
            let bar = TabBarView(frame: .zero)
            bar.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(bar)
            NSLayoutConstraint.activate([
                bar.topAnchor.constraint(equalTo: contentView.topAnchor),
                bar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                bar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                bar.heightAnchor.constraint(equalToConstant: barHeight),
            ])
            installed[key] = bar

            if monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                    MainActor.assumeIsolated {
                        let held = event.modifierFlags.contains(.command)
                        for bar in installed.values { bar.commandKeyChanged(held: held) }
                    }
                    return event
                }
            }
            return bar
        }

        /// Redraw every strip. Cheap, and a tab's contents can change in one
        /// window while another is the one being looked at.
        static func refreshAll() {
            for window in trackedWindows.allObjects {
                clearTitlebarBackground(in: window)
            }
            for bar in installed.values {
                if LivingAnimationState.shared.isTimelinePaused { bar.finishMotion() }
                if let window = bar.window { clearTitlebarBackground(in: window) }
                bar.layoutTabs()
                bar.refresh()
            }
        }

        /// Synchronize drag state across tab bars belonging to the originating
        /// `CustomTabGroup` so selecting a different tab window during mouseDown
        /// preserves the active drag on the newly frontmost window's TabBarView
        /// without leaking drag state to unrelated window groups.
        static func setDragState(
            in group: Tako.CustomTabGroup?,
            draggedWindow: NSWindow? = nil,
            index: Int?,
            start: CGPoint?,
            isDragging: Bool
        ) {
            for bar in installed.values {
                if let group, bar.group === group {
                    bar.draggingTabIndex = index
                    bar.draggingWindow = draggedWindow
                    bar.dragStartPoint = start
                    bar.isTabDragging = isDragging
                } else {
                    bar.draggingTabIndex = nil
                    bar.draggingWindow = nil
                    bar.dragStartPoint = nil
                    bar.isTabDragging = false
                }
            }
        }

        /// Some AppKit-internal operations (resize, appearance change, full
        /// screen transitions) re-apply `NSTitlebarContainerView`'s opaque
        /// gray layer background on their own schedule -- matches upstream's
        /// own note in `HiddenTitlebarTerminalWindow.reapplyHiddenStyle` about
        /// "some operations that appear to bring back the titlebar
        /// visibility". Called from `install`, every `refreshAll`, the
        /// notification hooks below, and every `TabBarView.draw` (confirmed
        /// live: a brand new window can still lose this race once, between
        /// `install` running and its first real paint, before any of those
        /// other triggers fire -- the strip stayed hidden until an unrelated
        /// resize nudged it) so it keeps winning that fight instead of
        /// losing it once.
        static func clearTitlebarBackground(in window: NSWindow) {
            guard let themeFrame = window.contentView?.superview,
                  let titlebarContainer = themeFrame.firstDescendant(withClassName: "NSTitlebarContainerView")
            else { return }
            let titlebar = titlebarContainer.firstDescendant(withClassName: "NSTitlebarView")
            for view in [titlebarContainer, titlebar].compactMap({ $0 }) {
                view.wantsLayer = true
                view.layer?.backgroundColor = NSColor.clear.cgColor
                view.layer?.isOpaque = false
            }
        }

        /// Inset the real content below the strip's row -- the content view
        /// now extends under the titlebar (`fullSizeContentView`), so
        /// whatever the window actually shows needs to start below
        /// `barHeight`, not at the content view's own top edge.
        static func contentTopInset(for window: NSWindow) -> CGFloat {
            installed[ObjectIdentifier(window)] != nil ? barHeight : 0
        }
    }
}
