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

        private static var installed: [ObjectIdentifier: TabBarView] = [:]
        private static var monitor: Any?

        static func install(in window: NSWindow) {
            let key = ObjectIdentifier(window)
            if installed[key] != nil { return }

            // fullSizeContentView/titlebarAppearsTransparent/titleVisibility
            // are set in `TerminalWindow.awakeFromNib`, not here -- confirmed
            // live that setting them this late (once the surface view deep in
            // the SwiftUI tree finally attaches and triggers this call) is too
            // late for AppKit to actually extend the content view under the
            // titlebar, even though the properties themselves report true.
            window.tabbingMode = .disallowed // The whole point: AppKit never manages tabbing for this window.

            // `titlebarAppearsTransparent` alone does not make the native
            // titlebar see-through here: confirmed live that `NSTitlebarContainerView`
            // -- a sibling of the content view at the NSThemeFrame level,
            // drawn *above* it, hosting `NSTitlebarView` (traffic lights) --
            // has its own CALayer with an explicit opaque gray
            // `backgroundColor`, set by AppKit independently of that
            // property. Clearing that layer's background directly is what
            // actually lets the custom bar drawn inside the content view
            // show through.
            clearTitlebarBackground(in: window)

            guard let contentView = window.contentView else { return }
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

            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    Tako.CustomTabGroup.leave(window)
                    installed.removeValue(forKey: key)
                    refreshAll()
                }
            }

            // AppKit re-paints `NSTitlebarContainerView`'s opaque background
            // on its own schedule -- confirmed live it comes back after
            // ordinary window resize and key/main transitions, not just once
            // at creation. Fight it on exactly those triggers rather than
            // continuously (a KVO-driven fight over native tab bar visibility
            // earlier in this window's history turned into ~887k calls/min).
            for name: NSNotification.Name in [
                NSWindow.didResizeNotification,
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
                NSWindow.didEndLiveResizeNotification,
            ] {
                NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { _ in
                    MainActor.assumeIsolated { clearTitlebarBackground(in: window) }
                }
            }

            // The command-number badges need the raw modifier state, which
            // only a monitor reports while no key is being pressed.
            if monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                    MainActor.assumeIsolated {
                        let held = event.modifierFlags.contains(.command)
                        for bar in installed.values { bar.commandKeyChanged(held: held) }
                    }
                    return event
                }
            }
        }

        /// Redraw every strip. Cheap, and a tab's contents can change in one
        /// window while another is the one being looked at.
        static func refreshAll() {
            for bar in installed.values {
                if let window = bar.window { clearTitlebarBackground(in: window) }
                bar.refresh()
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
            titlebarContainer.wantsLayer = true
            titlebarContainer.layer?.backgroundColor = NSColor.clear.cgColor
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
