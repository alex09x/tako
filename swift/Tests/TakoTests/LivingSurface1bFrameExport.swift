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
import Foundation
import SwiftUI
@testable import Tako
@testable import TakoKit

/// Offscreen 7-pill state strip view (`1074×44` pt -> `2148×88` px @2x) using production `Tako.TabStatusLayer`.
@MainActor
final class Strip1bFixtureView: NSView {
    private typealias T = Tako.LivingTokens

    struct PillSpec {
        let x: CGFloat
        let width: CGFloat
        let title: String
        let state: Tako.SurfaceState
        let bg: NSColor
        let textColor: NSColor
    }

    let specs: [PillSpec] = [
        .init(x: 4.0, width: 139.4, title: "~/tako", state: .idle, bg: T.chrome, textColor: T.textInactive),
        .init(x: 157.4, width: 139.4, title: "codex", state: .working, bg: T.body, textColor: T.textInactive),
        .init(x: 310.8, width: 139.4, title: "build", state: .progress(0.68), bg: T.chrome, textColor: T.textInactive),
        .init(x: 464.2, width: 139.4, title: "claude", state: .waiting, bg: T.body, textColor: T.textInactive),
        .init(x: 617.6, width: 139.4, title: "psql", state: .done, bg: T.chrome, textColor: T.textInactive),
        .init(x: 771.0, width: 139.4, title: "test", state: .failed, bg: T.body, textColor: T.textInactive),
        .init(x: 924.6, width: 139.4, title: "prod-1", state: .offline, bg: T.body, textColor: T.faint),
    ]

    var pillLayers: [Tako.TabStatusLayer] = []

    override var isFlipped: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        for spec in specs {
            let l = Tako.TabStatusLayer()
            let rect = CGRect(x: spec.x, y: 8, width: spec.width, height: 28)
            layer?.addSublayer(l)
            l.apply(state: spec.state, in: rect, hideRing: false, reduceMotion: false, paused: false)
            pillLayers.append(l)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func applyPhase(at t: TimeInterval) {
        for l in pillLayers {
            l.applySnapshotPhase(at: t, doneElapsed: t, failedElapsed: t)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(T.body.cgColor)
        ctx.fill(bounds)
        let font = T.monoFont(size: 11.5, weight: .regular)
        for spec in specs {
            let dx = (spec.state == .failed) ? LivingAnimationState.failedShakeOffset(elapsed: pillTimeOffset) : 0
            let rect = CGRect(x: spec.x + dx, y: 8, width: spec.width, height: 28)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil))
            ctx.setFillColor(spec.bg.cgColor)
            ctx.fillPath()
            let borderInset: CGFloat = (spec.state == .working || spec.state == .offline) ? 1.0 : 0.0
            Tako.TabText.draw(spec.title, atX: rect.minX + 29 + borderInset, centeredAtY: rect.midY, font: font, color: spec.textColor, context: ctx)
        }
    }

    var pillTimeOffset: TimeInterval = 0
}

extension LivingSurface1bVisualTests {
    private func applyScale2x(_ layer: CALayer?) {
        guard let layer else { return }
        layer.contentsScale = 2.0
        layer.mask?.contentsScale = 2.0
        layer.sublayers?.forEach { applyScale2x($0) }
    }

