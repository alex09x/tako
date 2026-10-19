/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

// motion-check BUNDLE_ID TAKOCTL TAB_TITLE [FRAMES_DIR]  (built from scripts/e2e/motion/)
//
// Plays working, done, failed and waiting on one tab of a running Tako and
// records its pill and its sidebar row at the display's rate, then says for
// each whether it moved as the design has it and whether it ever stalled.
// Run through scripts/motion-check.sh, which starts a separate Tako for it.

import AppKit

setvbuf(stdout, nil, _IONBF, 0)
let args = CommandLine.arguments
guard args.count >= 4 else { print("usage: motion-check BUNDLE_ID TAKOCTL TAB_TITLE [FRAMES_DIR]"); exit(2) }
let bundleID = args[1], takoctl = args[2], title = args[3]

func ctl(_ arguments: String...) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: takoctl)
    p.arguments = ["--bundle-id", bundleID] + arguments
    p.standardOutput = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
}

func status(_ s: String, pane: String) { ctl("status", "set", s, "--target", pane) }

/// One line of the verdict.
struct Check {
    let scene: String, surface: String, ok: Bool, detail: String
}
var checks: [Check] = []
func check(_ scene: String, _ surface: String, _ ok: Bool, _ detail: String) {
    checks.append(Check(scene: scene, surface: surface, ok: ok, detail: detail))
    print(String(format: "%@  %-8@ %-5@ %@", ok ? "ok  " : "FAIL", scene as NSString, surface as NSString, detail))
}

/// A stall is a frame the eye misses: three at 60 Hz.
let stall = 50.0
/// One-off motions take every frame the display shows; allow a fifth less.
let displayFPS = Double(NSScreen.screens.map(\.maximumFramesPerSecond).max() ?? 60)

/// The whole check takes about fifteen seconds; a minute means something hangs.
DispatchQueue.global().asyncAfter(deadline: .now() + 60) {
    print("motion-check: gave up after 60 s"); exit(2)
}

