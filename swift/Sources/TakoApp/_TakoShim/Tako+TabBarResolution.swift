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

extension Tako.TabBarView {
    func surface(in window: NSWindow) -> Tako.SurfaceView? {
        func find(_ view: NSView) -> Tako.SurfaceView? {
            if let surface = view as? Tako.SurfaceView { return surface }
            for sub in view.subviews {
                if let found = find(sub) { return found }
            }
            return nil
        }
        return window.contentView.flatMap(find)
    }

    func titleFor(_ window: NSWindow) -> String {
        let raw = surface(in: window)?.title ?? window.title
        guard !raw.isEmpty else { return "~" }
        // A path is shown by its last component; a bare slash says
        // nothing in a tab strip, so it reads as home.
        if raw.hasPrefix("/") || raw.hasPrefix("~") {
            return Tako.titleForDirectory(raw)
        }
        return raw
    }

    func surfaces(in window: NSWindow) -> [Tako.SurfaceView] {
        func collect(_ view: NSView, into list: inout [Tako.SurfaceView]) {
            if let surface = view as? Tako.SurfaceView {
                list.append(surface)
            }
            for sub in view.subviews {
                collect(sub, into: &list)
            }
        }
        var list: [Tako.SurfaceView] = []
        if let content = window.contentView {
            collect(content, into: &list)
        }
        return list
    }

    func aggregateCrab(for window: NSWindow) -> Tako.CrabTracker? {
        let all = surfaces(in: window)
        guard !all.isEmpty else { return nil }
        return all.max(by: { $0.crab.paneStatus.priority < $1.crab.paneStatus.priority })?.crab
    }

    func elapsedFor(_ window: NSWindow) -> String? {
        aggregateCrab(for: window)?.elapsedLabel
    }

    func crabColor(for window: NSWindow) -> NSColor {
        aggregateCrab(for: window)?.state.color ?? Tako.Brand.ember
    }

    func progressStyle(for window: NSWindow) -> Tako.Config.ProgressStyle {
        if let app = (NSApp?.delegate as? AppDelegate)?.tako {
            return app.config.progressStyle
        }
        return Tako.Config.ProgressStyle.all
    }

    func aggregateProgress(for window: NSWindow) -> (state: ProgressState, progress: Int?)? {
        let all = surfaces(in: window)
        guard !all.isEmpty else { return nil }
        return Tako.CrabTabBinding.aggregateProgress(for: all)
    }
}
