/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import SwiftUI
import UIKit
import XCTest
@testable import TakoCore

@MainActor
final class SessionPresentationTests: XCTestCase {
    func testConnectionTransitionsUpdateStatusTextAndDot() {
        let session = makeSession(status: .connecting)
        XCTAssertEqual(session.status.label, "connecting")
        assertColor(session.statusColor, rgb: 0xFF7A3D)

        session.transportConnected()
        XCTAssertEqual(session.status.label, "connected")
        assertColor(session.statusColor, rgb: 0x7BD88F)

        session.transportClosed("")
        XCTAssertEqual(session.status.label, "disconnected · closed")
        assertColor(session.statusColor, rgb: 0x8A7F76)

        session.status = .connecting
        XCTAssertEqual(session.status.label, "connecting")
        assertColor(session.statusColor, rgb: 0xFF7A3D)
    }

    func testDisconnectedStatusShowsTheActualReasonWithAMutedConnectionDot() {
        let session = makeSession(status: .connected)
        session.transportClosed("network lost · retry in 5s")

        XCTAssertEqual(session.status.label, "disconnected · network lost · retry in 5s")
        assertColor(session.statusColor, rgb: 0x8A7F76)
        // The transport error is red on the agent indicator, while the
        // connection indicator says this session is no longer live.
        assertColor(session.crab.color, rgb: 0xD54E53)
    }

    func testAgentSuccessAndFailureDoNotDetermineConnectionPresentation() {
        let session = makeSession(status: .connected)
        for (exitCode, rgb) in [(Int32(0), 0x7BD88F), (Int32(7), 0xD54E53)] {
            session.status = .connected
            session.commandDidStart()
            session.commandDidEnd(exitCode: exitCode)
            assertColor(session.crab.color, rgb: rgb)
            XCTAssertEqual(session.status.label, "connected")
            assertColor(session.statusColor, rgb: 0x7BD88F)

            // A saved/disconnected session can retain its last outcome.
            session.status = .disconnected(since: "saved")
            XCTAssertEqual(session.status.label, "disconnected · saved")
            assertColor(session.statusColor, rgb: 0x8A7F76)
            assertColor(session.crab.color, rgb: rgb)
        }
    }

    func testRunningAndAttentionUseEmberWhileConnectingUsesClaw() {
        let session = makeSession(status: .connecting)
        session.commandDidStart()
        assertColor(session.crab.color, rgb: 0xF4581C)
        assertColor(session.statusColor, rgb: 0xFF7A3D)

        session.handleBell()
        assertColor(session.crab.color, rgb: 0xF4581C)
        XCTAssertEqual(session.status.label, "connecting")
        assertColor(session.statusColor, rgb: 0xFF7A3D)
    }

    func testIdleAndGhostAgentIndicatorsAreMutedEvenWhenConnected() {
        let session = makeSession(status: .connected)
        assertColor(session.crab.color, rgb: 0x8A7F76)
        assertColor(CrabState.ghost.color, rgb: 0x8A7F76)
        assertColor(session.statusColor, rgb: 0x7BD88F)
    }

    private func makeSession(status: Session.Status) -> Session {
        Session(kind: .local, title: "Presentation", subtitle: "demo", status: status)
    }

    /// Compare displayed RGBA components, rather than Color identity or the
    /// same Brand constant used by the implementation. Both appearances
    /// should preserve these fixed semantic colors.
    private func assertColor(
        _ color: Color, rgb: Int, file: StaticString = #filePath, line: UInt = #line
    ) {
        for style in [UIUserInterfaceStyle.light, .dark] {
            let resolved = UIColor(color).resolvedColor(
                with: UITraitCollection(userInterfaceStyle: style))
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0
            guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
                XCTFail("Presentation color must resolve to RGB", file: file, line: line)
                return
            }
            XCTAssertEqual(red, CGFloat((rgb >> 16) & 0xFF) / 255,
                           accuracy: 0.0001, file: file, line: line)
            XCTAssertEqual(green, CGFloat((rgb >> 8) & 0xFF) / 255,
                           accuracy: 0.0001, file: file, line: line)
            XCTAssertEqual(blue, CGFloat(rgb & 0xFF) / 255,
                           accuracy: 0.0001, file: file, line: line)
            XCTAssertEqual(alpha, 1, accuracy: 0.0001, file: file, line: line)
        }
    }
}