    func snapshot2x(_ view: NSView) -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        applyScale2x(view.layer)
        for sub in view.subviews { applyScale2x(sub.layer) }
        let b = view.bounds
        let pw = max(1, Int((b.width * 2.0).rounded()))
        let ph = max(1, Int((b.height * 2.0).rounded()))
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pw,
            pixelsHigh: ph,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        rep.size = b.size
        view.cacheDisplay(in: b, to: rep)
        return rep
    }

    func snapshotSwiftUI2x<V: View>(_ view: V, width: CGFloat, height: CGFloat) -> NSBitmapImageRep? {
        let renderer = ImageRenderer(
            content: view
                .frame(width: width, height: height)
                .environment(\.displayScale, 2.0)
                .environment(\.colorScheme, .dark)
        )
        renderer.scale = 2.0
        renderer.proposedSize = ProposedViewSize(width: width, height: height)
        guard let cgImage = renderer.cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cgImage)
    }

    func exportDesignFramesIfRequested() throws {
        guard let framesDir = ProcessInfo.processInfo.environment["TAKO_1B_FRAMES_DIR"], !framesDir.isEmpty else {
            return
        }
        let dirURL = URL(fileURLWithPath: framesDir)
        try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)

        defer {
            LivingAnimationState.shared.fixedTimeOverride = nil
            LivingAnimationState.shared.resetEntries()
        }

        // 1. Setup Strip (1074×44 pt -> 2148×88 px)
        let stripView = Strip1bFixtureView(frame: NSRect(x: 0, y: 0, width: 1074, height: 44))
        let stripWin = NSWindow(contentRect: stripView.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        stripWin.contentView = stripView
        defer { stripWin.close() }

        // 2. Setup Tabs (1100×44 pt -> 2200×88 px) matching Sessions-v2.dc.html
        let (wsStore, tempDir) = makeWorkspaceStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let defaultWs = wsStore.activeWorkspace

        let ts1 = makeSurface(title: "claude · auth", pwd: "/Users/alex09x/tako-backend", status: .needsApproval, statusText: "Allow cargo test --package auth?", elapsedSeconds: 74)
        let ts2 = makeSurface(title: "codex review", pwd: "/Users/alex09x/tako-backend", status: .working, statusText: "Scanning 14 files", elapsedSeconds: 38)
        let ts3 = makeSurface(title: "cargo build", pwd: "/Users/alex09x/tako-core", status: .working, statusText: "Compiling tako-core", progressState: .normal, progressValue: 68)
        let ts4 = makeSurface(title: "cargo test", pwd: "/Users/alex09x/tako-core", status: .error, statusText: "exit 101")
        NotificationStore.shared.addNotification(id: nil, surfaceId: ts4.id, paneTitle: ts4.title, title: "Failed", body: "exit 101")
        let ts5 = makeSurface(title: "psql", pwd: "/Users/alex09x/tako-db", status: .done, statusText: "exit 0")

        let tabSurfaces = [ts1, ts2, ts3, ts4, ts5]
        var tabWindows: [NSWindow] = []
        for s in tabSurfaces {
            let c = BaseTerminalController(Tako.App(), surfaceTree: SplitTree(view: s))
            let w = makeWindow(title: s.title)
            w.windowController = c; c.window = w; w.contentView = s
            tabWindows.append(w)
        }
        defer { for w in tabWindows { Tako.CustomTabGroup.leave(w) } }
        for w in tabWindows.dropFirst() { Tako.CustomTabGroup.join(w, to: tabWindows[0], select: false) }
        Tako.CustomTabGroup.group(for: tabWindows[0]).setWindowOrder(tabWindows)
        for w in tabWindows {
            WorkspaceStore.shared.assignTab(tabIdentifier: w.stableTabIdentifier, to: WorkspaceStore.shared.activeWorkspaceId)
            wsStore.assignTab(tabIdentifier: w.stableTabIdentifier, to: defaultWs.id)
        }
        WorkspaceStore.shared.reorderTabs(in: WorkspaceStore.shared.activeWorkspaceId, newOrder: tabWindows.map(\.stableTabIdentifier))
        wsStore.reorderTabs(in: defaultWs.id, newOrder: tabWindows.map(\.stableTabIdentifier))
        Tako.CustomTabGroup.group(for: tabWindows[0]).select(tabWindows[0])

        let tabBar = Tako.TabBarView(frame: NSRect(x: 0, y: 1, width: 1100, height: 38))
        tabBar.styleOverride = .pill
        tabBar.workspaceStoreOverride = wsStore
        let hostWin1 = tabWindows[0]
        let hostContent = Tabs1bHostView(frame: NSRect(x: 0, y: 0, width: 1100, height: 44), tabBar: tabBar)
        hostContent.addSubview(ts1)
        ts1.isHidden = true
        hostWin1.setContentSize(NSSize(width: 1100, height: 44))
        hostWin1.contentView = hostContent
        _ = snapshot2x(hostContent)

        // 3. Setup Overview 4b store (1100×580 pt -> 2200×1160 px)
        let ovStore = PaneOverviewStore()
        ovStore.items = makeOverview4bItems()
        ovStore.selectedIndex = 0
        let canvasBg = Color(nsColor: NSColor(srgbRed: 0xE4 / 255, green: 0xDF / 255, blue: 0xD9 / 255, alpha: 1))

        LivingAnimationState.shared.resetEntries()

        // Render 81 frames: t = 0 ... 3200 ms, step 40 ms
        for ms in stride(from: 0, through: 3200, by: 40) {
            let t = Double(ms) / 1000.0
            LivingAnimationState.shared.fixedTimeOverride = t

            // Strip
            stripView.pillTimeOffset = t
            stripView.applyPhase(at: t)
            if let data = snapshot2x(stripView).representation(using: .png, properties: [:]) {
                try data.write(to: dirURL.appendingPathComponent(String(format: "strip_%04d.png", ms)))
            }

            // Tabs
            for layer in tabBar.statusLayers.values {
                layer.applySnapshotPhase(at: t, doneElapsed: t, failedElapsed: t)
            }
            tabBar.needsDisplay = true
            hostContent.needsDisplay = true
            if let data = snapshot2x(hostContent).representation(using: .png, properties: [:]) {
                try data.write(to: dirURL.appendingPathComponent(String(format: "tabs_%04d.png", ms)))
            }

            // Sidebar (true @2x via ImageRenderer)
            let sidebarView = Sidebar4aReferenceView(now: Date(timeIntervalSinceReferenceDate: t))
            if let rep = snapshotSwiftUI2x(sidebarView, width: 280, height: 720),
               let data = rep.representation(using: .png, properties: [:]) {
                try data.write(to: dirURL.appendingPathComponent(String(format: "sidebar_%04d.png", ms)))
            }

            // Overview (true @2x via ImageRenderer)
            let overviewView = PaneOverviewView(
                isPresented: .constant(true),
                showsBackdrop: false,
                store: ovStore,
                nowOverride: Date(timeIntervalSinceReferenceDate: t)
            ).background(canvasBg)
            if let rep = snapshotSwiftUI2x(overviewView, width: 1100, height: 580),
               let data = rep.representation(using: .png, properties: [:]) {
                try data.write(to: dirURL.appendingPathComponent(String(format: "overview_%04d.png", ms)))
            }
        }
    }

    private func makeOverview4bItems() -> [PaneOverviewItem] {
        [
            PaneOverviewItem(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, workspaceName: "Default", tabTitle: "claude", tabIndex: 0, title: "claude", pwd: "/Users/alex09x/tako-backend", status: .needsApproval, statusText: "Allow bash: cargo test --package auth", elapsed: "1m 14s", isFocused: true, isKeyWindow: true, thumbnailLines: ["$ claude \"Refactor auth middleware\"", "● Reading src/auth/jwt.rs (142 lines)", "● Proposed edit src/auth/jwt.rs (+38 −12)", "? Allow command: cargo test --package auth? [y/n]"]),
            PaneOverviewItem(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, workspaceName: "Default", tabTitle: "codex", tabIndex: 0, title: "codex review", pwd: "/Users/alex09x/tako-backend", status: .working, statusText: "Scanning 14 files", elapsed: "38s", thumbnailLines: ["$ codex review --base main", "Analyzing diff across 14 changed files…", "Checking P0/P1 invariants in", "SessionSidebarTree.swift", "Running static type checks…"]),
            PaneOverviewItem(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, workspaceName: "Default", tabTitle: "test", tabIndex: 0, title: "cargo test --workspace", pwd: "/Users/alex09x/tako-core", status: .error, statusText: "exit 101", elapsed: "12s", thumbnailLines: ["running 48 tests", "test parser::osc133 … ok", "test grid::reflow_wide_char … FAILED", "error: test failed, to rerun pass `--lib`"]),
            PaneOverviewItem(id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!, workspaceName: "Default", tabTitle: "build", tabIndex: 1, title: "cargo build --release", pwd: "/Users/alex09x/tako-core", status: .working, statusText: "Compiling tako-core", progressState: .normal, progressValue: 68, elapsed: "68%", thumbnailLines: ["   Compiling libc v0.2.161", "   Compiling vte v0.13.0", "   Compiling tako-core v0.9.2", "   Building [=========>     ] 212/310"]),
            PaneOverviewItem(id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!, workspaceName: "Frontend", tabTitle: "gemini", tabIndex: 0, title: "gemini", pwd: "/Users/alex09x/web-ui", status: .waitingForInput, statusText: "Which palette should we apply?", elapsed: "2m 05s", thumbnailLines: ["$ gemini \"Audit accessibility contrast\"", "Found 3 contrast ratios below 4.5:1.", "Which palette should we apply?", "❯ 1. High Contrast Ember   2. Warm Slate"]),
            PaneOverviewItem(id: UUID(uuidString: "00000000-0000-0000-0000-000000000006")!, workspaceName: "Default", tabTitle: "psql", tabIndex: 2, title: "psql migrations", pwd: "/Users/alex09x/tako-db", status: .done, statusText: "exit 0", elapsed: "2s", thumbnailLines: ["$ sqlx migrate run", "Applied 2026101401_add_workspace_tree", "Applied 2026101402_add_pane_badges", "All migrations applied successfully."]),
        ]
    }
}

