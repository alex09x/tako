/*
 * tako — Desktop settings building block layout tests
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import SwiftUI
import Testing
@testable import Tako

@MainActor
struct DesktopSettingsStyleTests {
    private let options: [(value: String, label: String)] =
        [("true", "When Running"), ("always", "Always"), ("false", "Never")]

    private func textWidth(_ label: String) -> CGFloat {
        (label as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: DesktopMetrics.bodyFontSize)]).width
    }

    /// Reference A02: segments are as wide as their labels («если идёт
    /// команда» wider than «всегда»), with 10 pt padding, never equal shares.
    @Test func segmentsTakeTheirLabelsWidth() {
        let segment = DesktopSegment(options: options, selection: "true", identifier: "S",
                                     palette: .dark) { _ in }
        let natural = NSHostingView(rootView: segment).fittingSize.width
        let labels = options.map { textWidth($0.label) + 20 }.reduce(0, +)
        #expect(natural >= labels, "segment \(natural) < labels \(labels)")
        // Even offered less room, a fixed-size segment reports its full width.
        let offered = NSHostingView(rootView: segment.frame(width: 150, alignment: .leading)).fittingSize.width
        #expect(offered == 150)
        #expect(NSHostingView(rootView: HStack(spacing: 0) { Color.clear.frame(width: 1); segment }).fittingSize.width >= labels)
    }
}
