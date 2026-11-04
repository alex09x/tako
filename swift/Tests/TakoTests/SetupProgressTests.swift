/*
 * tako — First-run setup state regression tests
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Testing
@testable import Tako

@Suite(.serialized) @MainActor
struct SetupProgressTests {
    @Test func launchSuppressionDoesNotConfuseUpdatesWithSetup() {
        #expect(SetupProgressStore.allowsLaunch(arguments: ["Tako", "--no-update"],
            environment: ["TAKO_NO_UPDATE": "1"], isTesting: false))
        for args in [["--no-launch-notices"], ["--selftest"], ["--selftest-input"]] {
            #expect(!SetupProgressStore.allowsLaunch(arguments: args, environment: [:], isTesting: false))
        }
        #expect(!SetupProgressStore.allowsLaunch(arguments: [], environment: ["TAKO_NO_LAUNCH_NOTICES": "1"], isTesting: false))
        #expect(!SetupProgressStore.allowsLaunch(arguments: [], environment: [:], isTesting: true))
    }

    @Test func closingAndReopeningResumesWithoutRunningInstallers() async throws {
        try await withStore { store in
            let calls = Calls()
            let model = SetupModel(store: store, services: services(calls))
            model.didPresent()
            model.select(.agents)
            model.dismiss()
            let reopened = SetupModel(store: store, services: services(calls))
            #expect(reopened.step == .agents)
            #expect(reopened.progress.hasPresented)
            #expect(!reopened.progress.completed)
            #expect(calls.installs == 0 && calls.permissionRequests == 0)
        }
    }

    @Test func skipAllLeavesIntegrationsOffAndTerminalReady() async throws {
        try await withStore { store in
            let calls = Calls()
            let model = SetupModel(store: store, services: services(calls))
            model.didPresent()
            await model.refresh()
            while model.step != .ready { model.next(skipping: true) }
            var closed = false
            model.onClose = { closed = true }
            model.next()
            #expect(closed && store.load().completed)
            #expect(!model.cli.installed)
            #expect(model.agents.allSatisfy { !$0.isReady })
            #expect(model.notifications.access == .notAsked)
            #expect(calls.installs == 0 && calls.permissionRequests == 0)
            #expect(!store.defaults.bool(forKey: SetupProgressStore.notificationOptInKey))
        }
    }

    @Test func refreshReadsRealChangesWithoutRequestingConsent() async throws {
        try await withStore { store in
            let calls = Calls()
            let model = SetupModel(store: store, services: services(calls))
            await model.refresh()
            #expect(model.notifications.access == .notAsked)
            calls.access = .denied
            await model.refresh()
            #expect(model.notifications.access == .denied)
            #expect(calls.permissionRequests == 0)
            await model.enableNotifications()
            #expect(calls.permissionRequests == 1)
            #expect(model.notifications.access == .denied)
        }
    }

    @Test func connectsOnlySelectedDetectedAgentsAndRetainsFailure() async throws {
        try await withStore { store in
            let calls = Calls()
            let model = SetupModel(store: store, services: services(calls))
            await model.refresh()
            model.selectedAgents = ["codex", "missing"]
            await model.connectSelected()
            #expect(calls.selected == ["codex"])
            #expect(model.agents.first?.isReady == false)
            #expect(model.message != nil)
            #expect(!model.isBusy)
        }
    }

    @Test func priorAgentDeclineIsNotAutomaticallySelectedAgain() async throws {
        try await withStore { store in
            store.defaults.set(true, forKey: AgentHooksTool.declinedKey)
            let model = SetupModel(store: store, services: services(Calls()))
            await model.refresh()
            #expect(model.selectedAgents.isEmpty)
            #expect(store.defaults.bool(forKey: AgentHooksTool.declinedKey))
        }
    }

    @Test func unknownProgressIsNotOverwrittenOrAutoOffered() async throws {
        try await withStore { store in
            let unknown = Data("{\"version\":99,\"future\":true}".utf8)
            store.defaults.set(unknown, forKey: SetupProgressStore.key)
            #expect(store.load().hasPresented)
            store.save(SetupProgress(completed: true))
            #expect(store.defaults.data(forKey: SetupProgressStore.key) == unknown)
        }
    }

    @Test func badgeOnlyPermissionDoesNotReadAsFullyEnabled() {
        let state = SetupNotificationStatus(access: .allowed, badges: true)
        #expect(state.title == "Partly enabled")
        #expect(!state.alerts && !state.sounds)
    }

    @Test func firstRunThemesKeepTheCurrentCustomPresetWithoutListingEveryFile() {
        let builtins = ["TakoCore", "Tako Forest", "Tako Night", "Tako Ocean", "Tako Slate"]
        let available = ["Temporary test preset", "Personal theme"] + builtins
        #expect(SetupAppearanceStep.choiceNames(available: available, current: "personal THEME")
            == ["Personal theme"] + builtins)
        #expect(SetupAppearanceStep.choiceNames(available: available, current: "tako") == builtins)
        #expect(SetupAppearanceStep.isSelected("TakoCore", current: "tako"))
        #expect(!SetupAppearanceStep.isSelected("Tako Forest", current: "TakoCore"))
    }

    @Test func explicitAgentSelectionSurvivesReentry() async throws {
        try await selectionSurvivesReentry(["codex"])
    }

    @Test func explicitEmptyAgentSelectionIsNotReplacedWithRecommendations() async throws {
        try await selectionSurvivesReentry([])
    }

    @Test func earlierProgressWithoutAgentSelectionStillResumes() async throws {
        try await withStore { store in
            let legacy = #"{"version":1,"hasPresented":true,"completed":false,"step":"agents","skipped":[]}"#
            store.defaults.set(Data(legacy.utf8), forKey: SetupProgressStore.key)
            let progress = store.load()
            #expect(progress.hasPresented && progress.step == .agents)
            #expect(progress.agentSelection == nil && store.canWrite)
        }
    }

    private func selectionSurvivesReentry(_ selected: Set<String>) async throws {
        try await withStore { store in
            var service = services(Calls())
            service.checkAgents = {
                ["codex", "claude"].map { id in
                    SetupAgentService.Status(id: id, name: id, isDetected: true,
                        hooksInstalled: false, skillInstalled: false, detail: nil)
                }
            }
            let first = SetupModel(store: store, services: service)
            await first.refresh()
            #expect(first.selectedAgents == ["codex", "claude"])
            first.selectedAgents = selected
            first.dismiss()
            let reopened = SetupModel(store: store, services: service)
            await reopened.refresh()
            #expect(reopened.selectedAgents == selected)
        }
    }

    private final class Calls {
        var installs = 0
        var permissionRequests = 0
        var selected: [String] = []
        var access: SetupNotificationStatus.Access = .notAsked
    }

    private func services(_ calls: Calls) -> SetupServices {
        let agents = [
            SetupAgentService.Status(id: "codex", name: "Codex", isDetected: true,
                hooksInstalled: true, skillInstalled: false, detail: "Skill install failed"),
            SetupAgentService.Status(id: "missing", name: "Missing", isDetected: false,
                hooksInstalled: false, skillInstalled: false, detail: nil)
        ]
        return SetupServices(checkCLI: { SetupCLIStatus(installed: false, detail: "Not installed") },
            installCLI: { calls.installs += 1; return SetupCLIStatus(installed: false, detail: "Failed", failure: "Not writable") },
            checkAgents: { agents }, connectAgents: { ids in calls.selected = ids; return agents },
            checkNotifications: { SetupNotificationStatus(access: calls.access) },
            enableNotifications: { calls.permissionRequests += 1; return SetupNotificationStatus(access: calls.access) },
            openNotificationSettings: {})
    }

    private func withStore(_ body: (SetupProgressStore) async throws -> Void) async throws {
        let name = "TakoSetupTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try await body(SetupProgressStore(defaults: defaults))
    }
}