/// Host wrapper for `tabs` (`1100×44` pt -> `2200×88` px) rendering the top 5pt canvas backdrop,
/// top-rounded 12pt window chrome, bottom 1pt `#2A211B` border, and 3 `#3A2F27` traffic light circles over `TabBarView`.
@MainActor
final class Tabs1bHostView: NSView {
    let tabBar: Tako.TabBarView
    private static let canvasBg = NSColor(srgbRed: 0xE4 / 255, green: 0xDF / 255, blue: 0xD9 / 255, alpha: 1)

    init(frame frameRect: NSRect, tabBar: Tako.TabBarView) {
        self.tabBar = tabBar
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        addSubview(tabBar)
        let lightsOverlay = TrafficLightsOverlayView(frame: frameRect)
        addSubview(lightsOverlay)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(Self.canvasBg.cgColor)
        ctx.fill(bounds)
        ctx.setFillColor(Tako.LivingTokens.hairline.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: bounds.width, height: 1))
    }
}

@MainActor
private final class TrafficLightsOverlayView: NSView {
    private static let canvasBg = NSColor(srgbRed: 0xE4 / 255, green: 0xDF / 255, blue: 0xD9 / 255, alpha: 1)
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Mask top-left and top-right 12pt rounded corners of .win (y = 0..39)
        let winPath = CGMutablePath()
        winPath.addRect(CGRect(x: 0, y: 0, width: bounds.width, height: 39))
        let rounded = CGMutablePath()
        rounded.move(to: CGPoint(x: 0, y: 0))
        rounded.addLine(to: CGPoint(x: 0, y: 27))
        rounded.addQuadCurve(to: CGPoint(x: 12, y: 39), control: CGPoint(x: 0, y: 39))
        rounded.addLine(to: CGPoint(x: bounds.width - 12, y: 39))
        rounded.addQuadCurve(to: CGPoint(x: bounds.width, y: 27), control: CGPoint(x: bounds.width, y: 39))
        rounded.addLine(to: CGPoint(x: bounds.width, y: 0))
        rounded.closeSubpath()
        winPath.addPath(rounded)
        ctx.addPath(winPath)
        ctx.setFillColor(Self.canvasBg.cgColor)
        ctx.fillPath(using: .evenOdd)

