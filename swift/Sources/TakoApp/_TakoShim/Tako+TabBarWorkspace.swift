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
    func workspaceAttentionCount(for ws: Workspace) -> Int {
        let store = effectiveWorkspaceStore
        let liveWs = store.workspace(for: ws.id) ?? ws
        let selected = group?.selectedWindow ?? window
        var tabCount = 0
        for w in windows {
            // A tab of no workspace counts toward the default one.
            let owner = store.workspace(forTab: w.stableTabIdentifier)?.id
            guard owner == liveWs.id || (owner == nil && liveWs.id == WorkspaceStore.defaultWorkspaceId) else { continue }
            let isSelected = (w === selected)
            let state = pillSurfaceState(for: w)
            if state == .waiting || state == .failed || (!isSelected && hasUnreadInWindow(w)) {
                tabCount += 1
            }
        }
        if !windows.isEmpty {
            return tabCount
        }
        return store.attentionCount(for: liveWs)
    }

    func drawWorkspacePill(in ctx: CGContext) {
        guard showsWorkspacePill else { return }
        let rect = workspacePillRect
        let ws = effectiveWorkspaceStore.activeWorkspace
        let attention = workspaceAttentionCount(for: ws)

        // Background pill (§4): #241C16 (hover #1F1915), r=6
        ctx.setFillColor(workspaceHovered ? Palette.hoverTab.cgColor : Palette.activeTab.cgColor)
        let path = CGPath(roundedRect: rect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        ctx.addPath(path)
        ctx.fillPath()

        // Color dot (§0 Tomorrow palette, no systemBlue)
        let dotColor = Tako.LivingTokens.workspaceColor(for: ws.color)
        ctx.setFillColor(dotColor.cgColor)
        let dotRect = CGRect(x: rect.minX + 8, y: rect.midY - 3.5, width: 7, height: 7)
        ctx.fillEllipse(in: dotRect)

        // Workspace title: mono 11 medium #B7ACA1 (hover #FAF7F2)
        let wsFont = Tako.LivingTokens.monoFont(size: 11, weight: .medium)
        // Cut to the width the chip is growing to: not re-cut every frame of the slide.
        let maxTitleWidth = (chipWidthTarget ?? rect.width) - 24 - (attention > 0 ? 22 : 0)
        let title = Tako.TabText.truncate(ws.name, to: maxTitleWidth, font: wsFont)
        let textColor = workspaceHovered ? Palette.activeText : Palette.inactiveText
        Tako.TabText.draw(title, atX: dotRect.maxX + 6, centeredAtY: rect.midY,
                          font: wsFont, color: textColor, context: ctx)

        // Attention badge if > 0 (§4: Claw #FF7A3D, r4, padding 1x4, mono 9.5 bold ink #14100E, "9+")
        if attention > 0 {
            let countStr = attention > 9 ? "9+" : "\(attention)"
            let badgeFont = Tako.LivingTokens.monoFont(size: 9.5, weight: .bold)
            let textW = Tako.TabText.width(of: countStr, font: badgeFont)
            let badgeW = max(14, ceil(textW + 8))
            let badgeRect = CGRect(x: rect.maxX - 9 - badgeW, y: rect.midY - 6.5, width: badgeW, height: 13)
            // While the chip grows to make room, the badge comes in with it.
            let room = rect.width - ((chipWidthTarget ?? rect.width) - 20)
            ctx.saveGState()
            defer { ctx.restoreGState() }
            ctx.setAlpha(min(1, max(0, room / 20)))
            ctx.setFillColor(Tako.LivingTokens.claw.cgColor)
            ctx.addPath(CGPath(roundedRect: badgeRect, cornerWidth: 4, cornerHeight: 4, transform: nil))
            ctx.fillPath()
            Tako.TabText.draw(countStr, atX: badgeRect.midX - textW / 2, centeredAtY: badgeRect.midY,
                              font: badgeFont, color: Tako.LivingTokens.ink, context: ctx)
        }
    }

    private static var shouldPresentNewWorkspaceDialog = false

    func showWorkspaceMenu(at point: CGPoint) {
        if let win = self.window {
            Tako.CustomTabGroup.lastActiveWindowFrame = win.frame
        }
        Self.shouldPresentNewWorkspaceDialog = false
        let menu = NSMenu()
        menu.autoenablesItems = false
        let store = effectiveWorkspaceStore
        for ws in store.workspaces {
            let attention = workspaceAttentionCount(for: ws)
            let title = attention > 0 ? "\(ws.name) (\(attention))" : ws.name
            let item = NSMenuItem(title: title, action: #selector(handleWorkspaceSelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ws.id
            item.isEnabled = true
            if ws.id == store.activeWorkspaceId {
                item.state = .on
            }
            menu.addItem(item)
        }
        menu.addItem(NSMenuItem.separator())
        let nextItem = NSMenuItem(title: "Next Workspace", action: #selector(handleNextWorkspace), keyEquivalent: "]")
        nextItem.keyEquivalentModifierMask = [.control, .option]
        nextItem.target = self
        nextItem.isEnabled = true
        menu.addItem(nextItem)

        let prevItem = NSMenuItem(title: "Previous Workspace", action: #selector(handlePreviousWorkspace), keyEquivalent: "[")
        prevItem.keyEquivalentModifierMask = [.control, .option]
        prevItem.target = self
        prevItem.isEnabled = true
        menu.addItem(prevItem)

        menu.addItem(NSMenuItem.separator())
        let newItem = NSMenuItem(title: "New Workspace...", action: #selector(handleNewWorkspace), keyEquivalent: "")
        newItem.target = self
        newItem.isEnabled = true
        menu.addItem(newItem)

        menu.popUp(positioning: nil, at: point, in: self)
        menu.cancelTrackingWithoutAnimation()
        for w in NSApp.windows where String(describing: type(of: w)).contains("Menu") {
            w.orderOut(nil)
        }

        if Self.shouldPresentNewWorkspaceDialog {
            Self.shouldPresentNewWorkspaceDialog = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.presentNewWorkspaceDialog()
            }
        }
    }

    @objc func handleWorkspaceSelected(_ sender: NSMenuItem) {
        if let win = self.window {
            Tako.CustomTabGroup.lastActiveWindowFrame = win.frame
        }
        let id = sender.representedObject as? UUID
        let title = sender.title
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let id {
                WorkspaceStore.shared.switchWorkspace(to: id)
            } else {
                _ = WorkspaceStore.shared.switchWorkspace(named: title)
            }
        }
    }

    @objc func handleNextWorkspace() {
        WorkspaceStore.shared.nextWorkspace()
    }

    @objc func handlePreviousWorkspace() {
        WorkspaceStore.shared.previousWorkspace()
    }

    @objc func handleNewWorkspace() {
        Self.shouldPresentNewWorkspaceDialog = true
    }

    private func presentNewWorkspaceDialog() {
        NSApp.activate(ignoringOtherApps: true)
        guard let window = self.window
            ?? AppUpdater.noticeWindow(key: NSApp.keyWindow, windows: NSApp.windows)
            ?? TerminalController.preferredParent?.window
            ?? NSApp.windows.first(where: { $0.isVisible }) else { return }

        let theme = (NSApp.delegate as? AppDelegate)?.tako.config.theme
        Task { @MainActor in
            guard let name = await TerminalDialogView.askText(
                in: window,
                title: "New Project Workspace",
                label: "Workspace Name:",
                value: "",
                hint: "e.g. backend, docs, tako",
                confirm: "Create",
                theme: theme
            ) else { return }

            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalName = trimmed.isEmpty ? "Workspace \(WorkspaceStore.shared.workspaces.count + 1)" : trimmed
            let ws = WorkspaceStore.shared.createWorkspace(name: finalName)
            WorkspaceStore.shared.switchWorkspace(to: ws.id)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Pill Tab Living Surface Resolution (§1, §2, §4)

    func pillSurfaceState(for window: NSWindow) -> Tako.SurfaceState {
        let style = progressStyle(for: window)
        let progPair = style.showsInTab ? aggregateProgress(for: window) : nil
        let pState = progPair?.state ?? .none
        // A program that cannot say how far it is shows as working, not as
        // a made-up percentage.
        let pFraction: Double? = pState == .none
            ? nil : progPair?.progress.map { min(1.0, max(0.0, Double($0) / 100.0)) }

        switch Tako.tabVisualState(for: window) {
        case "disconnected":
            return .offline
        case "error":
            return .failed
        case "needs_approval", "waiting_for_input", "attention":
            return .waiting
        case "working", "running", "reconnecting":
            if let pFraction { return .progress(pFraction) }
            if pState == .indeterminate { return .working }
            // Spec 1b: a shell command shows as working only after 3 s.
            if let crab = Tako.aggregateCrab(for: window), crab.paneStatus == .running, crab.state != .running {
                return .idle
            }
            return .working
        case "done", "succeeded":
            return .done
        default:
            if let pFraction { return .progress(pFraction) }
            if pState == .indeterminate { return .working }
            if let live = liveActivity(for: window) { return .live(flowing: live.isFlowing) }
            return .idle
        }
    }

    func hasUnreadInWindow(_ window: NSWindow) -> Bool {
        surfaces(in: window).contains {
            !$0.isAttentionMuted && NotificationStore.shared.unreadCount(for: $0.id) > 0
        }
    }

    func updateStatusLayer(for window: NSWindow, rect: CGRect, state: Tako.SurfaceState, hideRing: Bool) {
        if !wantsLayer {
            wantsLayer = true
            layer?.masksToBounds = false
        }
        let key = ObjectIdentifier(window)
        let statusLayer: Tako.TabStatusLayer
        if let existing = statusLayers[key] {
            statusLayer = existing
        } else {
            let created = Tako.TabStatusLayer()
            statusLayers[key] = created
            layer?.addSublayer(created)
            statusLayer = created
        }
        if statusLayer.superlayer == nil {
            layer?.addSublayer(statusLayer)
        }
        let animState = LivingAnimationState.shared
        statusLayer.apply(
            state: state,
            in: rect,
            hideRing: hideRing,
            reduceMotion: animState.reduceMotion,
            paused: animState.isTimelinePaused,
            allowFrameAnimation: isTabDragging,
            pulses: liveActivity(for: window)?.pulses ?? 0
        )
        if let t = animState.fixedTimeOverride {
            statusLayer.applySnapshotPhase(at: t, doneElapsed: t, failedElapsed: t)
        }
    }

    func syncStatusLayers(visibleTabIds: Set<ObjectIdentifier>) {
        syncCrabLayers(visibleTabIds: effectiveTabStyle == .classic ? visibleTabIds : [])
        guard effectiveTabStyle == .pill else {
            for (_, l) in statusLayers { l.removeFromSuperlayer() }
            statusLayers.removeAll()
            return
        }
        for (id, l) in statusLayers where !visibleTabIds.contains(id) {
            l.removeFromSuperlayer()
            statusLayers.removeValue(forKey: id)
        }
    }
}
