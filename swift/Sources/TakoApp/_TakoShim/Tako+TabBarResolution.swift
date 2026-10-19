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

    public static func surfaces(in window: NSWindow) -> [Tako.SurfaceView] {
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
        func find(_ view: NSView) -> Tako.SurfaceView? {
            if let surface = view as? Tako.SurfaceView { return surface }
            for sub in view.subviews {
                if let found = find(sub) { return found }
            }
            return nil
        }
        return window.contentView.flatMap(find)
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

    public static func aggregateProgress(for window: NSWindow) -> (state: ProgressState, progress: Int?)? {
        let all = surfaces(in: window)
        guard !all.isEmpty else { return nil }
        return Tako.CrabTabBinding.aggregateProgress(for: all)
    }

    public static func tabVisualStatus(for window: NSWindow, targetSurface: Tako.SurfaceView? = nil) -> TabVisualReport {
        let allSurfaces = surfaces(in: window)
        let group = Tako.CustomTabGroup.group(for: window)
        let visibleWindows = group.visibleWindows
        let selectedWindow = group.selectedWindow ?? window
        let isSelected = (window === selectedWindow)
        let tabIndex = visibleWindows.firstIndex { $0 === window } ?? 0
        let title = titleFor(window)

        let appConfig = (NSApp?.delegate as? AppDelegate)?.tako.config
        let tabStyleStr = (appConfig?.tabStyle == .classic) ? "classic" : "pill"

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

        guard let crab = aggregateCrab(for: window) else {
            return TabVisualReport(
                title: title,
                index: tabIndex,
                selected: isSelected,
                dot: "dim",
                color: Tako.tabStatusColorName(for: "dim"),
                hex: Tako.tabStatusHex(for: "dim"),
                state: "idle",
                style: tabStyleStr,
                panesCount: allSurfaces.count,
                progressState: progressState,
                progressValue: progressValue
            )
        }

        switch crab.paneStatus {
        case .running, .working:
            return TabVisualReport(
                title: title,
                index: tabIndex,
                selected: isSelected,
                dot: "ember",
                color: Tako.tabStatusColorName(for: "ember"),
                hex: Tako.tabStatusHex(for: "ember"),
                state: "working",
                style: tabStyleStr,
                panesCount: allSurfaces.count,
                progressState: progressState,
                progressValue: progressValue
            )
        case .error:
            return TabVisualReport(
                title: title,
                index: tabIndex,
                selected: isSelected,
                dot: "error",
                color: Tako.tabStatusColorName(for: "error"),
                hex: Tako.tabStatusHex(for: "error"),
                state: "error",
                style: tabStyleStr,
                panesCount: allSurfaces.count,
                progressState: progressState,
                progressValue: progressValue
            )
        case .done:
            return TabVisualReport(
                title: title,
                index: tabIndex,
                selected: isSelected,
                dot: "ok",
                color: Tako.tabStatusColorName(for: "ok"),
                hex: Tako.tabStatusHex(for: "ok"),
                state: "done",
                style: tabStyleStr,
                panesCount: allSurfaces.count,
                progressState: progressState,
                progressValue: progressValue
            )
        case .needsApproval, .waitingForInput:
            return TabVisualReport(
                title: title,
                index: tabIndex,
                selected: isSelected,
                dot: "claw",
                color: Tako.tabStatusColorName(for: "claw"),
                hex: Tako.tabStatusHex(for: "claw"),
                state: crab.paneStatus == .waitingForInput ? "waiting_for_input" : "needs_approval",
                style: tabStyleStr,
                panesCount: allSurfaces.count,
                progressState: progressState,
                progressValue: progressValue
            )
        case .disconnected:
            return TabVisualReport(
                title: title,
                index: tabIndex,
                selected: isSelected,
                dot: "dim",
                color: Tako.tabStatusColorName(for: "dim"),
                hex: Tako.tabStatusHex(for: "dim"),
                state: "disconnected",
                style: tabStyleStr,
                panesCount: allSurfaces.count,
                progressState: progressState,
                progressValue: progressValue
            )
        case .idle:
            if allSurfaces.contains(where: { !$0.isAttentionMuted && NotificationStore.shared.unreadCount(for: $0.id) > 0 }) {
                return TabVisualReport(
                    title: title,
                    index: tabIndex,
                    selected: isSelected,
                    dot: "claw",
                    color: Tako.tabStatusColorName(for: "claw"),
                    hex: Tako.tabStatusHex(for: "claw"),
                    state: "attention",
                    style: tabStyleStr,
                    panesCount: allSurfaces.count,
                    progressState: progressState,
                    progressValue: progressValue
                )
            }
            return TabVisualReport(
                title: title,
                index: tabIndex,
                selected: isSelected,
                dot: "dim",
                color: Tako.tabStatusColorName(for: "dim"),
                hex: Tako.tabStatusHex(for: "dim"),
                state: "idle",
                style: tabStyleStr,
                panesCount: allSurfaces.count,
                progressState: progressState,
                progressValue: progressValue
            )
        case .unknown:
            if allSurfaces.contains(where: { !$0.isAttentionMuted && NotificationStore.shared.unreadCount(for: $0.id) > 0 }) {
                return TabVisualReport(
                    title: title,
                    index: tabIndex,
                    selected: isSelected,
                    dot: "claw",
                    color: Tako.tabStatusColorName(for: "claw"),
                    hex: Tako.tabStatusHex(for: "claw"),
                    state: "attention",
                    style: tabStyleStr,
                    panesCount: allSurfaces.count,
                    progressState: progressState,
                    progressValue: progressValue
                )
            }
            switch crab.state {
            case .running:
                return TabVisualReport(
                    title: title,
                    index: tabIndex,
                    selected: isSelected,
                    dot: "ember",
                    color: Tako.tabStatusColorName(for: "ember"),
                    hex: Tako.tabStatusHex(for: "ember"),
                    state: "running",
                    style: tabStyleStr,
                    panesCount: allSurfaces.count,
                    progressState: progressState,
                    progressValue: progressValue
                )
            case .failed:
                return TabVisualReport(
                    title: title,
                    index: tabIndex,
                    selected: isSelected,
                    dot: "error",
                    color: Tako.tabStatusColorName(for: "error"),
                    hex: Tako.tabStatusHex(for: "error"),
                    state: "error",
                    style: tabStyleStr,
                    panesCount: allSurfaces.count,
                    progressState: progressState,
                    progressValue: progressValue
                )
            case .succeeded:
                return TabVisualReport(
                    title: title,
                    index: tabIndex,
                    selected: isSelected,
                    dot: "ok",
                    color: Tako.tabStatusColorName(for: "ok"),
                    hex: Tako.tabStatusHex(for: "ok"),
                    state: "succeeded",
                    style: tabStyleStr,
                    panesCount: allSurfaces.count,
                    progressState: progressState,
                    progressValue: progressValue
                )
            case .attention:
                return TabVisualReport(
                    title: title,
                    index: tabIndex,
                    selected: isSelected,
                    dot: "claw",
                    color: Tako.tabStatusColorName(for: "claw"),
                    hex: Tako.tabStatusHex(for: "claw"),
                    state: "attention",
                    style: tabStyleStr,
                    panesCount: allSurfaces.count,
                    progressState: progressState,
                    progressValue: progressValue
                )
            case .ghost:
                return TabVisualReport(
                    title: title,
                    index: tabIndex,
                    selected: isSelected,
                    dot: "dim",
                    color: Tako.tabStatusColorName(for: "dim"),
                    hex: Tako.tabStatusHex(for: "dim"),
                    state: "disconnected",
                    style: tabStyleStr,
                    panesCount: allSurfaces.count,
                    progressState: progressState,
                    progressValue: progressValue
                )
            case .reconnecting:
                return TabVisualReport(
                    title: title,
                    index: tabIndex,
                    selected: isSelected,
                    dot: "ember",
                    color: Tako.tabStatusColorName(for: "ember"),
                    hex: Tako.tabStatusHex(for: "ember"),
                    state: "reconnecting",
                    style: tabStyleStr,
                    panesCount: allSurfaces.count,
                    progressState: progressState,
                    progressValue: progressValue
                )
            case .idle:
                return TabVisualReport(
                    title: title,
                    index: tabIndex,
                    selected: isSelected,
                    dot: "dim",
                    color: Tako.tabStatusColorName(for: "dim"),
                    hex: Tako.tabStatusHex(for: "dim"),
                    state: "idle",
                    style: tabStyleStr,
                    panesCount: allSurfaces.count,
                    progressState: progressState,
                    progressValue: progressValue
                )
            }
        }
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
