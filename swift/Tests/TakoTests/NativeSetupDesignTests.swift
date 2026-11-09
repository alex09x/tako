/*
 * tako — Native five-stage setup design regressions
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import SwiftUI
import Testing
@testable import Tako

@Suite(.serialized) @MainActor
struct NativeSetupDesignTests {
    final class Calls: @unchecked Sendable { var install = 0, connect = 0, enable = 0, settings = 0, checks = 0 }

    @Test func everySavedStepMapsToOneOfFiveVisibleStages() {
        #expect(SetupStage.allCases.map(\.title) == ["Welcome", "Theme", "Agents", "Permissions", "Ready"])
        #expect(SetupStage.allCases.filter(\.isHero) == [.welcome, .ready])
        #expect(SetupStage(.commandLine) == .agents)
        #expect(SetupStage(.notifications) == .access)
        #expect(SetupStage(.permissions) == .access)
        for step in SetupStep.allCases { #expect(SetupStage(step).steps.contains(step)) }
        #expect(Set(SetupStage.allCases.flatMap(\.steps)) == Set(SetupStep.allCases))
    }

    @Test func savedSevenStepProgressResumesOnTheMatchingStage() throws {
        try fixture { model, _, defaults in
            var saved = SetupProgress(hasPresented: true, step: .notifications)
            saved.skipped = [.commandLine]
            SetupProgressStore(defaults: defaults).save(saved)
            let resumed = SetupModel(store: SetupProgressStore(defaults: defaults), services: model.services,
                                     configPath: "/nonexistent/tako-setup-design")
            #expect(resumed.stage == .access)
            #expect(resumed.progress.hasPresented)
            resumed.nextStage()
            #expect(resumed.stage == .ready)
            resumed.backStage(); resumed.backStage()
            #expect(resumed.step == .agents)
            #expect(resumed.progress.skipped == [.commandLine])
        }
    }

    @Test func skipMarksTheWholeStageAndLaterKeepsProgress() throws {
        try fixture { model, _, _ in
            var closed = 0
            model.onClose = { closed += 1 }
            model.selectStage(.access)
            model.nextStage(skipping: true)
            #expect(model.stage == .ready)
            #expect(model.progress.skipped.isSuperset(of: [.notifications, .permissions]))
            model.dismiss()
            #expect(closed == 1)
            let stored = model.store.load()
            #expect(stored.step == .ready && !stored.completed)
        }
    }

    @Test func navigationAndRefreshHaveNoInstallOrPermissionSideEffects() async throws {
        try await asyncFixture { model, calls in
            await model.refresh()
            for _ in SetupStage.allCases.dropLast() { model.nextStage() }
            #expect(model.stage == .ready)
            await model.refresh()
            #expect(calls.install == 0 && calls.connect == 0 && calls.enable == 0 && calls.settings == 0)
            #expect(model.folderAccess.isEmpty)
            #expect(model.permissionRequests.isEmpty)
            #expect(model.selectedAgents == ["claude"])
        }
    }

    @Test func sheetGeometryFitsSmallHostsAndCentersOverTheHost() {
        // Reference A14–A16: 653 wide, 389 tall for the hero cards, 714 for the lists.
        #expect(SetupSheetGeometry.size(forHost: NSSize(width: 1600, height: 1000)) == NSSize(width: 653, height: 714))
        #expect(SetupSheetGeometry.size(forHost: NSSize(width: 1600, height: 1000), stage: .welcome) == NSSize(width: 653, height: 389))
        #expect(SetupSheetGeometry.size(forHost: NSSize(width: 1600, height: 1000), stage: .access) == NSSize(width: 653, height: 714))
        let small = SetupSheetGeometry.size(forHost: NSSize(width: 560, height: 470))
        #expect(small == NSSize(width: 512, height: 422))
        #expect(SetupSheetGeometry.isCompact(small))
        #expect(SetupSheetGeometry.size(forHost: NSSize(width: 200, height: 200)) == SetupSheetGeometry.minimum)
        let host = NSRect(x: 100, y: 50, width: 1200, height: 800)
        let frame = SetupSheetGeometry.frame(forHost: host)
        #expect(frame.midX == host.midX)
        #expect(frame.maxY <= host.maxY)
    }

    @Test func readyFinishesClosesSheetAndFocusesTheExistingTerminal() throws {
        try fixture { model, calls, _ in
            _ = NSApplication.shared
            let host = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 560, height: 470),
                                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            host.isReleasedWhenClosed = false
            let terminal = NSTextView(frame: host.contentView!.bounds)
            host.contentView?.addSubview(terminal)
            host.makeKeyAndOrderFront(nil)
            host.makeFirstResponder(terminal)
            defer { host.close() }
            let coordinator = SetupCoordinator()
            let windowsBefore = NSApp.windows.filter(\.isVisible).count
            #expect(coordinator.show(model: model, in: host))
            let panel = try #require(coordinator.panel)
            #expect(panel.frame.width <= 512 && panel.frame.width >= SetupSheetGeometry.minimum.width)
            // The card is short on hero stages and grows for the lists; the top stays.
            func contentHeight() -> CGFloat { panel.contentRect(forFrameRect: panel.frame).height }
            #expect(contentHeight() == 389)
            model.selectStage(.access)
            #expect(contentHeight() == 422)
            model.selectStage(.ready)
            #expect(contentHeight() == 389)
            // Where the attached sheet sits is AppKit's; checked in the GUI run.
            model.nextStage()
            #expect(coordinator.panel == nil)
            #expect(host.attachedSheet == nil)
            #expect(host.firstResponder === terminal)
            #expect(model.store.load().completed)
            #expect(NSApp.windows.filter(\.isVisible).count <= windowsBefore)
            #expect(calls.install == 0 && calls.connect == 0)
        }
    }

    /// At launch setup appears before the terminal has taken focus: the
    /// window itself is first responder. Finishing must hand the keys to the
    /// existing terminal, not back to the window (XCUI: typing right after
    /// «Начать работу» reached nothing).
    @Test func finishingAtLaunchFocusesTheTerminalEvenIfTheWindowHadFocus() throws {
        try fixture { model, _, _ in
            _ = NSApplication.shared
            let host = NSWindow(contentRect: NSRect(x: 120, y: 120, width: 900, height: 700),
                                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            host.isReleasedWhenClosed = false
            let terminal = NSTextView(frame: host.contentView!.bounds)
            host.contentView?.addSubview(terminal)
            // Another view (the sidebar list takes focus when it appears) held the keys.
            let sidebar = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
            host.contentView?.addSubview(sidebar)
            host.makeKeyAndOrderFront(nil)
            defer { host.close() }
            let coordinator = SetupCoordinator()
            coordinator.terminalToFocus = { $0 === host ? terminal : nil }
            for previous in [nil, sidebar] as [NSResponder?] {
                host.makeFirstResponder(previous)
                #expect(coordinator.show(model: model, in: host))
                model.selectStage(.ready)
                model.finishSetup()
                #expect(coordinator.panel == nil)
                #expect(host.firstResponder === terminal,
                        "keys go to the terminal (before: \(String(describing: previous))), got \(String(describing: host.firstResponder))")
            }
        }
    }

    @Test func paletteFollowsDesktopPresentationNotTheTerminalPreview() {
        let dark = SetupPalette(desktop: .dark, isDark: true)
        let light = SetupPalette(desktop: .light, isDark: false)
        #expect(dark.background == Color(nsColor: DesktopPalette.dark.panel))
        #expect(light.background == Color(nsColor: DesktopPalette.light.panel))
        #expect(dark.isDark && !light.isDark)
        let presentation = DesktopPresentation(observe: false, systemIsDark: false)
        let model = SetupModel(store: SetupProgressStore(defaults: UserDefaults(suiteName: "NativeSetupPalette")!),
                               services: Self.services(Calls()), configPath: "/nonexistent/tako-setup-design")
        let view = SetupWizardView(model: model, presentation: presentation)
        #expect(view.presentation.palette.panel == DesktopPalette.light.panel)
        UserDefaults().removePersistentDomain(forName: "NativeSetupPalette")
    }

    static func services(_ calls: Calls) -> SetupServices {
        SetupServices(checkCLI: { calls.checks += 1; return .init(installed: false, detail: "Optional") },
            installCLI: { calls.install += 1; return .init(installed: true, detail: "Unused") },
            checkAgents: {
                [SetupAgentService.Status(id: "claude", name: "Claude Code", isDetected: true, hooksInstalled: false,
                                          skillInstalled: false, detail: nil)]
            },
            connectAgents: { _ in calls.connect += 1; return [] },
            checkNotifications: { .init(access: .notAsked) },
            enableNotifications: { calls.enable += 1; return .init(access: .allowed) },
            openNotificationSettings: { calls.settings += 1 })
    }

    private func fixture(_ body: (SetupModel, Calls, UserDefaults) throws -> Void) throws {
        let name = "NativeSetupDesignTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let calls = Calls()
        let model = SetupModel(store: SetupProgressStore(defaults: defaults), services: Self.services(calls),
                               configPath: "/nonexistent/tako-setup-design")
        try body(model, calls, defaults)
    }

    private func asyncFixture(_ body: (SetupModel, Calls) async throws -> Void) async throws {
        let name = "NativeSetupDesignTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let calls = Calls()
        let model = SetupModel(store: SetupProgressStore(defaults: defaults), services: Self.services(calls),
                               configPath: "/nonexistent/tako-setup-design")
        try await body(model, calls)
    }
}
