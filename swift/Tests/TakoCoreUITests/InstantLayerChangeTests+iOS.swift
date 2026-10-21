/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

#if canImport(UIKit)
import UIKit
import XCTest
@testable import TakoCoreUI

/// The phone's terminal takes a new size at once: its Metal layer is not
/// left easing a quarter second behind the view.
final class InstantLayerChangeTestsIOS: XCTestCase {
    @MainActor
    func testThePhonesMetalLayerTakesANewSizeAtOnce() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        let view = TakoTerminalView(frame: window.bounds)
        window.addSubview(view)
        window.isHidden = false
        view.layoutIfNeeded()
        CATransaction.flush()
        guard let metal = view.metalLayer else { throw XCTSkip("no Metal layer on this simulator") }
        // The check itself sees an implicit animation where there is one.
        let plain = CALayer()
        view.layer.addSublayer(plain)
        CATransaction.flush()
        plain.opacity = 0.3
        CATransaction.flush()
        XCTAssertNotNil(plain.animation(forKey: "opacity"), "the check is blind")
        plain.removeFromSuperlayer()
        view.frame = CGRect(x: 0, y: 0, width: 320, height: 480)
        view.applyMetalLayerGeometry()
        CATransaction.flush()
        XCTAssertEqual(metal.frame, view.bounds)
        XCTAssertNil(metal.animationKeys(), "the Metal layer animated to its new size")
    }
}
#endif
