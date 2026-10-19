/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

// What is on screen, frame by frame: ScreenCaptureKit streams one app's
// window at the display's rate and keeps, for every frame the window server
// composited, its display time and a crop of each region. Regions are found
// in the app's accessibility tree, so nothing is placed by hand.

import AppKit
import ApplicationServices
import CoreMedia
import ScreenCaptureKit

/// One crop of one frame: BGRA pixels, top row first.
struct Crop {
    let width: Int
    let height: Int
    let scale: CGFloat
    let bytes: Data

    /// sRGB-ish components, 0...1, of the pixel at `x`, `y`.
    func rgb(_ x: Int, _ y: Int) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let i = bytes.startIndex + (y * width + x) * 4
        let b = CGFloat(bytes[i]), g = CGFloat(bytes[i + 1]), r = CGFloat(bytes[i + 2])
        return (r / 255, g / 255, b / 255)
    }
}

/// A frame: when it was shown, in ms from the recording's mark, and its crops by region name.
struct Frame {
    let ms: Double
    let crops: [String: Crop]
}

final class RegionRecorder: NSObject, SCStreamOutput {
    private let regions: [(String, CGRect)]  // relative to the captured rect, points
    private let scale: CGFloat
    private let lock = NSLock()
    private var frames: [(t: UInt64, crops: [String: Crop])] = []

    init(regions: [(String, CGRect)], scale: CGFloat) {
        self.regions = regions
        self.scale = scale
    }

    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let status = (info[.status] as? Int).flatMap(SCFrameStatus.init(rawValue:)), status == .complete,
              let shown = info[.displayTime] as? UInt64,
              let buffer = CMSampleBufferGetImageBuffer(sb) else { return }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let bw = CVPixelBufferGetWidth(buffer), bh = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        var crops: [String: Crop] = [:]
        for (name, r) in regions {
            let x0 = max(0, Int(r.minX * scale)), y0 = max(0, Int(r.minY * scale))
            let x1 = min(bw, Int(r.maxX * scale)), y1 = min(bh, Int(r.maxY * scale))
            guard x1 > x0, y1 > y0 else { continue }
            var data = Data(capacity: (x1 - x0) * (y1 - y0) * 4)
            for y in y0..<y1 {
                data.append(base.advanced(by: y * rowBytes + x0 * 4).assumingMemoryBound(to: UInt8.self), count: (x1 - x0) * 4)
            }
            crops[name] = Crop(width: x1 - x0, height: y1 - y0, scale: scale, bytes: data)
        }
        lock.lock(); frames.append((shown, crops)); lock.unlock()
    }

    func take(since mark: UInt64) -> [Frame] {
        lock.lock(); defer { lock.unlock() }
        return frames.map { Frame(ms: machMs($0.t) - machMs(mark), crops: $0.crops) }
    }
}

private let timebase: mach_timebase_info_data_t = {
    var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb); return tb
}()

func machMs(_ t: UInt64) -> Double { Double(t) * Double(timebase.numer) / Double(timebase.denom) / 1e6 }

/// Records `regions` (global top-left points) of `bundleID`'s windows inside
/// `area` for `seconds`, running `action` once the stream is up. Frame times
/// are ms from the moment `action` started.
func record(bundleID: String, area: CGRect, regions: [(String, CGRect)], seconds: Double,
            action: @escaping () -> Void) async throws -> [Frame] {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard let display = content.displays.first(where: { $0.frame.contains(CGPoint(x: area.midX, y: area.midY)) }),
          let app = content.applications.first(where: { $0.bundleIdentifier == bundleID }) else {
        throw MotionError("no display or no running \(bundleID) to capture -- is Screen Recording allowed?")
    }
    let scale = NSScreen.screens.first { $0.frame.width > 0 }?.backingScaleFactor ?? 1
    let config = SCStreamConfiguration()
    config.sourceRect = area.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
    config.width = Int(area.width * scale); config.height = Int(area.height * scale)
    config.minimumFrameInterval = CMTime(value: 1, timescale: 240)
    config.queueDepth = 8
    config.showsCursor = false
    config.pixelFormat = kCVPixelFormatType_32BGRA
    let recorder = RegionRecorder(regions: regions.map { ($0.0, $0.1.offsetBy(dx: -area.minX, dy: -area.minY)) }, scale: scale)
    let stream = SCStream(filter: SCContentFilter(display: display, including: [app], exceptingWindows: []), configuration: config, delegate: nil)
    try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: DispatchQueue(label: "motion.frames", qos: .userInteractive))
    try await stream.startCapture()
    try await Task.sleep(nanoseconds: 300_000_000)
    let mark = mach_absolute_time()
    action()
    try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
    try await stream.stopCapture()
    return recorder.take(since: mark)
}

struct MotionError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

// MARK: - Where things are

/// The app's main window: its largest on-screen window, global top-left points.
func mainWindow(pid: pid_t) -> CGRect? {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.compactMap { w -> CGRect? in
        guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid, (w[kCGWindowLayer as String] as? Int) == 0,
              let b = w[kCGWindowBounds as String] as? [String: Double] else { return nil }
        return CGRect(x: b["X"]!, y: b["Y"]!, width: b["Width"]!, height: b["Height"]!)
    }.max { $0.width * $0.height < $1.width * $1.height }
}

private func attribute(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}

private func frame(_ e: AXUIElement) -> CGRect? {
    guard let p = attribute(e, kAXPositionAttribute), let s = attribute(e, kAXSizeAttribute) else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &point)
    AXValueGetValue(s as! AXValue, .cgSize, &size)
    return CGRect(origin: point, size: size)
}

/// The frames of every element of `role` whose title, value or placeholder
/// `matches` -- or of every one, without `matches`.
func accessibilityFrames(pid: pid_t, role: String, _ matches: ((String) -> Bool)? = nil) -> [CGRect] {
    var found: [CGRect] = []
    func walk(_ e: AXUIElement, _ depth: Int) {
        guard depth < 40 else { return }
        if (attribute(e, kAXRoleAttribute) as? String) == role,
           matches.map { m in [kAXTitleAttribute, kAXValueAttribute, kAXPlaceholderValueAttribute].contains { (attribute(e, $0) as? String).map(m) ?? false } } ?? true,
           let f = frame(e) {
            found.append(f)
        }
        for child in attribute(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] { walk(child, depth + 1) }
    }
    walk(AXUIElementCreateApplication(pid), 0)
    return found
}

/// Presses `item` in the app's `menu` through the accessibility tree: no key
/// reaches any other app.
@discardableResult
func pressMenuItem(pid: pid_t, menu: String, item: String) -> Bool {
    let app = AXUIElementCreateApplication(pid)
    guard let bar = attribute(app, kAXMenuBarAttribute).map({ $0 as! AXUIElement }),
          let top = (attribute(bar, kAXChildrenAttribute) as? [AXUIElement])?.first(where: { (attribute($0, kAXTitleAttribute) as? String) == menu }),
          let list = (attribute(top, kAXChildrenAttribute) as? [AXUIElement])?.first,
          let entry = (attribute(list, kAXChildrenAttribute) as? [AXUIElement])?.first(where: { (attribute($0, kAXTitleAttribute) as? String) == item })
    else { return false }
    return AXUIElementPerformAction(entry, kAXPressAction as CFString) == .success
}
