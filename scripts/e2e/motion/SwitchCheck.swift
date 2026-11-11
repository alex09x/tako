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

/// Each pixel's brightness, 0...1.
func luma(_ c: Crop) -> [Double] {
    let p = [UInt8](c.bytes)
    var out = [Double](repeating: 0, count: c.width * c.height)
    for k in out.indices { out[k] = Double(Int(p[k * 4]) + Int(p[k * 4 + 1]) + Int(p[k * 4 + 2])) / 765 }
    return out
}

/// A settled still and its ink: the pixels that stand out from its
/// background (its median brightness), where the text and the chrome are.
/// A mean over the whole crop misses a sparse page going blank -- `seq`'s
/// column is a percent of a terminal -- the ink does not.
struct Reference {
    let crop: Crop
    let background: Double
    let ink: [Bool]
    let inkCount: Int

    init(_ crop: Crop) {
        self.crop = crop
        let l = luma(crop)
        let bg = l.isEmpty ? 0 : l.sorted()[l.count / 2]
        let mask = l.map { abs($0 - bg) > 0.2 }
        background = bg
        ink = mask
        inkCount = mask.lazy.filter { $0 }.count
    }

    /// Ink as a share of the crop: a blank still has none.
    var inkShare: Double { ink.isEmpty ? 0 : Double(inkCount) / Double(ink.count) }

    /// The share of this still's ink a frame gets wrong, against this
    /// still's background: ink missing plus ink added, over the ink there is.
    func inkDistance(_ frame: Crop) -> Double {
        guard frame.width == crop.width, frame.height == crop.height, inkCount > 0 else { return .infinity }
        let l = luma(frame)
        var wrong = 0
        for k in l.indices where (abs(l[k] - background) > 0.2) != ink[k] { wrong += 1 }
        return Double(wrong) / Double(inkCount)
    }

    /// Whether a frame shows this still: close overall and the same ink, up
    /// to a blinking cursor and anti-aliasing.
    func matches(_ frame: Crop, limit: Double) -> Bool {
        difference(frame, crop) <= limit && inkDistance(frame) <= 0.25
    }
}