        // 3 traffic light circles (12×12pt #3A2F27 at x = 20, 40, 60, y = 14)
        ctx.setFillColor(Tako.LivingTokens.ghostBorder.cgColor)
        for lx: CGFloat in [20, 40, 60] {
            ctx.fillEllipse(in: CGRect(x: lx, y: 14, width: 12, height: 12))
        }
    }
}

/// Renders the exact 4a Session Sidebar reference tree (`280×720` pt -> `560×1440` px @2x) using production `SessionSidebarWorkspaceHeaderView` and `SessionSidebarRowView`.
@MainActor
struct Sidebar4aReferenceView: View {
    var now: Date = Date(timeIntervalSinceReferenceDate: 0)
    private typealias T = Tako.LivingTokens

    private var groups: [SessionSidebarWorkspaceGroup] {
        let ws1 = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        let ws2 = UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
        let ws3 = UUID(uuidString: "10000000-0000-0000-0000-000000000003")!
        let g1Items: [SessionSidebarItem] = [
            SessionSidebarItem(id: "sb-1", index: 0, isSelected: true, title: "claude · auth refactor", status: .needsApproval, elapsed: "1m 14s", workingDirectory: "/Users/alex09x/tako-backend", latestNotification: "Allow cargo test --package auth?", hasChildren: true, indentationLevel: 1, workspaceId: ws1, tabId: "t1", paneCount: 3),
            SessionSidebarItem(id: "sb-1-1", index: 1, isSelected: false, title: "claude", status: .needsApproval, isChild: true, label: "pane #1", indentationLevel: 2, workspaceId: ws1, tabId: "t1"),
            SessionSidebarItem(id: "sb-1-2", index: 2, isSelected: false, title: "codex review", status: .working, elapsed: "38s", isChild: true, label: "pane #2", indentationLevel: 2, workspaceId: ws1, tabId: "t1"),
            SessionSidebarItem(id: "sb-1-3", index: 3, isSelected: false, title: "cargo test", status: .error, unreadCount: 1, isChild: true, label: "pane #3", indentationLevel: 2, workspaceId: ws1, tabId: "t1"),
            SessionSidebarItem(id: "sb-2", index: 4, isSelected: false, title: "cargo build --release", status: .working, progress: 0.68, progressState: .normal, elapsed: "68%", workingDirectory: "/Users/alex09x/tako-core", gitBranch: "feat/sidebar ±3", gitDirty: true, indentationLevel: 1, workspaceId: ws1, tabId: "t2"),
            SessionSidebarItem(id: "sb-3", index: 5, isSelected: false, title: "psql migrations", status: .done, elapsed: "2s", workingDirectory: "/Users/alex09x/tako-db", gitBranch: "main", gitDirty: false, indentationLevel: 1, workspaceId: ws1, tabId: "t3"),
            SessionSidebarItem(id: "sb-4", index: 6, isSelected: false, title: "~/tako", status: .idle, indentationLevel: 1, workspaceId: ws1, tabId: "t4"),
        ]
        let g2Items: [SessionSidebarItem] = [
            SessionSidebarItem(id: "sb-5", index: 7, isSelected: false, title: "gemini · a11y audit", status: .waitingForInput, elapsed: "2m", workingDirectory: "/Users/alex09x/web-ui", latestNotification: "Which palette should we apply?", hasChildren: true, indentationLevel: 1, workspaceId: ws2, tabId: "t5", paneCount: 2),
            SessionSidebarItem(id: "sb-5-1", index: 8, isSelected: false, title: "gemini", status: .waitingForInput, isChild: true, label: "pane #1", indentationLevel: 2, workspaceId: ws2, tabId: "t5"),
            SessionSidebarItem(id: "sb-5-2", index: 9, isSelected: false, title: "npm run dev", status: .idle, elapsed: ":3000", isChild: true, label: "pane #2", indentationLevel: 2, workspaceId: ws2, tabId: "t5"),
        ]
        let g3Items: [SessionSidebarItem] = [
            SessionSidebarItem(id: "sb-6", index: 10, isSelected: false, title: "prod-1 · offline", status: .disconnected, indentationLevel: 1, workspaceId: ws3, tabId: "t6"),
        ]
        return [
            SessionSidebarWorkspaceGroup(id: ws1, name: "Default", color: "blue", icon: nil, isActive: true, isCollapsed: false, sessionCount: 5, paneCount: 7, attentionCount: 2, unreadCount: 1, dominantStatus: .needsApproval, items: g1Items),
            SessionSidebarWorkspaceGroup(id: ws2, name: "Frontend", color: "purple", icon: nil, isActive: false, isCollapsed: false, sessionCount: 2, paneCount: 3, attentionCount: 1, unreadCount: 0, dominantStatus: .waitingForInput, items: g2Items),
            SessionSidebarWorkspaceGroup(id: ws3, name: "Infra (k8s)", color: "yellow", icon: nil, isActive: false, isCollapsed: true, sessionCount: 2, paneCount: 2, attentionCount: 0, unreadCount: 0, dominantStatus: .disconnected, items: g3Items),
        ]
    }

