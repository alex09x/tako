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
}
