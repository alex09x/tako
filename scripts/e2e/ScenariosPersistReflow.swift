/*
 * tako — Persistent terminal reflow through real window resizing
 * Copyright (c) 2026 Alexander Panasenko
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Foundation

func runPersistReflowScenario(_ d: Driver) throws {
    d.quit()
    let config = "session-persistence = true\nremote-control = on\n"
    try d.launch(config: config)
    d.setPosition(CGPoint(x: 20, y: 50))
    // Hosted displays can clamp a requested 1250 pt window to 90 columns.
    // Measure both real widths before choosing content that must wrap in one
    // and fit completely in the other; a fixed 115-column marker cannot.
    d.setSize(CGSize(width: 1250, height: 700))
    d.focus()
    usleep(1_000_000)
    try d.run("tput cols > \(d.path("cols_available"))")
    let available = Int(try d.file("cols_available").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    d.setSize(CGSize(width: 650, height: 500))
    d.focus()
    usleep(1_000_000)
    try d.run("tput cols > \(d.path("cols_narrow"))")
    let narrow = Int(try d.file("cols_narrow").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    guard narrow > 0, available > narrow + 1 else {
        throw Failure("distinct grid widths required: narrow \(narrow), available \(available)")
    }
    let markerLength = narrow + (available - narrow) / 2
    let seed = Array(("REFLOW_" + UUID().uuidString).utf8)
    let expectedMarker = String(bytes: (0..<markerLength).map { seed[$0 % seed.count] }, encoding: .utf8)!
    // The marker itself is never typed into the command echo.
    let encoded = Data(expectedMarker.utf8).base64EncodedString()
    try d.run("python3 -c \"import base64, sys; sys.stdout.write(base64.b64decode('\(encoded)').decode('utf-8') + '\\n')\"")
    usleep(1_000_000)

    func q(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    let ctl = "\(q(d.appURL.path + "/Contents/MacOS/takoctl")) --bundle-id \(q(d.bundleID))"
    // Capture from outside the pane; typing a capture command inside it
    // would replace the physical rows under test with that command's echo.
    func rows() throws -> [String] {
        try d.exec("\(ctl) text --styled --lines 50").components(separatedBy: "\n").map {
            $0.replacingOccurrences(of: "\u{1b}\\[[0-9;]*[a-zA-Z]", with: "", options: .regularExpression)
                .trimmingCharacters(in: .newlines)
        }
    }
    let narrowRows = try rows()
    guard wrappedMarkerStart(expectedMarker, in: narrowRows, cols: narrow) != nil else {
        throw Failure("marker did not fill its physical wrapped rows at \(narrow) columns: \(narrowRows)")
    }
    try d.quitNormally()
    try d.launch(config: config)
    d.setPosition(CGPoint(x: 20, y: 50))
    d.setSize(CGSize(width: 1250, height: 700))
    d.focus()
    usleep(1_500_000)
    try d.run("tput cols > \(d.path("cols_wide"))")
    let wide = Int(try d.file("cols_wide").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    guard wide > narrow, wide >= expectedMarker.count else {
        throw Failure("columns did not widen enough for the \(markerLength)-character marker: was \(narrow), now \(wide), preflight \(available)")
    }
    let wideRows = try rows()
    guard wideRows.contains(where: { $0.contains(expectedMarker) }) else {
        throw Failure("restored marker did not unwrap into one physical row at \(wide) columns: \(wideRows)")
    }
    print("reflow: narrow \(narrow), wide \(wide), marker \(markerLength); physical wrap and unwrap proven")
    try d.run("exit")
}
