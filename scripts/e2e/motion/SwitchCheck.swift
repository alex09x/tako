/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

// MOTION_SCENE=switch: a click on another tab's sidebar row, recorded at the
// display's rate. The sidebar and the terminal beside it should go from the
// one tab to the other at once: a frame that looks like neither -- blank,
// stale, half drawn -- is a flicker the eye sees.

import AppKit

/// Mean per-channel difference of two crops, 0...1, every 3rd pixel.
func difference(_ a: Crop, _ b: Crop) -> Double {
    guard a.width == b.width, a.height == b.height else { return 1 }
    let pa = [UInt8](a.bytes), pb = [UInt8](b.bytes)
    var sum = 0, n = 0, i = 0
    while i + 3 < pa.count {
        for c in 0..<3 {
            let d = Int(pa[i + c]) - Int(pb[i + c])
            sum += d < 0 ? -d : d
        }
        n += 3
        i += 12
    }
    return n == 0 ? 0 : Double(sum) / Double(n) / 255
}

/// A real click at `point` (global top-left points) through the HID tap,
/// only when the window there is the app's; the cursor goes back after.
func click(_ point: CGPoint, pid: pid_t) -> Bool {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    let top = list.first { w in
        guard let b = w[kCGWindowBounds as String] as? [String: Double], (w[kCGWindowLayer as String] as? Int) ?? 1 < 20 else { return false }
        return CGRect(x: b["X"]!, y: b["Y"]!, width: b["Width"]!, height: b["Height"]!).contains(point)
    }
    guard (top?[kCGWindowOwnerPID as String] as? pid_t) == pid else { return false }
    let back = CGEvent(source: nil)?.location ?? point
    for type in [CGEventType.leftMouseDown, .leftMouseUp] {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(30_000)
    }
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: back, mouseButton: .left)?.post(tap: .cghidEventTap)
    return true
}

/// Switches between two tabs by their sidebar rows and judges every frame.
func switchCheck(pid: pid_t, titles: [String], framesDir: String?) async {
    var found: (window: CGRect, sidebar: CGRect, rows: [String: CGRect])?
    for _ in 0..<20 {
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard let window = mainWindow(pid: pid),
              let sidebar = accessibilityFrames(pid: pid, role: "AXScrollArea").first(where: { abs($0.minX - window.minX) < 1 })
        else { continue }
        var rows: [String: CGRect] = [:]
        for t in titles {
            rows[t] = accessibilityFrames(pid: pid, role: "AXStaticText", { $0 == t }).first { sidebar.contains(CGPoint(x: $0.midX, y: $0.midY)) }
        }
        if rows.count == titles.count { found = (window, sidebar, rows); break }
    }
    guard let (window, sidebar, rows) = found else { print("no sidebar rows titled \(titles)"); exit(1) }
    let terminal = CGRect(x: sidebar.maxX + 1, y: sidebar.minY, width: window.maxX - sidebar.maxX - 1, height: window.maxY - sidebar.minY)
    let regions: [(String, CGRect)] = [("sidebar", sidebar), ("terminal", terminal)]
    print("sidebar \(sidebar.integral), terminal \(terminal.integral)")

    for round in 0..<4 {
        let title = titles[round % titles.count]
        let row = rows[title]!
        let frames: [Frame]
        var clicked = true
        do {
            frames = try await record(bundleID: bundleID, area: window, regions: regions, seconds: 1.0) {
                clicked = click(CGPoint(x: row.midX, y: row.midY), pid: pid)
            }
        } catch { print("capture failed: \(error)"); exit(1) }
        guard clicked else { check("switch", title, false, "the window under the row is not Tako's"); continue }
        if let framesDir { dump(frames, scene: "switch\(round)-\(title)", to: framesDir) }
        for (name, _) in regions {
            let shots = frames.compactMap { f in f.crops[name].map { (f.ms, $0) } }
            guard let first = shots.first?.1, let last = shots.last?.1 else { continue }
            let change = difference(first, last)
            // A frame looks like neither side when it is further from both
            // than a quarter of the change itself, and visibly so.
            let limit = max(0.01, change / 4)
            let odd = shots.filter { min(difference($0.1, first), difference($0.1, last)) > limit }
            let settled = shots.last { difference($0.1, last) > limit }?.0 ?? 0
            check("switch", "\(name)", odd.isEmpty,
                  String(format: "to %@: change %.3f, %d frames like neither side%@, settled at %.0f ms, %d frames",
                         title, change, odd.count,
                         odd.isEmpty ? "" : " at " + odd.prefix(6).map { String(format: "%.0f", $0.0) }.joined(separator: ","),
                         settled, shots.count))
        }
        try? await Task.sleep(nanoseconds: 400_000_000)
    }
}
