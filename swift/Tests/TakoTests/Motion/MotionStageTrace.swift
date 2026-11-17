/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Testing
import WebKit

/// Observation only, under TAKO_MOTION_DIAGNOSTICS=<directory>: when each
/// stage of a motion test starts and ends, on the monotonic clock, and what
/// a captured frame held. Nothing here waits, lays out, renders or changes a
/// policy; images are kept as captured and encoded only in `write`, after the
/// timed loops, so file I/O cannot fall inside them.
@MainActor
final class MotionStageTrace {
    static var directory: String? {
        ProcessInfo.processInfo.environment["TAKO_MOTION_DIAGNOSTICS"].flatMap { $0.isEmpty ? nil : $0 }
    }

    let name: String
    private let origin = ProcessInfo.processInfo.systemUptime
    private var stages: [[String: Any]] = []
    private var frames: [[String: Any]] = []
    private var images: [(String, NSBitmapImageRep)] = []
    private var facts: [String: Any] = [:]

    /// Nil unless diagnostics are asked for: then no test does any of this.
    init?(_ name: String) {
        guard Self.directory != nil else { return nil }
        self.name = name
    }

    /// Seconds since this trace began, monotonic.
    func now() -> Double { ProcessInfo.processInfo.systemUptime - origin }

    func mark(_ stage: String) { stages.append(["stage": stage, "t": now()]) }

    func set(_ key: String, _ value: Any) { facts[key] = value }

    /// One captured frame. `frameT` is the test's own timestamp for it (the
    /// probe's Date, taken before the snapshot); the others are this trace's.
    func frame(phase: String, index: Int, runLoopStart: Double, runLoopEnd: Double, snapshotEnd: Double,
               frameT: Double, value: Double, image: NSBitmapImageRep, keepImage: Bool, root: NSView) {
        var row: [String: Any] = ["phase": phase, "index": index, "runLoopStart": runLoopStart,
                                  "runLoopEnd": runLoopEnd, "snapshotEnd": snapshotEnd, "frameT": frameT,
                                  "value": value, "pixels": [image.pixelsWide, image.pixelsHigh]]
        row["web"] = Self.webSample(in: root)
        row["sampledEnd"] = now()
        frames.append(row)
        if keepImage { images.append(("\(phase)-\(String(format: "%03d", index))", image)) }
    }

    func keep(_ label: String, _ image: NSBitmapImageRep) { images.append((label, image)) }

    /// The first WKWebView under `root` (at most 200 views, 12 deep): whether
    /// it loads and how far, and how opaque it and up to three ancestors are,
    /// natively and as presented. No URL or content is read.
    static func webSample(in root: NSView) -> [String: Any] {
        var visited = 0
        // The cap is checked before a view is visited, and stops siblings too.
        func find(_ view: NSView, _ depth: Int) -> WKWebView? {
            guard visited < 200 else { return nil }
            visited += 1
            if let web = view as? WKWebView { return web }
            guard depth < 12 else { return nil }
            for sub in view.subviews {
                guard visited < 200 else { break }
                if let found = find(sub, depth + 1) { return found }
            }
            return nil
        }
        guard let web = find(root, 0) else { return ["present": false, "visited": visited] }
        var chain: [[String: Any]] = []
        var view: NSView? = web
        while let v = view, chain.count < 4 {
            var row: [String: Any] = ["type": String(describing: type(of: v)).prefix(80).description,
                                      "alpha": Double(v.alphaValue), "hidden": v.isHidden]
            if let layer = v.layer {
                row["opacity"] = Double(layer.opacity)
                if let presented = layer.presentation() { row["presentedOpacity"] = Double(presented.opacity) }
                row["animations"] = (layer.animationKeys() ?? []).prefix(6).map { $0 }
            }
            chain.append(row)
            view = v.superview
        }
        return ["present": true, "visited": visited, "loading": web.isLoading,
                "progress": web.estimatedProgress, "chain": chain]
    }

    /// The JSON and PNGs, after the measured work; passing and failing alike.
    /// An observation that was asked for and could not be written fails the
    /// test: a missing image or JSON is never a pass.
    func write() {
        guard let directory = Self.directory else { return }
        let root = URL(fileURLWithPath: directory).appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for (label, image) in images {
                guard let png = image.representation(using: .png, properties: [:]) else {
                    Issue.record("motion observation \(name): image \(label) could not be encoded as PNG")
                    continue
                }
                try png.write(to: root.appendingPathComponent("\(label).png"))
            }
            let report: [String: Any] = ["name": name, "stages": stages, "frames": frames, "facts": facts,
                                         "images": images.map { $0.0 }]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("trace.json"))
            print("[motion stages] \(name): \(stages.count) stages, \(frames.count) frames, \(images.count) images -> \(root.path)/trace.json")
        } catch {
            Issue.record("motion observation \(name): could not write to \(root.path): \(error)")
        }
    }
}
