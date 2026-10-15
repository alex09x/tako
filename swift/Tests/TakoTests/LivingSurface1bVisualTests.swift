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
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import Tako
@testable import TakoKit

@Suite(.serialized)
@MainActor
struct LivingSurface1bVisualTests {
    private func makeDefaults() -> UserDefaults {
        let name = "TakoLiving1bTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func makeWorkspaceStore() -> (WorkspaceStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tako-ws-1b-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = WorkspaceStore(storeURL: dir.appendingPathComponent("workspaces.json"))
        return (store, dir)
    }

    private func makeSurface(
        title: String,
        pwd: String,
        status: Tako.PaneStatus = .idle,
        statusText: String? = nil,
        progressState: TakoTerminalNSView.ProgressState = .none,
        progressValue: Int? = nil,
        lines: [String] = []
    ) -> Tako.SurfaceView {
        let s = Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        s.title = title
        s.pwd = pwd
        s.crab.setStatus(status, text: statusText)
        s.activeProgressState = progressState
        s.activeProgressValue = progressValue
        if !lines.isEmpty {
            s.crab.commandStarted()
            if status != .working && status != .running {
                s.crab.setStatus(status, text: statusText)
            }
        }
        return s
    }

    @Test func spec1bAcceptanceChecklistAndScreenshots() throws {
        let defaults = makeDefaults()
        let sidebarStore = SessionSidebarStore(defaults: defaults)
        let (wsStore, tempDir) = makeWorkspaceStore()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Configure Tomorrow workspaces (no systemBlue)
        let backendWs = wsStore.activeWorkspace
        let frontendWs = wsStore.createWorkspace(name: "frontend", color: "purple")
        let infraWs = wsStore.createWorkspace(name: "infra", color: "yellow")
        #expect(Tako.Brand.hexString(for: Tako.LivingTokens.workspaceColor(for: "blue")) == "#8abeb7")
        #expect(Tako.Brand.hexString(for: Tako.LivingTokens.workspaceColor(for: "purple")) == "#b294bb")
        #expect(Tako.Brand.hexString(for: Tako.LivingTokens.workspaceColor(for: "yellow")) == "#f0c674")

        // Tab 1 (Active, Split with 2 panes: Working + Waiting for Approval)
        let s1a = makeSurface(title: "claude — auth refactor", pwd: "/Users/alex09x/Projects/tako", status: .working, statusText: "Editing Tako+TabBar.swift")
        let s1b = makeSurface(title: "cargo test --workspace", pwd: "/Users/alex09x/Projects/tako", status: .running, statusText: "Running 142 tests")
        var tree1 = SplitTree<Tako.SurfaceView>(view: s1a)
        tree1 = (try? tree1.inserting(view: s1b, at: s1a, direction: .right)) ?? tree1
        let c1 = BaseTerminalController(Tako.App(), surfaceTree: tree1)
        let w1 = makeWindow(title: "claude — auth refactor")
        w1.setContentSize(NSSize(width: 980, height: 600))
        w1.windowController = c1
        c1.window = w1
        let container1 = NSView(frame: NSRect(x: 0, y: 0, width: 980, height: 600))
        container1.addSubview(s1a)
        container1.addSubview(s1b)
        w1.contentView = container1

        // Tab 2 (Waiting for approval — shows Claw question in Sidebar line 2)
        let s2 = makeSurface(title: "codex — db migration", pwd: "/Users/alex09x/Projects/tako/db", status: .needsApproval, statusText: "Allow `psql -f 004_drop_legacy.sql` on staging?")
        NotificationStore.shared.addNotification(id: nil, surfaceId: s2.id, paneTitle: s2.title, title: "Approval", body: "Allow `psql -f 004_drop_legacy.sql` on staging?")
        let c2 = BaseTerminalController(Tako.App(), surfaceTree: SplitTree(view: s2))
        let w2 = makeWindow(title: "codex — db migration")
        w2.windowController = c2
        c2.window = w2
        w2.contentView = s2

        // Tab 3 (OSC 9;4 Progress 68%)
        let s3 = makeSurface(title: "release build", pwd: "/Users/alex09x/Projects/tako", status: .working, statusText: "Compiling ghostty-vt (68%)", progressState: .normal, progressValue: 68)
        let c3 = BaseTerminalController(Tako.App(), surfaceTree: SplitTree(view: s3))
        let w3 = makeWindow(title: "release build")
        w3.windowController = c3
        c3.window = w3
        w3.contentView = s3

        // Tab 4 (Done ✓)
        let s4 = makeSurface(title: "vite dev-server", pwd: "/Users/alex09x/Projects/web", status: .done, statusText: "Built in 1.42s")
        let c4 = BaseTerminalController(Tako.App(), surfaceTree: SplitTree(view: s4))
        let w4 = makeWindow(title: "vite dev-server")
        w4.windowController = c4
        c4.window = w4
        w4.contentView = s4

        // Tab 5 (Failed ! + unread dot)
        let s5 = makeSurface(title: "integration-suite", pwd: "/Users/alex09x/Projects/web/e2e", status: .error, statusText: "exit 101 · auth_flow_spec")
        NotificationStore.shared.addNotification(id: nil, surfaceId: s5.id, paneTitle: s5.title, title: "Failed", body: "exit 101 · auth_flow_spec")
        let c5 = BaseTerminalController(Tako.App(), surfaceTree: SplitTree(view: s5))
        let w5 = makeWindow(title: "integration-suite")
        w5.windowController = c5
        c5.window = w5
        w5.contentView = s5

        // Tab 6 (Offline dashed)
        let s6 = makeSurface(title: "ssh prod-node-02", pwd: "/srv/app", status: .disconnected, statusText: "Connection closed by remote host")
        let c6 = BaseTerminalController(Tako.App(), surfaceTree: SplitTree(view: s6))
        let w6 = makeWindow(title: "ssh prod-node-02")
        w6.windowController = c6
        c6.window = w6
        w6.contentView = s6

        let allWindows = [w1, w2, w3, w4, w5, w6]
        defer {
            for w in allWindows { Tako.CustomTabGroup.leave(w) }
        }
        for w in allWindows.dropFirst() {
            Tako.CustomTabGroup.join(w, to: w1, select: false)
        }
        Tako.CustomTabGroup.group(for: w1).select(w1)

        wsStore.assignTab(tabIdentifier: w1.stableTabIdentifier, to: backendWs.id)
        wsStore.assignTab(tabIdentifier: w2.stableTabIdentifier, to: backendWs.id)
        wsStore.assignTab(tabIdentifier: w3.stableTabIdentifier, to: backendWs.id)
        wsStore.assignTab(tabIdentifier: w4.stableTabIdentifier, to: frontendWs.id)
        wsStore.assignTab(tabIdentifier: w5.stableTabIdentifier, to: frontendWs.id)
        wsStore.assignTab(tabIdentifier: w6.stableTabIdentifier, to: infraWs.id)

        // 1. Verify Pill Tab Bar (§4 & §8.1-8.6, §8.10)
        let bar = Tako.TabBarView(frame: NSRect(x: 0, y: 0, width: 1120, height: 38))
        bar.styleOverride = .pill
        container1.addSubview(bar)
        _ = snapshot(bar)
        for layer in bar.statusLayers.values {
            layer.applySnapshotPhase(at: 1.1, doneElapsed: 0.35)
        }
        let barRep = snapshot(bar)

        #expect(bar.paintedRingStates[ObjectIdentifier(w1)] == .working)
        #expect(bar.paintedRingStates[ObjectIdentifier(w2)] == .waiting)
        #expect(bar.paintedRingStates[ObjectIdentifier(w3)] == .progress(0.68))
        #expect(bar.paintedRingStates[ObjectIdentifier(w4)] == .done)
        #expect(bar.paintedRingStates[ObjectIdentifier(w5)] == .failed)
        #expect(bar.paintedRingStates[ObjectIdentifier(w6)] == .offline)
        #expect(bar.pillMetaText(for: w3) == "68%")

        // Verify #483C32 is never present anywhere in the rendered TabBar bitmap (§8.6)
        for y in 0..<barRep.pixelsHigh {
            for x in stride(from: 0, to: barRep.pixelsWide, by: 4) {
                if let c = barRep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                    let isLegacyBrown = abs(c.redComponent - (0x48 / 255.0)) < 0.015
                        && abs(c.greenComponent - (0x3C / 255.0)) < 0.015
                        && abs(c.blueComponent - (0x32 / 255.0)) < 0.015
                    #expect(!isLegacyBrown, "Legacy #483C32 must not appear in Pill Tab Bar")
                }
            }
        }