/// Judges one region's recording of a switch from `before` to `after`, the
/// two settled stills: every frame must look like one of them, and the
/// recording must end on `after`. It must also cover the click: a frame
/// from before it (ms <= 0) showing `before`, and frames after it -- a
/// recording that starts late could miss the very flash it looks for.
func judgeSwitch(_ shots: [(ms: Double, crop: Crop)], before: Crop, after: Crop) -> (ok: Bool, detail: String) {
    guard !shots.isEmpty else { return (false, "no frames recorded") }
    let change = difference(before, after)
    let limit = max(0.01, change / 4)
    let from = Reference(before), to = Reference(after)
    guard from.inkCount > 0, to.inkCount > 0 else { return (false, "a still has no ink to judge by") }
    guard shots.contains(where: { $0.ms <= 0 && from.matches($0.crop, limit: limit) }) else {
        return (false, "no frame from before the click showing the tab before: the recording does not cover the click")
    }
    guard shots.contains(where: { $0.ms > 0 }) else { return (false, "no frame after the click") }
    let odd = shots.filter { !from.matches($0.crop, limit: limit) && !to.matches($0.crop, limit: limit) }
    let ended = to.matches(shots.last!.crop, limit: limit)
    let settled = shots.last { !to.matches($0.crop, limit: limit) }?.ms ?? 0
    let at = odd.prefix(6).map { String(format: "%.0f", $0.ms) }.joined(separator: ",")
    return (odd.isEmpty && ended,
            String(format: "change %.3f, %d frames like neither side%@, %@ at %.0f ms, %d frames from %.0f to %.0f ms, %d before the click, largest gap %.0f ms",
                   change, odd.count, odd.isEmpty ? "" : " at " + at,
                   ended ? "settled" : "NEVER reached the tab's still, last change", settled, shots.count,
                   shots.first!.ms, shots.last!.ms, shots.filter { $0.ms <= 0 }.count,
                   zip(shots, shots.dropFirst()).map { $1.ms - $0.ms }.max() ?? 0))
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
                let rb = Reference(b), ra = Reference(a)
                check("switch", "stills", rb.inkShare > 0.002 && ra.inkShare > 0.002 && rb.inkDistance(a) > 0.5,
                      String(format: "round %d: ink %.4f / %.4f of the crop, %@'s ink %.2f wrong in %@",
                             round, rb.inkShare, ra.inkShare, current, rb.inkDistance(a), target))
            }
            // A tab seen before must come back as it was.
            if let earlier = stills[target]?[name] {
                let r = Reference(earlier)
                check("switch", "same", r.matches(a, limit: 0.01),
                      String(format: "round %d: %@ %@ against its earlier still: mean %.3f, ink %.2f wrong",
                             round, target, name, difference(earlier, a), r.inkDistance(a)))
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
    let w = 200, h = 100
    func crop(_ f: (Int, Int) -> UInt8) -> Crop {
        var d = Data(count: w * h * 4)
        for y in 0..<h { for x in 0..<w { let v = f(x, y); let i = (y * w + x) * 4; d[i] = v; d[i + 1] = v; d[i + 2] = v; d[i + 3] = 255 } }
        return Crop(width: w, height: h, scale: 1, bytes: d)
    }
    /// White on the terminal's dark background at `permille` of the pixels, scattered.
    func page(_ permille: Int, seed: Int) -> Crop {
        crop { x, y in (((x &* 73_856_093) ^ (y &* 19_349_663) ^ seed) & 0x7fff_ffff) % 1000 < permille ? 235 : 20 }
    }
    let dense = page(200, seed: 1), sparse = page(5, seed: 2), background = crop { _, _ in 20 }, grey = crop { _, _ in 120 }
    // The sparse page with a 2x2 cursor more: a blink, not a different page.
    let blinked = crop { x, y in (x == 10 || x == 11) && (y == 10 || y == 11) ? 235 : [UInt8](sparse.bytes)[(y * w + x) * 4] }
    // The first frame is grabbed before the click, as a real recording's is.
    func shots(_ c: [Crop]) -> [(ms: Double, crop: Crop)] { c.enumerated().map { (Double($0.offset - 1) * 8, $0.element) } }
    func late(_ c: [Crop]) -> [(ms: Double, crop: Crop)] { c.enumerated().map { (Double($0.offset + 1) * 8, $0.element) } }
    let blankBetween = judgeSwitch(shots([dense, background, sparse]), before: dense, after: sparse)
    let cases: [(String, Bool, Bool)] = [
        ("a clean switch passes", judgeSwitch(shots([dense, dense, sparse, sparse]), before: dense, after: sparse).ok, true),
        ("a cursor blink on the page switched to passes", judgeSwitch(shots([dense, sparse, blinked]), before: dense, after: sparse).ok, true),
        ("an empty recording fails", judgeSwitch([], before: dense, after: sparse).ok, false),
        ("a recording that starts after the click fails",
         judgeSwitch(late([sparse, sparse, sparse]), before: dense, after: sparse).ok, false),
        ("a recording that ends at the click fails",
         judgeSwitch([(-16, dense), (0, dense)], before: dense, after: sparse).ok, false),
        ("a background-only frame before a sparse page fails", blankBetween.ok, false),
        ("a background-only frame after a sparse page fails",
         judgeSwitch(shots([sparse, background, dense]), before: sparse, after: dense).ok, false),
        ("a solid grey frame between fails", judgeSwitch(shots([dense, grey, sparse]), before: dense, after: sparse).ok, false),
        ("a click that changed nothing fails", judgeSwitch(shots([dense, dense, dense]), before: dense, after: sparse).ok, false),
        ("a blank still has no ink", Reference(background).inkShare > 0.002, false),
        ("a sparse page has ink", Reference(sparse).inkShare > 0.002, true),
        ("two tabs' stills differ in ink", Reference(dense).inkDistance(sparse) > 0.5, true),
    ]
    print(String(format: "sparse page: mean difference from background %.4f (the old judge's blind spot)", difference(background, sparse)))
    var bad = 0
    for (name, got, want) in cases {
        print("\(got == want ? "ok  " : "FAIL") \(name)")
        if got != want { bad += 1 }
    }
    exit(bad == 0 ? 0 : 1)
}
