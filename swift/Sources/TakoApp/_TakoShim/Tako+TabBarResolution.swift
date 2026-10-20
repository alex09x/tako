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

@MainActor
extension Tako {
    public struct TabVisualReport {
        public let title: String
        public let index: Int
        public let selected: Bool
        public let dot: String
        public let color: String
        public let hex: String
        public let state: String
        public let style: String
        public let panesCount: Int
        public let progressState: String?
        public let progressValue: Int?
    }

    /// A tab's panes. Its controller holds them: the tab bar asks for every
    /// tab several times a draw, and walking every view of the window -- the
    /// sidebar's too -- each time took most of the main thread. The walk is
    /// left for a window whose controller does not hold what it shows.
    public static func surfaces(in window: NSWindow) -> [Tako.SurfaceView] {
        if let panes = panes(of: window) { return panes }
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

    public static func surface(in window: NSWindow) -> Tako.SurfaceView? {
        if let panes = panes(of: window) { return panes.first }
        func find(_ view: NSView) -> Tako.SurfaceView? {
            if let surface = view as? Tako.SurfaceView { return surface }
            for sub in view.subviews {
                if let found = find(sub) { return found }
            }
            return nil
        }
        return window.contentView.flatMap(find)
    }

    /// The controller's panes, when every one of them is in `window`.
    private static func panes(of window: NSWindow) -> [Tako.SurfaceView]? {
        guard let tree = (window.windowController as? BaseTerminalController)?.surfaceTree else { return nil }
        let panes = Array(tree)
        guard !panes.isEmpty, panes.allSatisfy({ $0.window === window }) else { return nil }
        return panes
    }

    public static func titleFor(_ window: NSWindow) -> String {
        // A title the user gave the tab (Rename Tab, takoctl title) beats
        // whatever the program in it reports.
        if let override = (window.windowController as? BaseTerminalController)?.titleOverride, !override.isEmpty {
            return override
        }
        let raw = surface(in: window)?.title ?? window.title
        guard !raw.isEmpty else { return "~" }
        if raw.hasPrefix("/") || raw.hasPrefix("~") {
            return Tako.titleForDirectory(raw)
        }
        return raw
    }

    public static func aggregateCrab(for window: NSWindow) -> Tako.CrabTracker? {
        let all = surfaces(in: window)
        guard !all.isEmpty else { return nil }
        return all.max(by: { $0.crab.paneStatus.priority < $1.crab.paneStatus.priority })?.crab
    }

    /// The progress a tab shows: its panes' reports together -- unless a
    /// pane works with no report of its own. Working outranks progress (1b),
    /// so that tab shows working, not another pane's percentage.
    public static func aggregateProgress(for window: NSWindow) -> (state: ProgressState, progress: Int?)? {
        let all = surfaces(in: window)
        guard !all.isEmpty, !all.contains(where: worksWithoutProgress) else { return nil }
        return Tako.CrabTabBinding.aggregateProgress(for: all)
    }

    /// A pane at work that reports no progress: it shows as working.
    static func worksWithoutProgress(_ surface: Tako.SurfaceView) -> Bool {
        let crab = surface.crab
        guard crab.progressState == .none, surface.activeProgressState == .none else { return false }
        return crab.paneStatus.surfaceState(crabState: crab.state) == .working
    }

    /// The state a tab shows, and nothing else of its report: the tab bar
    /// asks for every tab several times a draw.
    public static func tabVisualState(for window: NSWindow) -> String {
        guard let crab = aggregateCrab(for: window) else { return "idle" }
        func hasUnread() -> Bool {
            surfaces(in: window).contains { !$0.isAttentionMuted && NotificationStore.shared.unreadCount(for: $0.id) > 0 }
        }
        switch crab.paneStatus {
        case .running, .working: return "working"
        case .error: return "error"
        case .done: return "done"
        case .waitingForInput: return "waiting_for_input"
        case .needsApproval: return "needs_approval"
        case .disconnected: return "disconnected"
        case .idle: return hasUnread() ? "attention" : "idle"
        case .unknown:
            if hasUnread() { return "attention" }
            switch crab.state {
            case .running: return "running"
            case .failed: return "error"
            case .succeeded: return "succeeded"
            case .attention: return "attention"
            case .ghost: return "disconnected"
            case .reconnecting: return "reconnecting"
            case .idle: return "idle"
            }
        }
    }

    /// The dot a tab's state is drawn with.
    static func tabStatusDot(for state: String) -> String {
        switch state {
        case "working", "running", "reconnecting": return "ember"
        case "error": return "error"
        case "done", "succeeded": return "ok"
        case "waiting_for_input", "needs_approval", "attention": return "claw"
        default: return "dim"
        }
    }

    public static func tabVisualStatus(for window: NSWindow, targetSurface: Tako.SurfaceView? = nil) -> TabVisualReport {
        let group = Tako.CustomTabGroup.group(for: window)
        let selectedWindow = group.selectedWindow ?? window
        let appConfig = (NSApp?.delegate as? AppDelegate)?.tako.config
        let (progressState, progressValue) = { () -> (String?, Int?) in
            guard let (pState, pVal) = aggregateProgress(for: window) else {
                return (nil, nil)
            }
            switch pState {
            case .indeterminate: return ("indeterminate", nil)
            case .normal: return ("normal", pVal)
            case .error: return ("error", pVal)
            case .paused: return ("paused", pVal)
            case .none: return (nil, nil)
            }
        }()
        let state = tabVisualState(for: window)
        let dot = tabStatusDot(for: state)
        return TabVisualReport(
            title: titleFor(window),
            index: group.visibleWindows.firstIndex { $0 === window } ?? 0,
            selected: window === selectedWindow,
            dot: dot,
            color: Tako.tabStatusColorName(for: dot),
            hex: Tako.tabStatusHex(for: dot),
            state: state,
            style: (appConfig?.tabStyle == .classic) ? "classic" : "pill",
            panesCount: surfaces(in: window).count,
            progressState: progressState,
            progressValue: progressValue
        )
    }
}

extension Tako.TabBarView {
    func surface(in window: NSWindow) -> Tako.SurfaceView? {
        Tako.surface(in: window)
    }

    func titleFor(_ window: NSWindow) -> String {
        Tako.titleFor(window)
    }

    func surfaces(in window: NSWindow) -> [Tako.SurfaceView] {
        Tako.surfaces(in: window)
    }

    func aggregateCrab(for window: NSWindow) -> Tako.CrabTracker? {
        Tako.aggregateCrab(for: window)
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
        Tako.aggregateProgress(for: window)
    }
}
