/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

// MOTION_SCENE=switch: clicks on the other tab's sidebar row, recorded at
// the display's rate. The sidebar and the terminal beside it should go from
// the one tab to the other at once: a frame that looks like neither -- blank,
// stale, half drawn -- is a flicker the eye sees. Each side is judged against
// a still of that tab taken on its own once it has settled, never against a
// frame of the recording being judged.

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

/// How far a crop's pixels stray from their mean, 0...1: a blank crop is ~0.
func texture(_ a: Crop) -> Double {
    let p = [UInt8](a.bytes)
    var values: [Double] = []
    var i = 0
    while i + 3 < p.count { values.append(Double(Int(p[i]) + Int(p[i + 1]) + Int(p[i + 2])) / 765); i += 12 }
    guard !values.isEmpty else { return 0 }
    let mean = values.reduce(0, +) / Double(values.count)
    return values.reduce(0) { $0 + abs($1 - mean) } / Double(values.count)
}

/// Judges one region's recording of a switch from `before` to `after`, the
/// two settled stills: every frame must look like one of them, and the
/// recording must end on `after`.
func judgeSwitch(_ shots: [(ms: Double, crop: Crop)], before: Crop, after: Crop) -> (ok: Bool, detail: String) {
    guard !shots.isEmpty else { return (false, "no frames recorded") }
    let change = difference(before, after)
    let limit = max(0.01, change / 4)
    let odd = shots.filter { min(difference($0.crop, before), difference($0.crop, after)) > limit }
    let ended = difference(shots.last!.crop, after) <= limit
    let settled = shots.last { difference($0.crop, after) > limit }?.ms ?? 0
    let at = odd.prefix(6).map { String(format: "%.0f", $0.ms) }.joined(separator: ",")
    return (odd.isEmpty && ended,
            String(format: "change %.3f, %d frames like neither side%@, %@ at %.0f ms, %d frames",
                   change, odd.count, odd.isEmpty ? "" : " at " + at,
                   ended ? "settled" : "NEVER reached the tab's still, last change", settled, shots.count))
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

/// The title of the tab Tako says is selected, from `takoctl --json tree`.
func selectedTabTitle() -> String? {
    let p = Process(), out = Pipe()
    p.executableURL = URL(fileURLWithPath: takoctl)
    p.arguments = ["--bundle-id", bundleID, "--json", "tree"]
    p.standardOutput = out
    guard (try? p.run()) != nil else { return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let windows = (root["result"] as? [String: Any])?["windows"] as? [[String: Any]] else { return nil }
    for w in windows {
        for t in w["tabs"] as? [[String: Any]] ?? [] where t["selected"] as? Bool == true {
            if (w["tabs"] as? [[String: Any]])?.count ?? 0 > 1 { return t["title"] as? String }
        }
    }
    return nil
}

/// Switches between two tabs by their sidebar rows, four times, and judges every frame.
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
    guard let (window, sidebar, rows) = found else { check("switch", "setup", false, "no sidebar rows titled \(titles)"); finish() }
    let terminal = CGRect(x: sidebar.maxX + 1, y: sidebar.minY, width: window.maxX - sidebar.maxX - 1, height: window.maxY - sidebar.minY)
    let regions: [(String, CGRect)] = [("sidebar", sidebar), ("terminal", terminal)]
    print("sidebar \(sidebar.integral), terminal \(terminal.integral)")

    /// A settled still of what is shown now: the last of 0.3 s of frames.
    func still() async -> [String: Crop] {
        let frames = (try? await record(bundleID: bundleID, area: window, regions: regions, seconds: 0.3) {}) ?? []
        return frames.last?.crops ?? [:]
    }

    guard var current = selectedTabTitle(), titles.contains(current) else {
        check("switch", "setup", false, "takoctl names no selected tab among \(titles)"); finish()
    }
    var stills: [String: [String: Crop]] = [current: await still()]
    for round in 0..<4 {
        let target = titles.first { $0 != current }!
        let row = rows[target]!
        var clicked = true
        let frames: [Frame]
        do {
            frames = try await record(bundleID: bundleID, area: window, regions: regions, seconds: 1.0) {
                clicked = click(CGPoint(x: row.midX, y: row.midY), pid: pid)
            }
        } catch { check("switch", "capture", false, "\(error)"); finish() }
        guard clicked else { check("switch", target, false, "the window under the row is not Tako's"); finish() }
        try? await Task.sleep(nanoseconds: 500_000_000)
        let selected = selectedTabTitle()
        check("switch", "select", selected == target, "round \(round): asked for \(target), takoctl says \(selected ?? "nothing") is selected")
        let after = await still()
        if let framesDir { dump(frames, scene: "switch\(round)-\(target)", to: framesDir) }
        let before = stills[current] ?? [:]
        for (name, _) in regions {
            guard let b = before[name], let a = after[name] else {
                check("switch", name, false, "round \(round): no still of \(before[name] == nil ? current : target)"); continue
            }
            // Two tabs that print different things must not look alike, nor blank.
            if name == "terminal" {
                check("switch", "stills", difference(b, a) > 0.02 && texture(b) > 0.01 && texture(a) > 0.01,
                      String(format: "round %d: %@ vs %@ differ by %.3f, texture %.3f / %.3f",
                             round, current, target, difference(b, a), texture(b), texture(a)))
            }
            // A tab seen before must come back as it was.
            if let earlier = stills[target]?[name] {
                check("switch", "same", difference(earlier, a) <= 0.01,
                      String(format: "round %d: %@ %@ differs from its earlier still by %.3f", round, target, name, difference(earlier, a)))
            }
            let shots = frames.compactMap { f in f.crops[name].map { (ms: f.ms, crop: $0) } }
            let verdict = judgeSwitch(shots, before: b, after: a)
            check("switch", name, verdict.ok, "round \(round) to \(target): \(verdict.detail)")
        }
        stills[target] = stills[target] ?? after
        current = target
    }
}

/// `motion-check --selftest-switch`: the judge on made-up crops, no screen needed.
func switchSelfTest() -> Never {
    func crop(_ f: (Int, Int) -> UInt8) -> Crop {
        var d = Data(count: 32 * 16 * 4)
        for y in 0..<16 { for x in 0..<32 { let v = f(x, y); let i = (y * 32 + x) * 4; d[i] = v; d[i + 1] = v; d[i + 2] = v; d[i + 3] = 255 } }
        return Crop(width: 32, height: 16, scale: 1, bytes: d)
    }
    let a = crop { x, _ in x % 4 < 2 ? 230 : 20 }, b = crop { _, y in y % 4 < 2 ? 230 : 20 }, blank = crop { _, _ in 0 }
    func shots(_ c: [Crop]) -> [(ms: Double, crop: Crop)] { c.enumerated().map { (Double($0.offset) * 8, $0.element) } }
    let cases: [(String, Bool, Bool)] = [
        ("a clean switch passes", judgeSwitch(shots([a, a, b, b]), before: a, after: b).ok, true),
        ("an empty recording fails", judgeSwitch([], before: a, after: b).ok, false),
        ("a blank frame between fails", judgeSwitch(shots([a, blank, b]), before: a, after: b).ok, false),
        ("a click that changed nothing fails", judgeSwitch(shots([a, a, a]), before: a, after: b).ok, false),
        ("a blank still has no texture", texture(blank) > 0.01, false),
        ("a printed still has texture", texture(a) > 0.01, true),
        ("two tabs' stills differ", difference(a, b) > 0.02, true),
    ]
    var bad = 0
    for (name, got, want) in cases {
        print("\(got == want ? "ok  " : "FAIL") \(name)")
        if got != want { bad += 1 }
    }
    exit(bad == 0 ? 0 : 1)
}
