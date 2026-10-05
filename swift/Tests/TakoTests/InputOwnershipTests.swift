/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Testing
@testable import Tako

@Suite @MainActor struct InputOwnershipTests {

    @Test func testInitialState() {
        let store = InputOwnershipStore()
        let paneId = UUID()

        let state = store.state(for: paneId)
        #expect(state.isLocked == false)
        #expect(state.owner == .human)
        #expect(state.previousAgent == nil)
        #expect(state.lastActivityMark == nil)
        #expect(state.activityLog.isEmpty)
        #expect(store.isLocked(for: paneId) == false)
        #expect(store.owner(for: paneId) == .human)
    }

    @Test func testLockAndUnlock() {
        let store = InputOwnershipStore()
        let paneId = UUID()

        store.lock(paneId: paneId, by: "claude-code")
        #expect(store.isLocked(for: paneId) == true)
        #expect(store.owner(for: paneId) == .agent(name: "claude-code"))
        #expect(store.owner(for: paneId).isAgent == true)
        #expect(store.owner(for: paneId).agentName == "claude-code")

        store.unlock(paneId: paneId)
        #expect(store.isLocked(for: paneId) == false)
        #expect(store.owner(for: paneId) == .human)
        #expect(store.owner(for: paneId).isAgent == false)
        #expect(store.owner(for: paneId).agentName == nil)
        #expect(store.previousAgent(for: paneId) == nil)
    }

    @Test func testTakeOverAndHandBack() {
        let store = InputOwnershipStore()
        let paneId = UUID()

        // 1. Agent locks the pane
        store.lock(paneId: paneId, by: "codex-subagent")
        #expect(store.isLocked(for: paneId) == true)
        #expect(store.owner(for: paneId) == .agent(name: "codex-subagent"))

        // 2. Human user takes over
        store.takeOver(paneId: paneId)
        #expect(store.isLocked(for: paneId) == false)
        #expect(store.owner(for: paneId) == .human)
        #expect(store.previousAgent(for: paneId) == "codex-subagent")

        // 3. Human hands back control to the agent
        store.handBack(paneId: paneId)
        #expect(store.isLocked(for: paneId) == true)
        #expect(store.owner(for: paneId) == .agent(name: "codex-subagent"))

        // 4. Human takes over again, and hands back to a new agent explicitly
        store.takeOver(paneId: paneId)
        #expect(store.isLocked(for: paneId) == false)
        store.handBack(paneId: paneId, to: "gemini-helper")
        #expect(store.isLocked(for: paneId) == true)
        #expect(store.owner(for: paneId) == .agent(name: "gemini-helper"))
    }

    @Test func testActivityAttributionAndMaxLogEntries() {
        let store = InputOwnershipStore()
        let paneId = UUID()

        // Record automated keystrokes from client
        store.recordAutomation(paneId: paneId, client: "takoctl", action: "type")
        var mark = store.lastActivityMark(for: paneId)
        #expect(mark != nil)
        #expect(mark?.client == "takoctl")
        #expect(mark?.action == "type")
        #expect(store.activityLog(for: paneId).count == 1)

        store.recordAutomation(paneId: paneId, client: "claude-worker", action: "send")
        mark = store.lastActivityMark(for: paneId)
        #expect(mark?.client == "claude-worker")
        #expect(mark?.action == "send")
        #expect(store.activityLog(for: paneId).count == 2)

        // Verify bounding to maxLogEntriesPerPane (100)
        for i in 1...110 {
            store.recordAutomation(paneId: paneId, client: "client-\(i)", action: "key enter")
        }
        let log = store.activityLog(for: paneId)
        #expect(log.count == InputOwnershipStore.maxLogEntriesPerPane)
        #expect(log.last?.client == "client-110")
        #expect(log.first?.client == "client-11")
    }

    @Test func testClearActivityMarkAndRemoval() {
        let store = InputOwnershipStore()
        let paneId = UUID()

        store.lock(paneId: paneId, by: "agent-x")
        store.recordAutomation(paneId: paneId, client: "bot", action: "key ctrl+c")
        #expect(store.lastActivityMark(for: paneId) != nil)

        store.clearActivityMark(paneId: paneId)
        #expect(store.lastActivityMark(for: paneId) == nil)
        #expect(store.isLocked(for: paneId) == true)

        store.remove(paneId: paneId)
        #expect(store.isLocked(for: paneId) == false)
        #expect(store.owner(for: paneId) == .human)
        #expect(store.activityLog(for: paneId).isEmpty)
    }

    @Test func testPaneLevelAutomationSwitchAndCreatorTyping() {
        let store = InputOwnershipStore()
        let paneId = UUID()

        // 1. Initial state: not created by any client, automation may not type
        #expect(store.creatorClient(for: paneId) == nil)
        #expect(store.automationMayType(for: paneId) == false)
        #expect(store.canClientType(paneId: paneId, client: "agent-1") == false)
        #expect(store.canClientType(paneId: paneId, client: "takoctl") == false)

        // 2. Creator client can type into pane it created
        store.setCreatorClient(paneId: paneId, client: "agent-1")
        #expect(store.creatorClient(for: paneId) == "agent-1")
        #expect(store.canClientType(paneId: paneId, client: "agent-1") == true)
        #expect(store.canClientType(paneId: paneId, client: "agent-2") == false)

        // 3. Enabling "automation may type here" allows any client to type
        store.setAutomationMayType(paneId: paneId, allowed: true)
        #expect(store.automationMayType(for: paneId) == true)
        #expect(store.canClientType(paneId: paneId, client: "agent-2") == true)
        #expect(store.canClientType(paneId: paneId, client: "takoctl") == true)

        // 4. Disabling "automation may type here" revokes non-creator permission
        store.setAutomationMayType(paneId: paneId, allowed: false)
        #expect(store.automationMayType(for: paneId) == false)
        #expect(store.canClientType(paneId: paneId, client: "agent-1") == true)
        #expect(store.canClientType(paneId: paneId, client: "agent-2") == false)

        // 5. One-time confirmation allows typing once and resets
        store.confirmOneTimeTyping(paneId: paneId)
        #expect(store.canClientType(paneId: paneId, client: "agent-2") == true)
        #expect(store.canClientType(paneId: paneId, client: "agent-2") == false)
    }
}
