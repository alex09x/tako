/*
 * tako — Session sidebar header, search and segments (reference A01)
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import SwiftUI

/// The top of the sidebar as the frozen reference draws it (`.sb-hd`,
/// `.sb-search`, `.sb-seg`): a 44 pt header with the window's traffic
/// lights and three icons, an always-shown «Filter sessions… ⌘K» field and
/// «All» beside the counters.
/// Accessibility: `SessionSidebarHeader`, `SessionSidebarKeys`,
/// `SessionSidebarSettings`, `SessionSidebarHeaderNewSession` (the + menu),
/// `SessionSidebarSearchField`, `SessionSidebarSegmentAll`,
/// `SessionSidebarAttentionToggle`.
extension SessionSidebarView {
    static let referenceHeaderHeight: CGFloat = 44

    func headerView(sessionCount: Int, attentionCount: Int) -> some View {
        let stripHeight = SessionSidebarChrome.topStripHeight(for: targetWindow)
        let barHeight = max(SessionSidebarChrome.headerBarHeight(for: targetWindow), Self.referenceHeaderHeight)
        return ZStack(alignment: .topLeading) {
            if stripHeight > 0 {
                SidebarTitlebarDragStrip().frame(maxWidth: .infinity).frame(height: barHeight)
            }
            Color.clear.frame(width: 1, height: 1)
                .background(SidebarHeaderTitleAXOverlay(value: "\(sessionCount)"))
                .allowsHitTesting(false)
            HStack(spacing: 1) {
                Spacer(minLength: SessionSidebarChrome.leadingHeaderInset(for: targetWindow))
                headerIcon("keyboard", id: "SessionSidebarKeys", label: "Keyboard Shortcuts", help: "Keyboard Shortcuts") {
                    DesktopSettingsController.showGlobal(section: .keys, in: targetWindow)
                }
                headerIcon("gearshape", id: "SessionSidebarSettings", label: "Settings", help: "Settings  ⌘,") {
                    DesktopSettingsController.showGlobal(section: .general, in: targetWindow)
                }
                headerIcon("plus", id: "SessionSidebarHeaderNewSession", label: "New Session or Terminal",
                           help: "New Session or Terminal", action: showNewMenu)
            }
            .padding(.trailing, 8)
            .frame(height: barHeight)
        }
        .frame(height: barHeight)
    }

    private func headerIcon(_ symbol: String, id: String, label: String, help: String,
                            action: @escaping () -> Void) -> some View {
        SidebarHeaderActionButton(identifier: id, label: label, value: "", helpText: help, isActive: false,
                                  action: action) { hovering in
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .regular))
                .foregroundColor(Color(nsColor: hovering ? T.textActive : T.dim))
                .frame(width: 24, height: 24)
        }
    }

    /// The + menu: the registry's own actions and their real shortcuts.
    func showNewMenu() {
        let window = targetWindow
        guard let content = window?.contentView,
              let anchor = Self.newMenuAnchor(in: content) else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(SidebarMenuAction("New Session", binding: "new_tab") { [store] in store.createNewTab(in: window) })
        menu.addItem(SidebarMenuAction("New Terminal to the Right", binding: "new_split:right") {
            (window?.windowController as? BaseTerminalController)?.splitRight(window as Any)
        })
        menu.addItem(SidebarMenuAction("New Window", binding: "new_window") {
            NSApp.sendAction(#selector(AppDelegate.newWindow(_:)), to: nil, from: nil)
        })
        menu.addItem(.separator())
        let newWorkspace = SidebarMenuAction("New Workspace", binding: "") {
            Tako.TabBarView.presentNewWorkspaceDialog(in: window)
        }
        newWorkspace.identifier = .init("SessionSidebarNewWorkspace")
        menu.addItem(newWorkspace)
        // Associate the popup with its actual control and host. A screen-only
        // popup was visible but missing from the app's accessibility tree,
        // and keyboard activation incorrectly followed the mouse position.
        let belowButton = NSPoint(x: anchor.bounds.minX,
                                  y: anchor.isFlipped ? anchor.bounds.maxY : anchor.bounds.minY)
        menu.popUp(positioning: nil, at: belowButton, in: anchor)
    }

    private static func newMenuAnchor(in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == "SessionSidebarHeaderNewSession" { return view }
        for child in view.subviews {
            if let anchor = newMenuAnchor(in: child) { return anchor }
        }
        return nil
    }

    // MARK: Search

    /// The style's search field, segments and headings (`sidebar-style`).
    var chrome: SidebarChromeMetrics { .of(DesktopPresentation.shared.preferences.sidebarStyle) }

    var searchBar: some View {
        let chrome = chrome
        return HStack(spacing: 6) {
            Text("⌕").font(Font(T.monoFont(size: 12))).foregroundColor(Color(nsColor: T.faint))
            ZStack(alignment: .leading) {
                if filterText.isEmpty {
                    Text("Filter sessions…")
                        .font(Font(T.monoFont(size: 12)))
                        .foregroundColor(Color(nsColor: T.faint))
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                SidebarSearchField(text: filterTextBinding, focusRequestToken: searchFocusToken,
                                   font: T.monoFont(size: 12), textColor: T.textActive,
                                   onEscape: collapseSearchAndClearFilter)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if filterText.isEmpty {
                Text("⌘K")
                    .font(Font(T.monoFont(size: 9.5, weight: .medium)))
                    .foregroundColor(Color(nsColor: T.faint))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: T.hairline)))
                    .accessibilityHidden(true)
            } else {
                Button(action: { store.setFilterText("", for: targetWindow) }) {
                    Text("✕").font(.system(size: 10)).foregroundColor(Color(nsColor: T.dim))
                }
                .buttonStyle(.plain)
                .help("Clear · Esc")
                .accessibilityIdentifier("SessionSidebarSearchClear")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: chrome.searchHeight)
        .background(RoundedRectangle(cornerRadius: 7).fill(chrome.searchFilled ? Color(nsColor: T.chrome) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: T.hairline), lineWidth: 1))
        .background {
            // ⌘K focuses the field from anywhere in the window.
            Button("", action: toggleSearchBar).keyboardShortcut("k", modifiers: .command)
                .opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        }
        .padding(.horizontal, chrome.searchHorizontalMargin)
        .padding(.top, chrome.searchTop)
        .padding(.bottom, chrome.searchBottom)
    }

    // MARK: Segments

    func segmentsRow(attentionCount: Int, counts: SidebarAttentionCounts) -> some View {
        HStack(spacing: 4) {
            segmentButton(isActive: !filterNeedsAttention, identifier: "SessionSidebarSegmentAll", value: "") {
                store.setFilterNeedsAttention(false, for: targetWindow)
            } content: {
                Text("All")
            }
            segmentButton(isActive: filterNeedsAttention, identifier: "SessionSidebarAttentionToggle",
                          value: filterNeedsAttention ? "active" : "\(attentionCount)") {
                store.setFilterNeedsAttention(!filterNeedsAttention, for: targetWindow)
            } content: {
                HStack(spacing: 6) {
                    SidebarStatusLayerView(state: .waiting, ringCenter: nil, cornerRadius: 0,
                                           reduceMotion: Self.headerRingRests(reduceMotion: animState.reduceMotion,
                                                                              waiting: counts.waiting),
                                           paused: motionPaused, pulses: 0, ringOnly: 10)
                        .frame(width: 10, height: 10)
                    SessionSidebarCountsLabel(counts: counts, preferences: DesktopPresentation.shared.preferences)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private func segmentButton<Content: View>(isActive: Bool, identifier: String, value: String,
                                              action: @escaping () -> Void,
                                              @ViewBuilder content: () -> Content) -> some View {
        Button(action: action) {
            content()
                .font(Font(T.monoFont(size: chrome.segmentFontSize, weight: .medium)))
                .foregroundColor(Color(nsColor: isActive ? T.textActive : T.dim))
                .padding(.horizontal, 9)
                .frame(height: chrome.segmentHeight)
                .background(RoundedRectangle(cornerRadius: 6).fill(isActive ? Color(nsColor: T.surfaceActive) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityValue(value)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}

/// A menu item that runs a closure and shows the action's configured shortcut.
final class SidebarMenuAction: NSMenuItem {
    private let run: () -> Void

    init(_ title: String, binding: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(runAction), keyEquivalent: "")
        target = self
        // An item with no binding («New Workspace», a workspace's menu) shows no shortcut.
        guard !binding.isEmpty else { return }
        let shortcut = (NSApp?.delegate as? AppDelegate)?.tako.config.keyboardShortcut(for: binding)
            ?? KeybindRegistry.defaultShortcut(for: binding)
        if let shortcut {
            keyEquivalent = String(shortcut.key.character).lowercased()
            var mask: NSEvent.ModifierFlags = []
            if shortcut.modifiers.contains(.command) { mask.insert(.command) }
            if shortcut.modifiers.contains(.shift) { mask.insert(.shift) }
            if shortcut.modifiers.contains(.option) { mask.insert(.option) }
            if shortcut.modifiers.contains(.control) { mask.insert(.control) }
            keyEquivalentModifierMask = mask
        }
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }

    @objc private func runAction() { run() }

    /// In a menu that enables its items itself (a terminal's), keep the
    /// state the item was given, so a disabled one stays disabled.
    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { menuItem.isEnabled }
}

/// A 24 pt header icon over a real button (keyboard and AX reachable).
struct SidebarHeaderActionButton<LabelContent: View>: View {
    let identifier: String
    let label: String
    let value: String
    let helpText: String
    let isActive: Bool
    let action: () -> Void
    @ViewBuilder let content: (_ hovering: Bool) -> LabelContent

    @State private var hovering = false
    private typealias T = Tako.LivingTokens

    var body: some View {
        ZStack {
            content(hovering)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering ? Color(nsColor: T.surfaceHover) : isActive ? Color(nsColor: T.surfaceActive) : .clear))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            FloatingActionButtonOverlay(identifier: identifier, label: label, value: value, helpText: helpText,
                                        onHoverChange: { hovering = $0 }, action: action)
        }
        .fixedSize(horizontal: true, vertical: true)
    }
}
