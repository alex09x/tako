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

/// What the window draws, as the pixels' brightness: the accessibility tree
/// stays empty in a unit-test host, so the tests read the picture.
@MainActor
func shownPixels(_ view: UIView) -> [UInt8] {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
        view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
    }
    guard let cg = image.cgImage, let data = cg.dataProvider?.data else { return [] }
    return Array(CFDataGetBytePtr(data).map { UnsafeBufferPointer(start: $0, count: CFDataGetLength(data)) } ?? UnsafeBufferPointer(start: nil, count: 0))
}

func totalLight(_ pixels: [UInt8]) -> Int { pixels.reduce(0) { $0 + Int($1) } }

/// The host-key prompt shows Trust and Cancel as dead labels for one second:
/// tapping Connect must never carry into the decision it opens. After that
/// they are real buttons.
@MainActor
final class HostKeyPromptArmingTests: XCTestCase {
    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    func testTrustAndCancelAreDimLabelsForASecondThenFullButtons() {
        let prompt = HostKeyPrompt(
            host: "example.test",
            presented: .init(algorithm: "ssh-ed25519", fingerprint: "SHA256:abc", changed: false),
            onTrust: {}, onCancel: {})
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let host = UIHostingController(rootView: prompt)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        spin(0.25)
        let early = totalLight(shownPixels(host.view))
        spin(0.55)
        let stillEarly = totalLight(shownPixels(host.view))
        XCTAssertEqual(early, stillEarly, "the prompt changed before its second was up (at 0.8 s)")
        // 1.4 s in: the second is up with room for a slow runner, and far from
        // any longer delay a mutation might put there.
        spin(0.6)
        let armed = totalLight(shownPixels(host.view))
        XCTAssertGreaterThan(armed, early + 20_000, "the buttons look the same after a second: \(early) vs \(armed)")
    }
}

private struct Plain: View {
    var body: some View { HStack { Text("connecting…") } }
}

/// The two spinners and the delay before the host-key prompt mounts.
@MainActor
final class ConnectingSpinnerTests: XCTestCase {
    private func shown<V: View>(_ view: V) -> (UIWindow, UIHostingController<V>) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let host = UIHostingController(rootView: view)
        window.rootViewController = host
        window.makeKeyAndVisible()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        return (window, host)
    }

    /// SwiftUI draws a ProgressView into the view's own display list: no UIKit
    /// spinner or layer exists to find, so the view tree's type names are read.
    private func containsSpinner<V: View>(_ view: V) -> Bool {
        String(describing: type(of: view.body)).contains("ProgressView")
    }

    func testTheTerminalsConnectingStripHasASpinner() {
        XCTAssertTrue(containsSpinner(ConnectingNotice()), "\(type(of: ConnectingNotice().body))")
    }

    func testTheHostKeyLookHasASpinner() {
        XCTAssertTrue(containsSpinner(CheckingOverlay(host: "example.test")), "\(type(of: CheckingOverlay(host: "x").body))")
    }

    func testAPlainViewHasNoSpinner() {
        XCTAssertFalse(containsSpinner(Plain()))
    }

    func testAFoundHostKeyWaitsThreeQuartersOfASecondBeforeItsPromptMounts() {
        XCTAssertEqual(SessionListScreen.hostKeyMountDelay, 750_000_000)
    }
}

/// The form scrolls to the passphrase when a key is pasted.
@MainActor
final class PassphraseRevealTests: XCTestCase {
    func testAPastedKeyRevealsThePassphraseAndAClearedOneDoesNot() {
        XCTAssertTrue(SshFormScreen.revealsPassphrase(wasEmpty: true, isEmpty: false))
        XCTAssertFalse(SshFormScreen.revealsPassphrase(wasEmpty: false, isEmpty: true))
        XCTAssertFalse(SshFormScreen.revealsPassphrase(wasEmpty: false, isEmpty: false))
        XCTAssertFalse(SshFormScreen.revealsPassphrase(wasEmpty: true, isEmpty: true))
    }

    func testTheRevealEasesOutOverTwoTenthsOfASecond() {
        XCTAssertEqual(SshFormScreen.revealAnimation, Animation.easeOut(duration: 0.2))
    }
}
