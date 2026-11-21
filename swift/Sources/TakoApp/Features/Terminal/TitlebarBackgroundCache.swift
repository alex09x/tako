/*
 * tako — Locate native titlebar views once per stable window hierarchy
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit

@MainActor
final class TitlebarBackgroundCache {
    private final class Entry {
        weak var root: NSView?
        weak var container: NSView?
        weak var titlebar: NSView?
        init(root: NSView, container: NSView, titlebar: NSView?) {
            self.root = root; self.container = container; self.titlebar = titlebar
        }
    }

    private let entries = NSMapTable<NSWindow, Entry>.weakToStrongObjects()
    private let find: (NSView, String) -> NSView?

    init(find: @escaping (NSView, String) -> NSView? = { $0.firstDescendant(withClassName: $1) }) {
        self.find = find
    }

    func views(in window: NSWindow, root: NSView) -> [NSView] {
        if let entry = entries.object(forKey: window), entry.root === root,
           let container = entry.container, container.isDescendant(of: root) {
            if let titlebar = entry.titlebar, titlebar.isDescendant(of: container) {
                return [container, titlebar]
            }
            // AppKit may replace just the titlebar during a style transition.
            entry.titlebar = find(container, "NSTitlebarView")
            return [container, entry.titlebar].compactMap { $0 }
        }
        guard let container = find(root, "NSTitlebarContainerView") else {
            entries.removeObject(forKey: window)
            return []
        }
        let titlebar = find(container, "NSTitlebarView")
        entries.setObject(Entry(root: root, container: container, titlebar: titlebar), forKey: window)
        return [container, titlebar].compactMap { $0 }
    }
}
