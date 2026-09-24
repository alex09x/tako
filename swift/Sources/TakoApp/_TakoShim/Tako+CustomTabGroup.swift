import AppKit

// Replaces NSWindowTabGroup for windows with tabbingMode = .disallowed.
//
// AppKit's native tab bar cannot be hidden and stay hidden while a window's
// tabbingMode allows tabbing at all -- confirmed live: it re-asserts
// isTabBarVisible on its own layout schedule regardless of anything a
// titlebar accessory does (a reactive toggle spun into hundreds of
// thousands of calls a minute fighting it). The only way to show
// TabBarView's own styling instead is for AppKit to never manage tabbing
// for these windows in the first place -- tabbingMode = .disallowed --
// which means membership, order, and selection have to be modelled here
// instead of read from `window.tabGroup`. Verified first in an isolated
// standalone prototype (multi-window create/switch/close, 0% idle CPU, no
// native bar ever appeared) before this port.

extension Tako {
    @MainActor
    final class CustomTabGroup {
        private(set) var windows: [NSWindow] = []
        private(set) var selectedWindow: NSWindow?

        private static var groupsByWindow: [ObjectIdentifier: CustomTabGroup] = [:]

        /// The group a window belongs to, creating a fresh single-window
        /// group the first time a window is asked about.
        static func group(for window: NSWindow) -> CustomTabGroup {
            if let existing = groupsByWindow[ObjectIdentifier(window)] {
                return existing
            }
            let group = CustomTabGroup()
            group.windows = [window]
            group.selectedWindow = window
            groupsByWindow[ObjectIdentifier(window)] = group
            return group
        }

        /// Add `window` to the same group as `anchor`, dropping it from
        /// whatever single-window group it was in on its own (every window
        /// starts in one via `group(for:)` the moment anything asks).
        static func join(_ window: NSWindow, to anchor: NSWindow, select: Bool) {
            let target = group(for: anchor)
            groupsByWindow[ObjectIdentifier(window)] = target
            guard !target.windows.contains(window) else {
                if select { target.select(window) }
                return
            }
            // Match the shared frame so switching to it is never a visible
            // jump -- the new tab's window was created at its own cascaded
            // position, not the group's.
            window.setFrame(anchor.frame, display: false)
            target.windows.append(window)
            if select {
                target.select(window)
            } else {
                window.orderOut(nil)
            }
            Tako.TabBarController.refreshAll()
        }

        /// Insert `window` into `anchor`'s group at a specific index (used
        /// by undo, which restores tabs to their original position).
        static func insert(_ window: NSWindow, into anchor: NSWindow, at index: Int, select: Bool) {
            let target = group(for: anchor)
            groupsByWindow[ObjectIdentifier(window)] = target
            guard !target.windows.contains(window) else { return }
            window.setFrame(anchor.frame, display: false)
            let clamped = max(0, min(index, target.windows.count))
            target.windows.insert(window, at: clamped)
            if select {
                target.select(window)
            } else {
                window.orderOut(nil)
            }
            Tako.TabBarController.refreshAll()
        }

        /// Drop a window from its group entirely, e.g. on close. Selecting
        /// its neighbor mirrors native tab-close behavior (the tab to the
        /// right takes focus, or the new last tab if it was rightmost).
        static func leave(_ window: NSWindow) {
            guard let group = groupsByWindow[ObjectIdentifier(window)] else { return }
            groupsByWindow.removeValue(forKey: ObjectIdentifier(window))
            guard let index = group.windows.firstIndex(of: window) else { return }
            group.windows.remove(at: index)
            if group.selectedWindow === window {
                let next = index < group.windows.count ? group.windows[index] : group.windows.last
                group.selectedWindow = next
                next?.makeKeyAndOrderFront(nil)
            }
            Tako.TabBarController.refreshAll()
        }

        /// Reorder a window within its own group (Cmd+Shift+[/]).
        static func move(_ window: NSWindow, to index: Int, in group: CustomTabGroup) {
            guard let current = group.windows.firstIndex(of: window) else { return }
            let clamped = max(0, min(index, group.windows.count - 1))
            guard clamped != current else { return }
            group.windows.remove(at: current)
            group.windows.insert(window, at: clamped)
            TabBarController.refreshAll()
        }

        func select(_ window: NSWindow) {
            guard windows.contains(window) else { return }
            guard selectedWindow !== window else { window.makeKeyAndOrderFront(nil); return }
            let previous = selectedWindow
            selectedWindow = window
            window.setFrame(previous?.frame ?? window.frame, display: false)
            window.makeKeyAndOrderFront(nil)
            previous?.orderOut(nil)
            Tako.TabBarController.refreshAll()
        }

        /// Keep every tab's frame in sync so a hidden one is never shown
        /// stale geometry when it's brought forward -- called on resize of
        /// whichever window is currently selected.
        func syncFrame(from window: NSWindow) {
            guard selectedWindow === window else { return }
            for sibling in windows where sibling !== window {
                sibling.setFrame(window.frame, display: false)
            }
        }
    }
}
