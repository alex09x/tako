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
import Testing
@testable import Tako

/// A session offered at launch and not restored is not offered again on the
/// next launch; a new session, or a new generation of the same one, is.
struct SessionRecoveryDeferralTests {
    private func candidate(_ id: UUID, generation: String?) -> SessionRecoveryInventory.Candidate {
        .init(id: id, runtimeID: "0.8.1-0000000000000000", identity: .verified, record: nil,
              observedInRuntime: true, observedGeneration: generation, processID: nil, executableName: nil)
    }

    private func sandbox() throws -> (SessionRecoveryDeferral, () -> Void) {
        let suite = "tako-deferral-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (SessionRecoveryDeferral(defaults: defaults), { defaults.removePersistentDomain(forName: suite) })
    }

    @Test func aSessionAlreadyOfferedIsNotAskedAboutAgain() throws {
        let (deferral, cleanup) = try sandbox()
        defer { cleanup() }
        let first = candidate(UUID(), generation: "a"), second = candidate(UUID(), generation: "b")
        #expect(deferral.unasked([first]) == [first], "nothing was offered yet")

        deferral.remember(offered: [first])
        #expect(deferral.unasked([first]).isEmpty)
        #expect(deferral.unasked([first, second]) == [second], "a new session is a new question")
    }

    @Test func aNewGenerationOfTheSameSessionIsAskedAbout() throws {
        let (deferral, cleanup) = try sandbox()
        defer { cleanup() }
        let id = UUID()
        deferral.remember(offered: [candidate(id, generation: "a")])
        #expect(deferral.unasked([candidate(id, generation: "b")]).count == 1)
        #expect(deferral.unasked([candidate(id, generation: nil)]).count == 1)
    }

    @Test func rememberingKeepsOnlyWhatIsStillRunning() throws {
        let (deferral, cleanup) = try sandbox()
        defer { cleanup() }
        let gone = candidate(UUID(), generation: "a"), alive = candidate(UUID(), generation: "b")
        deferral.remember(offered: [gone, alive])
        deferral.remember(offered: [alive])
        #expect(deferral.deferred == [SessionRecoveryDeferral.key(for: alive)])
    }

    // MARK: - The real question (TerminalDialogView in a window)

    @MainActor private func window(drawable: Bool = true) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = drawable ? NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600)) : nil
        return window
    }

    private func verified(_ id: UUID = UUID(), generation: String = "a") -> SessionRecoveryInventory.Candidate {
        let record = SessionRecord(id: id, runtimeID: "0.8.1-0000000000000000", generation: generation,
                                   state: .detached, createdAt: Date())
        return .init(id: id, runtimeID: record.runtimeID, identity: .verified, record: record,
                     observedInRuntime: true, observedGeneration: generation, processID: nil, executableName: nil)
    }

    /// Asks through the real dialog and presses `button` once it is up; nil
    /// presses nothing (for a question that never appears).
    @MainActor
    private func ask(_ found: [SessionRecoveryInventory.Candidate], _ deferral: SessionRecoveryDeferral,
                     in window: NSWindow, showEmpty: Bool = false, persistence: Bool = true,
                     press button: String?) async -> SessionRecoveryOffer.Outcome {
        let asked = Task { @MainActor in
            await SessionRecoveryOffer.ask(found, showEmpty: showEmpty, persistenceEnabled: persistence,
                                           deferral: deferral, window: window, theme: nil)
        }
        if let button {
            while TerminalDialogView.pending(in: window) == nil { await Task.yield() }
            #expect(TerminalDialogView.pending(in: window)?.press(button) == true)
        }
        return await asked.value
    }

    @Test @MainActor func laterAtLaunchSilencesTheSameOfferButNotANewOne() async throws {
        let (deferral, cleanup) = try sandbox()
        defer { cleanup() }
        let window = window(), first = verified()
        #expect(await ask([first], deferral, in: window, press: "Later") == .declined)
        #expect(deferral.deferred == [SessionRecoveryDeferral.key(for: first)])

        // The next launch finds the same session: no question at all.
        #expect(await ask([first], deferral, in: window, press: nil) == .nothingNew)
        #expect(TerminalDialogView.pending(in: window) == nil)

        // A new generation of it is asked about again.
        let reborn = verified(first.id, generation: "b")
        #expect(await ask([reborn], deferral, in: window, press: "Restore") == .restore(verified: [reborn], adoptable: []))
        #expect(deferral.deferred == [SessionRecoveryDeferral.key(for: reborn)])
    }

    @Test @MainActor func theMenuCommandAlwaysAsksAndRecordsNothing() async throws {
        let (deferral, cleanup) = try sandbox()
        defer { cleanup() }
        let window = window(), found = verified()
        deferral.remember(offered: [found])
        #expect(await ask([found], deferral, in: window, showEmpty: true, press: "Later") == .declined)
        #expect(await ask([], deferral, in: window, showEmpty: true, press: "OK") == .declined)
        #expect(deferral.deferred == [SessionRecoveryDeferral.key(for: found)], "the menu changed what launch remembers")
    }

    @Test @MainActor func aQuestionThatCannotBeShownIsNotAnOffer() async throws {
        let (deferral, cleanup) = try sandbox()
        defer { cleanup() }
        let found = verified()
        #expect(await ask([found], deferral, in: window(drawable: false), press: nil) == .notShown)
        #expect(deferral.deferred.isEmpty)
        #expect(SessionRecoveryOffer.isDue([found], showEmpty: false, deferral: deferral), "it must be offered again")
    }

    @Test @MainActor func theDisabledPersistenceNoticeIsNotAnOffer() async throws {
        let (deferral, cleanup) = try sandbox()
        defer { cleanup() }
        #expect(await ask([verified()], deferral, in: window(), persistence: false, press: "OK") == .declined)
        #expect(deferral.deferred.isEmpty)
    }

    @Test @MainActor func anUnverifiableSessionIsAcknowledgedWithOK() async throws {
        let (deferral, cleanup) = try sandbox()
        defer { cleanup() }
        let unknown = SessionRecoveryInventory.Candidate(
            id: UUID(), runtimeID: "0.8.1-0000000000000000", identity: .unavailable, record: nil,
            observedInRuntime: true, observedGeneration: nil, processID: nil, executableName: nil)
        #expect(await ask([unknown], deferral, in: window(), press: "OK") == .declined)
        #expect(deferral.deferred == [SessionRecoveryDeferral.key(for: unknown)])
    }
}
