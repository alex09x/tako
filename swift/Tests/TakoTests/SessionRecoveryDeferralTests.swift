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

    // MARK: - present(): the launch and menu paths themselves

    /// Runs the real `present()` with private defaults, records and host
    /// window, pressing `button` if a question comes up. Returns whether one did.
    @MainActor
    private func present(_ found: [SessionRecoveryInventory.Candidate], _ deferral: SessionRecoveryDeferral,
                         in window: NSWindow?, showEmpty: Bool = false, persistence: Bool = true,
                         press button: String?) async throws -> Bool {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tako-rec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config.tako")
        try "session-persistence = \(persistence)\n".write(to: config, atomically: true, encoding: .utf8)
        let app = Tako.App(configPath: config.path)
        #expect(app.config.sessionPersistence == persistence)
        let running = Task { @MainActor in
            await SessionRecoveryPresentation.present(found, app: app, records: SessionRecordStore(directory: directory),
                                                      showEmpty: showEmpty, deferral: deferral, host: { window })
        }
        var asked = false
        if let button, let window {
            while TerminalDialogView.pending(in: window) == nil { await Task.yield() }
            asked = TerminalDialogView.pending(in: window)?.press(button) == true
        }
        await running.value
        return asked
    }

    @Test @MainActor func presentAsksOnceAtLaunchAndAgainForANewGenerationOrRuntime() async throws {
        let (deferral, cleanup) = try sandbox()
        defer { cleanup() }
        let window = window(), first = verified()
        #expect(try await present([first], deferral, in: window, press: "Later"))
        #expect(deferral.deferred == [SessionRecoveryDeferral.key(for: first)])

        // The same session on the next launch: present() returns without a question.
        #expect(try await present([first], deferral, in: window, press: nil) == false)
        #expect(TerminalDialogView.pending(in: window) == nil)

        // The same pane id in a new generation, then in another runtime.
        let reborn = verified(first.id, generation: "b")
        #expect(try await present([reborn], deferral, in: window, press: "Later"))
        let moved = SessionRecoveryInventory.Candidate(
            id: first.id, runtimeID: "0.8.1-1111111111111111", identity: .verified, record: reborn.record,
            observedInRuntime: true, observedGeneration: "b", processID: nil, executableName: nil)
        #expect(SessionRecoveryDeferral.key(for: moved) != SessionRecoveryDeferral.key(for: reborn))
        #expect(try await present([moved], deferral, in: window, press: "Later"))
        #expect(deferral.deferred == [SessionRecoveryDeferral.key(for: moved)])
    }

    @Test @MainActor func presentFromTheMenuReopensWhatLaunchAlreadyOffered() async throws {
        let (deferral, cleanup) = try sandbox()
        defer { cleanup() }
        let window = window(), found = verified()
        #expect(try await present([found], deferral, in: window, press: "Later"))
        #expect(try await present([found], deferral, in: window, showEmpty: true, press: "Later"))
        #expect(deferral.deferred == [SessionRecoveryDeferral.key(for: found)])
    }

    @Test @MainActor func presentWithoutADrawableHostRecordsNothing() async throws {
        let (deferral, cleanup) = try sandbox()
        defer { cleanup() }
        let found = verified()
        // No host window at all, then a window that cannot draw.
        #expect(try await present([found], deferral, in: nil, press: nil) == false)
        #expect(try await present([found], deferral, in: window(drawable: false), press: nil) == false)
        #expect(deferral.deferred.isEmpty)
        #expect(try await present([found], deferral, in: window(), press: "Later"), "it is still offered")
    }

    @Test @MainActor func presentWithPersistenceDisabledShowsItsNoticeAndRecordsNothing() async throws {
        let (deferral, cleanup) = try sandbox()
        defer { cleanup() }
        let window = window(), found = verified()
        #expect(try await present([found], deferral, in: window, persistence: false, press: "OK"))
        #expect(deferral.deferred.isEmpty)
        #expect(try await present([found], deferral, in: window, press: "Later"), "enabling it later still offers the session")
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