        // Verify occlusion pause (§8.10)
        if let statusLayer = bar.statusLayers[ObjectIdentifier(w1)] {
            statusLayer.setLayerPaused(true)
            #expect(statusLayer.speed == 0.0)
            statusLayer.setLayerPaused(false)
            #expect(statusLayer.speed == 1.0)
        }

        // 2. Verify Session Sidebar 4a (§5 & §8.7)
        let groups = sidebarStore.workspaceGroups(for: w1, workspaceStore: wsStore)
        #expect(groups.count == 3)
        let child1 = groups[0].items.first(where: { $0.isChild })
        #expect(child1?.compactPaneTag == "1")

        let sidebarHost = NSHostingView(
            rootView: SessionSidebarView(
                isPresented: .constant(true),
                containingWindow: w1,
                store: sidebarStore,
                workspaceStore: wsStore
            )
        )
        sidebarHost.frame = NSRect(x: 0, y: 0, width: 260, height: 680)
        let sidebarWin = NSWindow(contentRect: sidebarHost.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        sidebarWin.contentView = sidebarHost
        defer { sidebarWin.close() }
        sidebarHost.layoutSubtreeIfNeeded()
        let sidebarRep = snapshot(sidebarHost)
        #expect(sidebarRep.pixelsWide >= 260 && sidebarRep.pixelsHigh >= 680)

        // 3. Verify Pane Overview 4b (§6 & §8.8)
        let overviewStore = PaneOverviewStore()
        overviewStore.items = [
            PaneOverviewItem(
                id: s1a.id, workspaceName: "Default", tabTitle: "claude", tabIndex: 0,
                title: "claude — auth refactor", pwd: "/Users/alex09x/Projects/tako",
                status: .working, statusText: "Editing Tako+TabBar.swift", elapsed: "1m 24s",
                isFocused: true, isKeyWindow: true,
                thumbnailLines: ["$ claude \"implement style 1b living surface\"", "● Reading Tako+TabBarDrawing.swift…", "● Applying conic comet gradient (2.2s)", "✓ Updated TabStatusLayer.swift (+368 -0)"]
            ),
            PaneOverviewItem(
                id: s2.id, workspaceName: "Default", tabTitle: "codex", tabIndex: 1,
                title: "codex — db migration", pwd: "/Users/alex09x/Projects/tako/db",
                status: .needsApproval, statusText: "Allow psql -f 004_drop_legacy.sql?", elapsed: "42s",
                thumbnailLines: ["$ codex \"migrate staging schema\"", "? Tool Permission Request: bash", "  Command: psql -f 004_drop_legacy.sql", "  [y] Approve   [n] Reject"]
            ),
            PaneOverviewItem(
                id: s3.id, workspaceName: "Default", tabTitle: "build", tabIndex: 2,
                title: "release build", pwd: "/Users/alex09x/Projects/tako",
                status: .working, statusText: "Compiling ghostty-vt",
                progressState: .normal, progressValue: 68, elapsed: "68%",
                thumbnailLines: ["$ zig build -Doptimize=ReleaseFast", "[142/208] Compiling src/terminal/PageList.zig", "[143/208] Compiling src/terminal/Screen.zig", "OSC 9;4;1;68 progress active…"]
            ),
            PaneOverviewItem(
                id: s4.id, workspaceName: "frontend", tabTitle: "vite", tabIndex: 3,
                title: "vite dev-server", pwd: "/Users/alex09x/Projects/web",
                status: .done, statusText: "Built in 1.42s", elapsed: "1s",
                thumbnailLines: ["$ pnpm run build", "vite v6.1.0 building for production...", "✓ 418 modules transformed.", "dist/assets/index-D8a91F.js  184.20 kB │ gzip: 58.10 kB"]
            ),
            PaneOverviewItem(
                id: s5.id, workspaceName: "frontend", tabTitle: "e2e", tabIndex: 4,
                title: "integration-suite", pwd: "/Users/alex09x/Projects/web/e2e",
                status: .error, statusText: "exit 101 · auth_flow_spec", elapsed: "19s",
                thumbnailLines: ["$ cargo test --test auth_flow_spec", "thread 'auth_token_refresh' panicked at src/auth.rs:84:", "assertion `left == right` failed: 401 != 200", "error: test failed, to rerun pass `--test auth_flow_spec`"]
            ),
            PaneOverviewItem(
                id: s6.id, workspaceName: "infra", tabTitle: "ssh", tabIndex: 5,
                title: "ssh prod-node-02", pwd: "/srv/app",
                status: .disconnected, statusText: "Connection closed by remote host",
                thumbnailLines: ["$ ssh prod-node-02.internal", "Last login: Wed Oct 14 19:40:11 2026", "client_loop: send disconnect: Broken pipe"]
            ),
        ]
        overviewStore.selectedIndex = 1 // Select the waiting card to showcase breatheSel (2px Ember<->Claw)

        let overviewHost = NSHostingView(
            rootView: PaneOverviewView(
                isPresented: .constant(true),
                store: overviewStore
            )
        )
        overviewHost.frame = NSRect(x: 0, y: 0, width: 1180, height: 820)
        let overviewWin = NSWindow(contentRect: overviewHost.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        overviewWin.contentView = overviewHost
        defer { overviewWin.close() }
        overviewHost.layoutSubtreeIfNeeded()
        let overviewRep = snapshot(overviewHost)
        #expect(overviewRep.pixelsWide >= 1180 && overviewRep.pixelsHigh >= 820)

        // Export screenshots & 3.6s animated GIF when requested
        if let outDir = ProcessInfo.processInfo.environment["TAKO_EXPORT_1B_SCREENSHOTS"], !outDir.isEmpty {
            let dirURL = URL(fileURLWithPath: outDir)
            try FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
            if let data = barRep.representation(using: .png, properties: [:]) {
                try data.write(to: dirURL.appendingPathComponent("tabbar_1b_living_surface.png"))
            }
            if let data = sidebarRep.representation(using: .png, properties: [:]) {
                try data.write(to: dirURL.appendingPathComponent("sidebar_1b_4a.png"))
            }
            if let data = overviewRep.representation(using: .png, properties: [:]) {
                try data.write(to: dirURL.appendingPathComponent("overview_1b_4b.png"))
            }
            try exportAnimatedGif(
                to: dirURL.appendingPathComponent("living_surface_1b_animation.gif"),
                bar: bar,
                sidebarStore: sidebarStore,
                sidebarItems: groups[0].items.filter { !$0.isChild },
                overviewItems: Array(overviewStore.items.prefix(2))
            )
        }
    }

    private func exportAnimatedGif(
        to url: URL,
        bar: Tako.TabBarView,
        sidebarStore: SessionSidebarStore,
        sidebarItems: [SessionSidebarItem],
        overviewItems: [PaneOverviewItem]
    ) throws {
        let frameCount = 30
        let dt: TimeInterval = 0.12 // 30 * 0.12s = 3.6s animation
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else {
            return
        }
        let fileProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ]
        CGImageDestinationSetProperties(dest, fileProps as CFDictionary)
        let frameProps: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: dt,
                kCGImagePropertyGIFUnclampedDelayTime: dt
            ]
        ]

        let animHost = NSHostingView(rootView: AnyView(EmptyView()))
        animHost.frame = NSRect(x: 0, y: 0, width: 960, height: 310)
        let animWin = NSWindow(contentRect: animHost.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        animWin.contentView = animHost
        defer { animWin.close() }

        for i in 0..<frameCount {
            let t = Double(i) * dt
            let date = Date(timeIntervalSinceReferenceDate: t)
            for layer in bar.statusLayers.values {
                layer.applySnapshotPhase(at: t, doneElapsed: t.truncatingRemainder(dividingBy: 1.8))
            }
            let barStepRep = snapshot(bar)
            let barNSImage = NSImage(size: bar.bounds.size)
            barNSImage.addRepresentation(barStepRep)

            let root = VStack(alignment: .leading, spacing: 12) {
                Image(nsImage: barNSImage)
                    .resizable()
                    .frame(width: 932, height: 38, alignment: .leading)
                    .clipped()

                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(sidebarItems.prefix(3).enumerated()), id: \.element.id) { idx, item in
                            SessionSidebarRowView(
                                item: item,
                                index: idx,
                                selectedIndex: 0,
                                targetWindow: nil,
                                editingItemId: .constant(nil),
                                editingDescriptionText: .constant(""),
                                isPresented: .constant(true),
                                now: date,
                                reduceMotion: false,
                                onSelect: {}
                            )
                        }
                    }
                    .frame(width: 260)

                    ForEach(Array(overviewItems.enumerated()), id: \.element.id) { idx, ovItem in
                        PaneOverviewCard(
                            item: ovItem,
                            isSelected: idx == 1,
                            now: date,
                            reduceMotion: false
                        )
                        .frame(width: 325)
                    }
                }
            }
            .padding(14)
            .frame(width: 960, height: 310, alignment: .topLeading)
            .background(Color(nsColor: Tako.LivingTokens.body))

            animHost.rootView = AnyView(root)
            animHost.layoutSubtreeIfNeeded()
            let rep = snapshot(animHost)
            if let cgImg = rep.cgImage {
                CGImageDestinationAddImage(dest, cgImg, frameProps as CFDictionary)
            }
        }
        CGImageDestinationFinalize(dest)
    }
}
