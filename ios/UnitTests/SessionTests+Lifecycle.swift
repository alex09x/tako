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
import XCTest
import UIKit
@testable import TakoCore

@MainActor
extension SessionTests {
    // MARK: - needsCredentials / draft

    func testNeedsCredentialsFalseForLocal() {
        XCTAssertFalse(makeLocal().needsCredentials)
    }

    func testNeedsCredentialsTrueWhenNothingToAuthenticateWith() {
        XCTAssertTrue(makeSsh().needsCredentials)
    }

    func testNeedsCredentialsFalseWithKey() {
        XCTAssertFalse(makeSsh(privateKeyPEM: "pem").needsCredentials)
    }

    func testNeedsCredentialsFalseWithPassword() {
        XCTAssertFalse(makeSsh(password: "pw").needsCredentials)
    }

    func testDraftNilForLocal() {
        XCTAssertNil(makeLocal().draft)
    }

    func testDraftRoundTripsHostPortUsername() {
        let session = makeSsh()
        let draft = session.draft
        XCTAssertEqual(draft?.host, "example.com")
        XCTAssertEqual(draft?.port, "2222")
        XCTAssertEqual(draft?.username, "alex")
    }

    // MARK: - receive without a mounted surface

    func testReceiveWithoutSurfaceUpdatesTitle() {
        let session = makeLocal()
        session.receive(Data("\u{1b}]0;My Title\u{07}".utf8))
        XCTAssertEqual(session.title, "My Title")
    }

    func testReceiveWithoutSurfaceTracksCommandLifecycleSuccess() {
        let session = makeLocal()
        session.receive(Data("\u{1b}]133;C\u{07}".utf8))
        XCTAssertEqual(session.crab, .running)
        session.receive(Data("\u{1b}]133;D;0\u{07}".utf8))
        XCTAssertEqual(session.crab, .succeeded)
    }

    func testReceiveWithoutSurfaceTracksCommandLifecycleFailure() {
        let session = makeLocal()
        session.receive(Data("\u{1b}]133;C\u{07}".utf8))
        session.receive(Data("\u{1b}]133;D;7\u{07}".utf8))
        XCTAssertEqual(session.crab, .failed)
    }

    func testReceiveWithoutSurfaceCommandEndWithNoCodeCountsAsSuccess() {
        let session = makeLocal()
        session.receive(Data("\u{1b}]133;C\u{07}".utf8))
        session.receive(Data("\u{1b}]133;D\u{07}".utf8))
        XCTAssertEqual(session.crab, .succeeded)
    }

    func testReceiveWithoutSurfaceBellSetsAttention() {
        let session = makeLocal()
        session.receive(Data([0x07]))
        XCTAssertEqual(session.crab, .attention)
    }

    func testReceiveWithoutSurfaceRoutesDeviceRepliesWithoutCrashing() {
        let session = makeLocal()
        // A cursor-position query makes the engine produce reply bytes;
        // with no ssh transport attached this is a no-op send, but the
        // "route the reply back" branch still runs.
        session.receive(Data("\u{1b}[6n".utf8))
    }

    func testReceiveWithoutSurfaceSetsLastReceivedAt() {
        let session = makeLocal()
        XCTAssertNil(session.lastReceivedAt)
        session.receive(Data("hi".utf8))
        XCTAssertNotNil(session.lastReceivedAt)
    }

    // MARK: - receive with a mounted surface

    func testReceiveWithSurfaceRoutesTitleThroughTheDelegate() async {
        let session = makeLocal()
        _ = MountedSurface(session: session)
        session.receive(Data("\u{1b}]0;Mounted Title\u{07}".utf8))
        let updated = await pollUntil { session.title == "Mounted Title" }
        XCTAssertTrue(updated)
    }

    func testReceiveWithSurfaceRoutesCommandLifecycleThroughTheDelegate() async {
        let session = makeLocal()
        _ = MountedSurface(session: session)
        session.receive(Data("\u{1b}]133;C\u{07}".utf8))
        let running = await pollUntil { session.crab == .running }
        XCTAssertTrue(running)
        session.receive(Data("\u{1b}]133;D;0\u{07}".utf8))
        let succeeded = await pollUntil { session.crab == .succeeded }
        XCTAssertTrue(succeeded)
    }


}
