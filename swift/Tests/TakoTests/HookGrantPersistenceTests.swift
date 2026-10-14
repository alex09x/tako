/*
 * tako — Lifecycle grant persistence validation
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Testing
@testable import Tako

struct HookGrantPersistenceTests {
    private func data(_ changes: [String: Any] = [:]) throws -> Data {
        var record: [String: Any] = ["bundle_id": "fixture.tako", "scopes": ["signal"],
            "surface": "11111111-1111-4111-8111-111111111111", "token": String(repeating: "a", count: 64)]
        record.merge(changes) { _, new in new }
        return try JSONSerialization.data(withJSONObject: record)
    }

    @Test func restoresOnlySignalGrantForMatchingBundle() throws {
        let grant = try #require(HookGrantPersistence.decode(data(), bundleID: "fixture.tako"))
        #expect(grant.scopes == [.signal])
        #expect(grant.client == "tako-hook-11111111-1111-4111-8111-111111111111")
        #expect(HookGrantPersistence.decode(try data(), bundleID: "other.tako") == nil)
    }

    @Test func refusesExpandedScopesAndInvalidIdentity() throws {
        for change: [String: Any] in [["scopes": ["signal", "input"]], ["surface": "bad"], ["token": "bad"]] {
            #expect(HookGrantPersistence.decode(try data(change), bundleID: "fixture.tako") == nil)
        }
    }

    @Test func testHarnessNeverReadsRealKeychain() {
        #expect(HookGrantPersistence.enabled == false)
        #expect(HookGrantPersistence.records().isEmpty)
    }

    @Test func newGrantScopesDoNotAttenuateIssuer() throws {
        let request = try ControlRequest.parse(Data(#"{"cmd":"grant","args":{"subcommand":"create","scopes":["signal"]}}"#.utf8))
        #expect(request.requestedScopes == nil)
        #expect(request.args["scopes"] == .array([.string("signal")]))
        let attenuated = try ControlRequest.parse(Data(#"{"cmd":"status","args":{"scopes":["read"]}}"#.utf8))
        #expect(attenuated.requestedScopes == [.read])
        let listing = try ControlRequest.parse(Data(#"{"cmd":"grant","args":{"subcommand":"list","scopes":["read"]}}"#.utf8))
        #expect(listing.requestedScopes == [.read])
    }
}