    var body: some View {
        let canvasBg = Color(nsColor: NSColor(srgbRed: 0xE4 / 255, green: 0xDF / 255, blue: 0xD9 / 255, alpha: 1))
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Sessions").font(T.headerFont(size: 13)).foregroundColor(Color(nsColor: T.textActive))
                Spacer()
                Text("9").font(Font(T.monoFont(size: 10, weight: .medium))).foregroundColor(Color(nsColor: T.dim))
            }
            .frame(height: 17)
            .padding(.top, 11).padding(.horizontal, 12).padding(.bottom, 9)
            HStack(spacing: 7) {
                Text("⌕").font(Font(T.monoFont(size: 11))).foregroundColor(Color(nsColor: T.faint))
                Text("Filter sessions…").font(Font(T.monoFont(size: 11))).foregroundColor(Color(nsColor: T.faint))
                Spacer()
            }
            .padding(.horizontal, 9).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: T.chrome)))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: T.hairline), lineWidth: 1))
            .padding(.horizontal, 12).padding(.bottom, 8)
            HStack(spacing: 4) {
                Text("All").font(Font(T.monoFont(size: 10))).foregroundColor(Color(nsColor: T.textActive))
                    .padding(.horizontal, 8).frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: T.surfaceActive)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: T.hairline), lineWidth: 1))
                HStack(spacing: 6) {
                    StatusRingView(state: .waiting, size: .extraSmall, now: now, elapsedInState: now.timeIntervalSinceReferenceDate, reduceMotion: false)
                    Text("Needs you · 3").font(Font(T.monoFont(size: 10))).foregroundColor(Color(nsColor: T.dim))
                }
                .padding(.horizontal, 8).frame(height: 22)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.bottom, 6)
            ForEach(groups) { group in
                SessionSidebarWorkspaceHeaderView(group: group, onToggleCollapse: {}, onSelectWorkspace: {})
                ForEach(Array(group.items.enumerated()), id: \.element.id) { idx, item in
                    SessionSidebarRowView(item: item, index: idx, selectedIndex: -1, targetWindow: nil, editingItemId: .constant(nil), editingDescriptionText: .constant(""), isPresented: .constant(true), now: now, reduceMotion: false, onSelect: {})
                }
            }
            Spacer(minLength: 0)
            Divider().background(Color(nsColor: T.hairline))
            HStack {
                Text("+ New session").font(Font(T.monoFont(size: 10.5))).foregroundColor(Color(nsColor: T.dim))
                Spacer()
                (Text("⌥⏎").font(.custom("Menlo-Regular", fixedSize: 10.5)) + Text(" next waiting").font(Font(T.monoFont(size: 10.5))))
                    .foregroundColor(Color(nsColor: T.dim))
            }
            .frame(height: 14)
            .padding(.horizontal, 12).padding(.vertical, 9)
        }
        .frame(width: 280, height: 720)
        .background(Color(nsColor: T.body))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .background(canvasBg)
    }
}
