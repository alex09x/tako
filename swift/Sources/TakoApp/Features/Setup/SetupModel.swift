/*
 * tako — Resumable setup state and actions
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import SwiftUI

@MainActor
final class SetupModel: ObservableObject {
    @Published private(set) var progress: SetupProgress
    @Published private(set) var cli = SetupCLIStatus(installed: false, detail: "Checking…")
    @Published private(set) var agents: [SetupAgentService.Status] = []
    @Published private(set) var notifications = SetupNotificationStatus(access: .unavailable)
    @Published private(set) var isBusy = false
    @Published private(set) var isRefreshing = false
    @Published var selectedAgents: Set<String> = [] {
        didSet {
            guard loadedAgents else { return }
            progress.agentSelection = selectedAgents
            store.save(progress)
        }
    }
    @Published var message: String?
    @Published var selectedTheme: String
    @Published private(set) var previewTheme: TerminalTheme
    let store: SetupProgressStore
    let services: SetupServices
    let configFile: KeybindConfigFile
    var onClose: () -> Void = {}
    private var loadedAgents = false
    private var refreshID = UUID()

    init(store: SetupProgressStore = SetupProgressStore(), services: SetupServices? = nil,
         configPath: String? = nil) {
        self.store = store
        self.services = services ?? .live(defaults: store.defaults)
        let config = KeybindConfigFile(configPath: configPath)
        config.reload()
        self.configFile = config
        self.progress = store.load()
        self.selectedTheme = TerminalSettingRegistry.setting(for: "theme")
            .flatMap { config.getSettingValue(for: $0) } ?? "TakoCore"
        self.previewTheme = Self.readTheme(config)
    }

    var step: SetupStep { progress.step }
    var stepIndex: Int { SetupStep.allCases.firstIndex(of: step) ?? 0 }
    var selectedDetectedAgents: [String] {
        agents.filter { $0.isDetected && !$0.isReady && selectedAgents.contains($0.id) }.map(\.id)
    }

    func didPresent() {
        progress.hasPresented = true
        store.save(progress)
    }

    func select(_ step: SetupStep) {
        guard !isBusy else { return }
        progress.step = step
        message = nil
        store.save(progress)
    }

    func next(skipping: Bool = false) {
        guard !isBusy else { return }
        if skipping { progress.skipped.insert(step) }
        if step == .ready {
            progress.completed = true
            store.save(progress)
            onClose()
        } else {
            select(SetupStep.allCases[min(stepIndex + 1, SetupStep.allCases.count - 1)])
        }
    }

    func back() { select(SetupStep.allCases[max(0, stepIndex - 1)]) }

    func dismiss() {
        guard !isBusy else { return }
        store.save(progress)
        onClose()
    }

    func refresh() async {
        guard !isBusy else { return }
        let id = UUID()
        refreshID = id
        isRefreshing = true
        cli = services.checkCLI()
        let newNotifications = await services.checkNotifications()
        let newAgents = await services.checkAgents()
        guard refreshID == id, !isBusy else { return }
        notifications = newNotifications
        agents = newAgents
        if !loadedAgents {
            if let selection = progress.agentSelection {
                selectedAgents = selection
            } else if !store.defaults.bool(forKey: AgentHooksTool.declinedKey), !progress.skipped.contains(.agents) {
                selectedAgents = Set(agents.filter { $0.isDetected && !$0.isReady }.map(\.id))
            }
            loadedAgents = true
        }
        isRefreshing = false
    }

    func installCLI() {
        guard !isBusy else { return }
        cli = services.installCLI()
        message = cli.failure
        if cli.installed { progress.skipped.remove(.commandLine); store.save(progress) }
    }

    func connectSelected() async {
        let ids = selectedDetectedAgents
        guard !isBusy, !isRefreshing, !ids.isEmpty else { return }
        progress.agentSelection = selectedAgents
        store.save(progress)
        isBusy = true
        message = nil
        refreshID = UUID()
        agents = await services.connectAgents(ids)
        let failed = agents.filter { ids.contains($0.id) && !$0.isReady }
        message = failed.isEmpty ? nil : "Some agents still need attention. See the details below."
        if failed.isEmpty { progress.skipped.remove(.agents); store.save(progress) }
        isBusy = false
    }

    func enableNotifications() async {
        guard !isBusy else { return }
        isBusy = true
        refreshID = UUID()
        notifications = await services.enableNotifications()
        message = notifications.failure
        if notifications.access == .allowed { progress.skipped.remove(.notifications); store.save(progress) }
        isBusy = false
    }

    func checkNotificationsAndSendTest() async {
        guard !isBusy, !isRefreshing else { return }
        isBusy = true
        refreshID = UUID()
        message = nil
        defer { isBusy = false }
        notifications = await services.checkNotifications()
        switch notifications.access {
        case .allowed:
            if let error = await services.sendTestNotification() {
                message = "Test notification couldn't be sent: \(error)"
            } else {
                message = notifications.alerts ? "Test notification sent."
                    : "Test notification sent. Banners are off in macOS Settings."
            }
        case .denied: message = "Notifications are disabled in macOS Settings."
        case .notAsked: message = "Enable notifications first to receive a test notification."
        case .unavailable: message = "Notification service is unavailable."
        }
    }

    func requestPermission(_ kind: TerminalPermissionKind, service: TerminalPermissionService) async {
        guard !isBusy, !isRefreshing else { return }
        isBusy = true
        message = nil
        defer { isBusy = false }
        let result = await service.request(kind)
        await service.snapshot()
        message = result.message
    }

    func checkSelectedFolder(using service: SetupFolderAccess? = nil) async {
        guard !isBusy, !isRefreshing else { return }
        isBusy = true
        message = nil
        defer { isBusy = false }
        let result = await (service ?? SetupFolderAccess()).chooseAndCheck()
        message = result?.message ?? "Folder check canceled. No access was checked or requested."
    }

    func chooseTheme(_ name: String) {
        guard !isBusy else { return }
        if configFile.applySetupColorPreset(name, preserving: Self.readTheme(configFile)) {
            previewTheme = Self.readTheme(configFile)
            selectedTheme = name
            message = nil
            progress.skipped.remove(.appearance)
            store.save(progress)
        } else {
            message = "The theme couldn't be saved. Check that your Tako configuration is writable."
        }
    }

    private static func readTheme(_ file: KeybindConfigFile) -> TerminalTheme {
        let text = file.configPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
        return TerminalTheme.parse(config: text, configPath: file.configPath,
                                   darkAppearance: TakoSystemAppearance.isDark)
    }
}
