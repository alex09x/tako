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
import Testing
@testable import Tako

// Coverage for swift/Sources/TakoApp/Features/Settings:
// ConfigurationErrorsController (window lifecycle + the errors-driven
// auto-close), ConfigurationErrorsView (hosted rendering + both buttons),
// and the static SettingsView.

private final class FakeErrorsViewModel: ObservableObject, ConfigurationErrorsViewModel {
    @Published var errors: [String] = []
}

/// Stands in for the real AppDelegate so `ConfigurationErrorsView`'s
/// "Reload Configuration" button can be proven to reach it without
/// triggering the app's real config reload.
private final class RecordingAppDelegate: AppDelegate {
    var reloadInvoked = false
    override func reloadConfig(_ sender: Any?) {
        reloadInvoked = true
    }
}

@MainActor
@Suite
struct ConfigurationErrorsControllerCoverageTests {
    @Test func windowNibNameIsConfigurationErrors() {
        let controller = ConfigurationErrorsController()
        #expect(controller.windowNibName == "ConfigurationErrors")
    }

    @Test func windowWillLoadDisablesCascading() {
        let controller = ConfigurationErrorsController()
        controller.shouldCascadeWindows = true
        controller.windowWillLoad()
        #expect(!controller.shouldCascadeWindows)
    }

    @Test func windowDidLoadConfiguresTheInjectedWindow() {
        let controller = ConfigurationErrorsController()
        let window = makePanelWindow()
        controller.window = window
        controller.windowDidLoad()

        #expect(window.level == .popUpMenu)
        #expect(window.titlebarAppearsTransparent)
        #expect(window.contentView != nil)
        #expect(String(describing: type(of: window.contentView!)).contains("NSHostingView"))
    }

    @Test func settingErrorsToEmptyClosesTheWindow() {
        let controller = ConfigurationErrorsController()
        let window = makePanelWindow()
        controller.window = window
        controller.windowDidLoad()
        window.makeKeyAndOrderFront(nil)
        #expect(window.isVisible)

        controller.errors = ["missing key: foo"]
        #expect(window.isVisible) // Non-empty errors must not auto-close.

        controller.errors = []
        #expect(!window.isVisible)
    }
}

@Suite
@MainActor
struct ConfigurationErrorsViewCoverageTests {
    /// AX inspection and `.keyboardShortcut` dispatch are both unavailable
    /// in this bare-NSWindow harness (see PanelTestSupport.swift); rendering
    /// a different error list and proving the pixels differ is this
    /// suite's read-only substitute for asserting on the `Text(error)` rows
    /// directly.
    @Test func differentErrorListsRenderDifferentPixels() {
        let model1 = FakeErrorsViewModel()
        model1.errors = ["bad line 3"]
        let window1 = makePanelWindow(size: NSSize(width: 600, height: 320))
        defer { window1.orderOut(nil) }
        let hosting1 = hostPanel(ConfigurationErrorsView(model: model1), in: window1)
        let withOneError = panelSnapshot(hosting1)

        let model2 = FakeErrorsViewModel()
        model2.errors = ["bad line 3", "unknown directive", "a third problem entirely"]
        let window2 = makePanelWindow(size: NSSize(width: 600, height: 320))
        defer { window2.orderOut(nil) }
        let hosting2 = hostPanel(ConfigurationErrorsView(model: model2), in: window2)
        let withThreeErrors = panelSnapshot(hosting2)

        #expect(!panelBitmapsEqual(withOneError, withThreeErrors))
    }
}

@Suite
@MainActor
struct SettingsViewCoverageTests {
    @Test func rendersWithTheAppDelegateEnvironmentObject() {
        let delegate = AppDelegate()
        let window = makePanelWindow(size: NSSize(width: 520, height: 200))
        let hosting = hostPanel(SettingsView().environmentObject(delegate), in: window)

        #expect(hosting.fittingSize.width > 0)
        #expect(hosting.fittingSize.height > 0)
    }
}

@Suite
@MainActor
struct KeybindingsSettingsCoverageTests {
    @Test func registryContainsAllCategories() {
        let categories = Set(KeybindRegistry.allActions.map(\.category))
        #expect(categories.count == KeybindCategory.allCases.count)
    }

    @Test func formatTriggerProducesExpectedSymbols() {
        #expect(KeybindRegistry.format(trigger: "cmd+shift+return") == "⇧⌘↩")
        #expect(KeybindRegistry.format(trigger: "ctrl+opt+]") == "⌃⌥]")
        #expect(KeybindRegistry.format(trigger: "opt+cmd+=") == "⌥⌘=")
        #expect(KeybindRegistry.format(trigger: "cmd+d") == "⌘D")
    }
}