// Off the main thread: the main thread only runs dispatchMain(), so nothing
// the check waits on can be stuck behind it.
Task {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
        print("no \(bundleID) running"); exit(1)
    }
    let pid = app.processIdentifier
    app.activate()

    // Where everything is, once the tab strip has stopped moving: a shell
    // starting renames the first tab and pushes the others along.
    var layout: (window: CGRect, pill: CGRect, label: CGRect, sidebar: CGRect)?
    for _ in 0..<20 {
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard let window = mainWindow(pid: pid),
              let pill = accessibilityFrames(pid: pid, role: "AXRadioButton", { $0 == title }).first,
              let label = accessibilityFrames(pid: pid, role: "AXStaticText", { $0 == title }).first(where: { $0.minX < window.minX + 400 }),
              // The sidebar's list: the scroll area along the window's left edge.
              let sidebar = accessibilityFrames(pid: pid, role: "AXScrollArea").first(where: { abs($0.minX - window.minX) < 1 })
        else { continue }
        if let l = layout, l.window == window, l.pill == pill, l.label == label { break }
        layout = (window, pill, label, sidebar)
    }
    guard let (window, pill, label, sidebar) = layout else {
        print("no tab or sidebar row titled \"\(title)\" -- is the sidebar open?"); exit(1)
    }
    let pane = ProcessInfo.processInfo.environment["MOTION_PANE"] ?? ""

    // A row's surface runs 8 pt in from the sidebar's edges; its ring centre
    // is 14 pt left of its title, a pill's 15.5 pt in from the pill's edge.
    let row = CGRect(x: sidebar.minX + 8, y: label.minY - 8, width: sidebar.width - 16, height: label.height + 16)
    let rowRing = CGPoint(x: label.minX - 14, y: label.midY)
    let pillRing = CGPoint(x: pill.minX + 15.5, y: pill.midY)
    func ringBox(_ c: CGPoint) -> CGRect { CGRect(x: c.x - 10, y: c.y - 9, width: 20, height: 18) }
    // Wide enough to keep the ring and the title when the strip moves: a
    // failed or waiting tab badges its workspace chip, which pushes every pill along.
    let tabLine = CGRect(x: pill.minX - 30, y: pillRing.y - 9, width: 180, height: 18)
    let regions: [(String, CGRect)] = [("tab", pill), ("row", row), ("tab-ring", ringBox(pillRing)), ("row-ring", ringBox(rowRing)),
                                       ("tab-line", tabLine)]
    print("tab \"\(title)\" at \(pill.integral), sidebar row at \(row.integral)")

    func run(_ scene: String, _ seconds: Double, _ action: @escaping () -> Void) async -> [Frame] {
        do {
            let frames = try await record(bundleID: bundleID, area: window, regions: regions, seconds: seconds, action: action)
            if args.count > 4 { dump(frames, scene: scene, to: args[4]) }
            return frames
        } catch {
            print("capture failed: \(error)"); exit(1)
        }
    }
    let centre = CGPoint(x: 10, y: 9)

    // Working: the spinner turns at 400°/s clockwise, every frame.
    status("idle", pane: pane)
    try? await Task.sleep(nanoseconds: 400_000_000)
    var frames = await run("working", 1.6) { status("working", pane: pane) }
    for (surface, ring) in [("tab", "tab-ring"), ("row", "row-ring")] {
        let c = cadence(frames, ring, in: 400...1600)
        let rate = spinRate(frames, ring, centre: centre, in: 400...1600)
        let ok = rate.map { abs($0 - 400) < 60 } ?? false
        check("working", surface, ok && c.longestGap <= stall,
              "spinner \(rate.map { String(format: "%.0f°/s", $0) } ?? "not found") (design 400°/s clockwise), \(c)")
    }

    // Done: the ring pops and the glint crosses the surface left to right --
    // with another tab working beside it, its spinner at 60 a second, as
    // when an agent runs in the next tab.
    let other = ProcessInfo.processInfo.environment["MOTION_OTHER_PANE"] ?? ""
    if !other.isEmpty { status("working", pane: other) }
    frames = await run("done", 1.8) { status("done", pane: pane) }
    if !other.isEmpty { status("idle", pane: other) }
    for (surface, area, ring) in [("tab", "tab", "tab-ring"), ("row", "row", "row-ring")] {
        let width = (area == "tab" ? pill.width : row.width)
        let band = bandTrack(frames, area, skip: area == "tab" ? 28 : (rowRing.x - row.minX + 14), in: 0...1300)
        let xs = band.map(\.x)
        let backwards = zip(xs, xs.dropFirst()).map { $0 - $1 }.max() ?? 0
        let jump = zip(xs, xs.dropFirst()).map { $1 - $0 }.max() ?? 0
        let span = (xs.max() ?? 0) - (xs.min() ?? 0)
        let sweepWindow = (band.first?.ms ?? 0)...(band.last?.ms ?? 0)
        let c = cadence(frames, area, in: sweepWindow)
        let ok = band.count >= 8 && span > 0.4 * width && backwards < 3 && jump < 0.25 * width && c.longestGap <= stall
            && c.fps >= 0.8 * displayFPS
        check("done", surface, ok, String(format: "glint %.0f -> %.0f pt of %.0f in %d redraws, back %.1f, jump %.0f, %@",
                                          xs.first ?? 0, xs.last ?? 0, width, band.count, max(0, backwards), jump, c.description))
        let sizes = discs(frames, ring, Crop.green, in: 0...900).map { $0.box.width }.filter { $0 > 3 }
        let popped = (sizes.min() ?? 99) < 11 && (sizes.max() ?? 0) > 15.5
        check("done", surface, popped, String(format: "pop %.1f -> %.1f pt (design 7.7 -> 17.5)", sizes.min() ?? 0, sizes.max() ?? 0))
    }

    // Failed: the whole surface shakes 2 pt each way and comes back. A
    // failed tab also badges its workspace chip, which now slides the pills
    // along over 150 ms: the swing is read after that, the pill must never
    // jump, and on the pill the title must move with the ring.
    status("working", pane: pane)
    try? await Task.sleep(nanoseconds: 500_000_000)
    frames = await run("failed", 1.0) { status("error", pane: pane) }
    for (surface, region) in [("tab", "tab-line"), ("row", "row-ring")] {
        // The ring: 45 pt into the tab line, 21 more once the chip has slid.
        let track = shakeTrack(frames, region, discLeftOf: region == "tab-line" ? 85 : .infinity, in: 0...900)
        guard let start = track.first?.ms, let rest = track.last?.disc else {
            check("failed", surface, false, "no failed ring found"); continue
        }
        let swing = track.filter { $0.ms > start + 170 && $0.ms < start + 460 }.map { $0.disc - rest }
        let reach = (swing.max() ?? 0, swing.min() ?? 0)
        let step = zip(track, track.dropFirst()).map { abs($1.disc - $0.disc) }.max() ?? 0
        let apart = track.compactMap { t in t.title.map { t.disc - $0 } }
        let together = (apart.max() ?? 0) - (apart.min() ?? 0)
        // Ring and title measured apart wander ~1 pt with antialiasing; a
        // ring shaking alone would wander the full 4.
        let whole = surface != "tab" || (apart.count > 10 && together < 2)
        check("failed", surface, reach.0 > 1.4 && reach.1 < -1.4 && step < 8 && whole,
              String(format: "shake %+.1f / %+.1f pt (design ±2), largest step %.1f pt%@", reach.1, reach.0, step,
                     surface == "tab" ? String(format: ", ring and title %.1f pt apart at most", together) : ""))
    }

    // Waiting: the halo, the dot and the border never stop. Judged on the
    // whole surface: the ring alone is still for a few frames each cycle,
    // when the halo has faded and the dot turns.
    frames = await run("waiting", 2.0) { status("needs_approval", pane: pane) }
    for surface in ["tab", "row"] {
        let c = cadence(frames, surface, in: 300...2000)
        check("waiting", surface, c.redraws > 40 && c.longestGap <= stall, "halo, dot and border: \(c)")
    }

    // Overview: a card's done glint crosses the card at the display's rate too.
    status("working", pane: pane)
    guard pressMenuItem(pid: pid, menu: "View", item: "Pane Overview") else {
        check("done", "card", false, "no View > Pane Overview to press"); finish()
    }
    try? await Task.sleep(nanoseconds: 1_000_000_000)
    // Cards are titled by their pane, not their tab: the working pane's is
    // the one card whose chip says Working.
    if let chip = accessibilityFrames(pid: pid, role: "AXStaticText", { $0 == "Working" }).first(where: { $0.minX > sidebar.maxX + 20 }) {
        // The card's title row and chip, its full width: 8 pt left of the chip, 228 pt across.
        let card = CGRect(x: chip.minX - 8, y: chip.minY - 34, width: 228, height: 52)
        let cardFrames: [Frame]
        do {
            cardFrames = try await record(bundleID: bundleID, area: window, regions: [("card", card)], seconds: 1.6) { status("done", pane: pane) }
        } catch { print("capture failed: \(error)"); exit(1) }
        if args.count > 4 { dump(cardFrames, scene: "overview", to: args[4]) }
        let band = bandTrack(cardFrames, "card", skip: 34, in: 0...1300)
        let xs = band.map(\.x)
        let span = (xs.max() ?? 0) - (xs.min() ?? 0)
        let backwards = zip(xs, xs.dropFirst()).map { $0 - $1 }.max() ?? 0
        let c = cadence(cardFrames, "card", in: (band.first?.ms ?? 0)...(band.last?.ms ?? 0))
        check("done", "card", band.count >= 8 && span > 0.4 * card.width && backwards < 3 && c.longestGap <= stall && c.fps >= 0.8 * displayFPS,
              String(format: "glint %.0f -> %.0f pt in %d redraws, back %.1f, %@", xs.first ?? 0, xs.last ?? 0, band.count, max(0, backwards), c.description))
    } else {
        check("done", "card", false, "no Overview card with a Working chip")
    }
    pressMenuItem(pid: pid, menu: "View", item: "Pane Overview")
    status("idle", pane: pane)
    finish()
}

func finish() -> Never {
    let failed = checks.filter { !$0.ok }
    print(failed.isEmpty ? "motion-check: all \(checks.count) checks passed" : "motion-check: \(failed.count) of \(checks.count) checks failed")
    exit(failed.isEmpty ? 0 : 1)
}
dispatchMain()

/// A recording's crops as PNGs, for a look by eye.
func dump(_ frames: [Frame], scene: String, to dir: String) {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for (i, f) in frames.enumerated() {
        for (name, crop) in f.crops {
            let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            guard let image = CGImage(width: crop.width, height: crop.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: crop.width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info,
                                      provider: CGDataProvider(data: crop.bytes as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
            else { continue }
            let rep = NSBitmapImageRep(cgImage: image)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: String(format: "%@/%@-%@_%04d_%.0fms.png", dir, scene, name, i, f.ms)))
        }
    }
}
