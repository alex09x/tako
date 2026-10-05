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

@Suite @MainActor struct BroadcastInputTests {

    final class MockSurface: AnyObject {
        let id: UUID
        var isLocked: Bool = false
        var writtenBytes: [[UInt8]] = []
        var insertedTexts: [String] = []

        init(id: UUID = UUID(), isLocked: Bool = false) {
            self.id = id
            self.isLocked = isLocked
        }

        func writeToShell(_ bytes: [UInt8]) {
            writtenBytes.append(bytes)
        }

        func insertText(_ text: String) {
            insertedTexts.append(text)
        }
    }

    @Test func testInitialState() {
        let store = BroadcastInputStore()
        let paneId = UUID()

        #expect(store.isBroadcasting == false)
        #expect(store.activeSession == nil)
        #expect(store.isParticipating(paneId: paneId) == false)
        #expect(store.isLeader(paneId: paneId) == false)
    }

    @Test func testStartAndEndBroadcast() {
        let store = BroadcastInputStore()
        let p1 = UUID()
        let p2 = UUID()
        let p3 = UUID()

        // Starting with fewer than 2 panes fails
        let failed = store.startBroadcast(panes: [p1])
        #expect(failed == false)
        #expect(store.isBroadcasting == false)

        // Starting with 3 panes succeeds
        let success = store.startBroadcast(panes: [p1, p2, p3], leader: p1)
        #expect(success == true)
        #expect(store.isBroadcasting == true)
        #expect(store.activeSession?.selectedPaneIds.count == 3)
        #expect(store.isParticipating(paneId: p1) == true)
        #expect(store.isParticipating(paneId: p2) == true)
        #expect(store.isParticipating(paneId: p3) == true)
        #expect(store.isLeader(paneId: p1) == true)
        #expect(store.isLeader(paneId: p2) == false)

        // Changing leader
        store.setLeader(paneId: p2)
        #expect(store.isLeader(paneId: p2) == true)
        #expect(store.isLeader(paneId: p1) == false)

        // Ending broadcast
        store.endBroadcast()
        #expect(store.isBroadcasting == false)
        #expect(store.activeSession == nil)
    }

    @Test func testEndsWithSelection() {
        let store = BroadcastInputStore()
        let p1 = UUID()
        let p2 = UUID()
        let p3 = UUID()

        store.startBroadcast(panes: [p1, p2, p3], leader: p1)
        #expect(store.isBroadcasting == true)

        // Closing one pane retains broadcast across the remaining 2
        store.paneClosed(p3)
        #expect(store.isBroadcasting == true)
        #expect(store.activeSession?.selectedPaneIds == [p1, p2])

        // Closing another pane drops selection to 1 -> broadcast ends automatically
        store.paneClosed(p2)
        #expect(store.isBroadcasting == false)
        #expect(store.activeSession == nil)

        // Selection update dropping below 2 ends broadcast immediately
        store.startBroadcast(panes: [p1, p2, p3], leader: p1)
        #expect(store.isBroadcasting == true)
        store.updateSelection(panes: [p1])
        #expect(store.isBroadcasting == false)
        #expect(store.activeSession == nil)
    }

    @Test func testSecureInputPanesNeverReceiveBroadcast() {
        let store = BroadcastInputStore()
        let secureInput = SecureInput.shared

        let s1 = MockSurface()
        let s2 = MockSurface()
        let s3 = MockSurface()

        let surfaces: [UUID: MockSurface] = [s1.id: s1, s2.id: s2, s3.id: s3]

        store.startBroadcast(panes: [s1.id, s2.id, s3.id], leader: s1.id)

        // Mark s2 as secure input
        secureInput.setScoped(ObjectIdentifier(s2), focused: true)
        #expect(secureInput.isSecure(for: s2) == true)
        #expect(secureInput.isSecure(for: s3) == false)

        // Broadcast input bytes from s1
        let testData = Data([0x68, 0x65, 0x6C, 0x6C, 0x6F]) // "hello"
        store.broadcastInput(from: s1, sourceId: s1.id, data: testData) { targetId in
            guard let surface = surfaces[targetId] else { return nil }
            return (target: surface, isLocked: surface.isLocked, write: { surface.writeToShell($0) })
        }

        // s1 is sender; s2 is secure (MUST NOT RECEIVE); s3 is normal (MUST RECEIVE)
        #expect(s1.writtenBytes.isEmpty)
        #expect(s2.writtenBytes.isEmpty)
        #expect(s3.writtenBytes.count == 1)
        #expect(s3.writtenBytes.first == [0x68, 0x65, 0x6C, 0x6C, 0x6F])

        // Broadcast text (paste) from s1
        store.broadcastText(from: s1, sourceId: s1.id, text: "uname -a\n") { targetId in
            guard let surface = surfaces[targetId] else { return nil }
            return (target: surface, isLocked: surface.isLocked, insertText: { surface.insertText($0) })
        }

        #expect(s2.insertedTexts.isEmpty)
        #expect(s3.insertedTexts == ["uname -a\n"])

        // If the typing surface itself becomes secure, it MUST NOT broadcast out
        secureInput.setScoped(ObjectIdentifier(s1), focused: true)
        store.broadcastInput(from: s1, sourceId: s1.id, data: Data([0x0A])) { targetId in
            guard let surface = surfaces[targetId] else { return nil }
            return (target: surface, isLocked: surface.isLocked, write: { surface.writeToShell($0) })
        }
        #expect(s3.writtenBytes.count == 1) // unchanged, no leak!

        // Clean up scoped secure input
        secureInput.removeScoped(ObjectIdentifier(s1))
        secureInput.removeScoped(ObjectIdentifier(s2))
    }

    @Test func testLockedPanesNeverReceiveBroadcast() {
        let store = BroadcastInputStore()
        let s1 = MockSurface()
        let s2 = MockSurface(isLocked: true) // locked by agent
        let s3 = MockSurface(isLocked: false)

        let surfaces: [UUID: MockSurface] = [s1.id: s1, s2.id: s2, s3.id: s3]

        store.startBroadcast(panes: [s1.id, s2.id, s3.id], leader: s1.id)

        store.broadcastInput(from: s1, sourceId: s1.id, data: Data([0x61])) { targetId in
            guard let surface = surfaces[targetId] else { return nil }
            return (target: surface, isLocked: surface.isLocked, write: { surface.writeToShell($0) })
        }

        #expect(s2.writtenBytes.isEmpty)
        #expect(s3.writtenBytes.count == 1)
    }
}
